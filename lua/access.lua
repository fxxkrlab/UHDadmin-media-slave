-- access.lua: Main access control entry point (access_by_lua_file)
-- Runs for every request in the access phase.
--
-- Check order:
--   1. URI skip list (streaming bypass)
--   2. URI block list
--   3. Client detection + Token→User reverse lookup
--   4. L2 Redis: enforcement check (ban/throttle)
--   5. L1 shared_dict: req/s + req/min rate limit
--   6. L2 Redis: remaining quota check (daily/monthly)
--   6b. Concurrent stream check (PlaySessionId-based)
--   7. Client whitelist + version
--   8. Fake counts interception

local cjson = require("cjson.safe")
local config = require("config")
local client_detect = require("client_detect")
local rate_limiter = require("rate_limiter")
local redis_store = require("redis_store")
local telemetry = require("telemetry")

-- ==================== Helper Functions ====================

local function deny_request(status, message)
    ngx.status = status
    ngx.header["Content-Type"] = "text/plain; charset=utf-8"
    ngx.header["X-DetailPreload-Bytes"] = "-1"
    ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate"
    ngx.say(message)
    return ngx.exit(status)
end

local function deny_json(status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["X-DetailPreload-Bytes"] = "-1"
    ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate"
    local json = cjson.encode(body) or "{}"
    ngx.header["Content-Length"] = #json
    ngx.say(json)
    return ngx.exit(status)
end

-- ==================== Load Config ====================

local lua_cfg = config.get_lua_config()
if not lua_cfg then
    -- No config loaded yet (agent hasn't pulled), allow pass-through
    return
end

local uri = ngx.var.uri or ""

-- ==================== 1. URI Skip List (streaming bypass) ====================

local skip_list = lua_cfg.skip_list or {}
for _, rule in ipairs(skip_list) do
    local pattern = rule.pattern
    if pattern then
        if rule.match_type == "regex" then
            if ngx.re.find(uri, pattern, "ijo") then
                return  -- Allow, skip all access checks
            end
        elseif rule.match_type == "prefix" then
            if uri:sub(1, #pattern) == pattern then
                return
            end
        elseif rule.match_type == "exact" then
            if uri == pattern then
                return
            end
        end
    end
end

-- ==================== 2. URI Block List ====================

local block_list = lua_cfg.block_list or {}
for _, rule in ipairs(block_list) do
    local pattern = rule.pattern
    if pattern then
        local matched = false
        if rule.match_type == "regex" then
            matched = ngx.re.find(uri, pattern, "ijo") ~= nil
        elseif rule.match_type == "prefix" then
            matched = uri:sub(1, #pattern) == pattern
        elseif rule.match_type == "exact" then
            matched = uri == pattern
        end

        if matched then
            ngx.log(ngx.WARN, "Blocked URI: ", uri)
            telemetry.log_blocked({
                reason = "uri_blocked",
                uri = uri,
                pattern = pattern,
                ip = ngx.var.remote_addr,
                timestamp = ngx.now(),
            })
            return deny_request(ngx.HTTP_FORBIDDEN, "此接口已被禁用")
        end
    end
end

-- ==================== 3. Client Detection ====================

local client_name = client_detect.get_client_name()
local client_version = client_detect.get_client_version()
local device_id = client_detect.get_device_id()
local device_name = client_detect.get_device_name()
local user_id = client_detect.get_user_id()
local token = client_detect.get_token()
local play_session_id = client_detect.get_play_session_id()
local client_ip = ngx.var.remote_addr

-- Token → User reverse lookup: if user_id is missing, try to resolve from token cache
if token then
    if not user_id then
        local token_info = redis_store.get_token_map(token)
        if token_info then
            user_id = token_info.user_id
            if not device_id and token_info.device_id then
                device_id = token_info.device_id
            end
            if not device_name and token_info.device_name then
                device_name = token_info.device_name
            end
            if not client_name and token_info.client_name then
                client_name = token_info.client_name
            end
        end
    else
        -- user_id is known, refresh token TTL
        redis_store.touch_token_map(token)
    end
end

-- Fallback: device_id → user_id mapping (from Plan B Emby Sessions API resolve)
if not user_id and device_id then
    local red, _ = redis_store.connect()
    if red then
        local raw = red:get("device_user:" .. device_id)
        redis_store.keepalive(red)
        if raw and raw ~= ngx.null then
            local info = cjson.decode(raw)
            if info and info.user_id then
                user_id = info.user_id
                if not device_name and info.device_name then
                    device_name = info.device_name
                end
            end
        end
    end
end

-- Store in ngx.ctx for log phase and body_filter
ngx.ctx.client_name = client_name
ngx.ctx.client_version = client_version
ngx.ctx.device_id = device_id
ngx.ctx.device_name = device_name
ngx.ctx.user_id = user_id
ngx.ctx.token = token
ngx.ctx.play_session_id = play_session_id

-- ==================== 4. L2 Redis: Enforcement Check ====================
-- Check if there's an active enforcement (ban/throttle) for this IP/user/device

local function check_redis_enforcement(dimension, value)
    if not value then return nil end
    local enf = redis_store.check_enforcement(dimension, value)
    if enf then
        if enf.action == "reject" then
            ngx.log(ngx.WARN, "Enforcement reject: ", dimension, "=", value,
                    " reason=", enf.reason or "quota")
            telemetry.log_blocked({
                reason = "enforcement_reject",
                dimension = dimension,
                dimension_value = value,
                ip = client_ip,
                uri = uri,
                timestamp = ngx.now(),
            })
            return deny_request(ngx.HTTP_FORBIDDEN, enf.reason or "访问受限")
        end
        if enf.action == "throttle" then
            ngx.ctx.throttle_rate_bps = enf.throttle_rate_bps
        end
    end
end

check_redis_enforcement("ip", client_ip)
check_redis_enforcement("user", user_id)
check_redis_enforcement("device", device_id)

-- ==================== 5. L1 shared_dict: Rate Limiting ====================

local rate_cfg = config.get_rate_limit_config()
if rate_cfg and rate_cfg.rules then
    for _, rule in ipairs(rate_cfg.rules) do
        local key = nil

        -- Determine rate limit key based on apply_to
        if rule.apply_to == "ip" then
            if not rule.apply_value or rule.apply_value == "*" then
                key = "ip:" .. client_ip
            elseif rule.apply_value == client_ip then
                key = "ip:" .. client_ip
            end
        elseif rule.apply_to == "user" and user_id then
            if not rule.apply_value or rule.apply_value == "*" then
                key = "user:" .. user_id
            elseif rule.apply_value == user_id then
                key = "user:" .. user_id
            end
        elseif rule.apply_to == "device" and device_id then
            if not rule.apply_value or rule.apply_value == "*" then
                key = "device:" .. device_id
            elseif rule.apply_value == device_id then
                key = "device:" .. device_id
            end
        elseif rule.apply_to == "global" then
            key = "global"
        end

        if key then
            -- Check per-second rate
            if rule.rate_per_second and rule.rate_per_second > 0 then
                local allowed = rate_limiter.check_rate(key, rule.rate_per_second, rule.rate_burst)
                if not allowed then
                    ngx.log(ngx.WARN, "Rate limited (req/s): ", key)
                    telemetry.log_blocked({
                        reason = "rate_limit_rps",
                        key = key,
                        rule_id = rule.id,
                        ip = client_ip,
                        uri = uri,
                        timestamp = ngx.now(),
                    })
                    if rule.over_action == "reject" then
                        return deny_request(429, "请求过于频繁，请稍后再试")
                    end
                    if rule.over_action == "throttle" and rule.throttle_rate_bps then
                        ngx.ctx.throttle_rate_bps = rule.throttle_rate_bps
                    end
                end
            end

            -- Check per-minute rate
            if rule.rate_per_minute and rule.rate_per_minute > 0 then
                local allowed = rate_limiter.check_minute_rate(key .. ":min", rule.rate_per_minute)
                if not allowed then
                    ngx.log(ngx.WARN, "Rate limited (req/min): ", key)
                    telemetry.log_blocked({
                        reason = "rate_limit_rpm",
                        key = key,
                        rule_id = rule.id,
                        ip = client_ip,
                        uri = uri,
                        timestamp = ngx.now(),
                    })
                    if rule.over_action == "reject" then
                        return deny_request(429, "请求过于频繁，请稍后再试")
                    end
                    if rule.over_action == "throttle" and rule.throttle_rate_bps then
                        ngx.ctx.throttle_rate_bps = rule.throttle_rate_bps
                    end
                end
            end
        end
    end
end

-- ==================== 6. L2 Redis: Remaining Quota Check ====================

local function check_remaining_quota(dimension, value)
    if not value then return end

    local req_left, bw_left = redis_store.get_remaining(dimension, value)

    -- req_left/bw_left = nil means no quota set for this dimension (allow)
    if req_left and req_left <= 0 then
        ngx.log(ngx.WARN, "Quota exhausted (requests): ", dimension, "=", value,
                " remaining=", req_left)
        telemetry.log_blocked({
            reason = "quota_requests_exhausted",
            dimension = dimension,
            dimension_value = value,
            ip = client_ip,
            uri = uri,
            timestamp = ngx.now(),
        })
        return deny_request(429, "请求配额已用尽，请稍后再试")
    end

    if bw_left and bw_left <= 0 then
        ngx.log(ngx.WARN, "Quota exhausted (bandwidth): ", dimension, "=", value,
                " remaining=", bw_left)
        telemetry.log_blocked({
            reason = "quota_bandwidth_exhausted",
            dimension = dimension,
            dimension_value = value,
            ip = client_ip,
            uri = uri,
            timestamp = ngx.now(),
        })
        return deny_request(429, "流量配额已用尽，请稍后再试")
    end
end

check_remaining_quota("ip", client_ip)
check_remaining_quota("user", user_id)
check_remaining_quota("device", device_id)

-- ==================== 6b. Concurrent Stream Check ====================
-- Only applies when a PlaySessionId is present (streaming requests)

if play_session_id and user_id then
    local is_new = not redis_store.session_exists(user_id, play_session_id)
    if is_new then
        -- New stream: check concurrent limit
        local concurrent_cfg = lua_cfg.concurrent_streams
        if concurrent_cfg and concurrent_cfg.max_streams then
            local active_count = redis_store.count_user_sessions(user_id)
            if active_count >= concurrent_cfg.max_streams then
                ngx.log(ngx.WARN, "Concurrent stream limit: user=", user_id,
                        " active=", active_count, " max=", concurrent_cfg.max_streams)
                telemetry.log_blocked({
                    reason = "concurrent_stream_limit",
                    user_id = user_id,
                    play_session_id = play_session_id,
                    active_count = active_count,
                    max_streams = concurrent_cfg.max_streams,
                    ip = client_ip,
                    uri = uri,
                    timestamp = ngx.now(),
                })
                return deny_request(429, concurrent_cfg.deny_message or "同时播放流数量已达上限")
            end
        end

        -- Register this new session
        redis_store.register_session(user_id, play_session_id, {
            device_id = device_id,
            device_name = device_name,
            client_name = client_name,
            client_ip = client_ip,
            item_id = nil,  -- populated in log phase if available
        })
    end
end

-- ==================== 7. Client Whitelist ====================

local deny_message = lua_cfg.deny_message or "请使用允许的客户端进行访问"

if client_name then
    local whitelist = config.get_client_whitelist()

    -- Only enforce if whitelist is non-empty
    if next(whitelist) then
        if not whitelist[client_name] then
            ngx.log(ngx.WARN, "Client not in whitelist: [", client_name, "] version: [",
                    client_version or "unknown", "]")
            telemetry.log_blocked({
                reason = "client_not_whitelisted",
                client_name = client_name,
                client_version = client_version,
                ip = client_ip,
                uri = uri,
                timestamp = ngx.now(),
            })
            return deny_request(ngx.HTTP_FORBIDDEN, deny_message)
        end

        -- Check minimum version
        local min_versions = config.get_min_versions()
        local min_ver = min_versions[client_name]
        if min_ver then
            if not client_version or not client_detect.is_version_sufficient(client_version, min_ver) then
                if not client_version then
                    ngx.log(ngx.WARN, "No version detected for ", client_name)
                else
                    ngx.log(ngx.WARN, "Version too old for ", client_name, ": ",
                            client_version, " < ", min_ver)
                end
                telemetry.log_blocked({
                    reason = "version_too_old",
                    client_name = client_name,
                    client_version = client_version,
                    required_version = min_ver,
                    ip = client_ip,
                    uri = uri,
                    timestamp = ngx.now(),
                })
                return deny_request(ngx.HTTP_FORBIDDEN,
                    "请使用 " .. client_name .. " " .. min_ver .. " 或更高版本进行访问")
            end
        end
    end
end

-- ==================== 8. Fake Counts (Items/Counts interception) ====================

if lua_cfg.fake_counts_enabled then
    local function is_items_counts_request()
        if ngx.re.find(uri, [[/Items/Counts(?:$|/)]], "ijo") then
            return true
        end
        if ngx.re.find(uri, [[/Users/.*/Items/Counts]], "ijo") then
            return true
        end
        return false
    end

    if is_items_counts_request() then
        ngx.req.discard_body()
        ngx.log(ngx.INFO, "Items/Counts intercepted, client=",
                client_name or "unknown", " uri=", ngx.var.request_uri or "")

        local fake_value = lua_cfg.fake_counts_value or 888
        local fake_counts = {
            MovieCount = fake_value,
            SeriesCount = fake_value,
            EpisodeCount = fake_value,
            BoxSetCount = fake_value,
            ProgramCount = fake_value,
            ChannelCount = fake_value,
            TrailerCount = fake_value,
            GameCount = fake_value,
            MusicVideoCount = fake_value,
            AlbumCount = fake_value,
            SongCount = fake_value,
            ArtistCount = fake_value,
            AudioCount = fake_value,
            BookCount = fake_value,
            ItemCount = fake_value,
        }

        return deny_json(ngx.HTTP_OK, fake_counts)
    end
end

-- ==================== Set Detail Preload Header ====================
ngx.header["X-DetailPreload-Bytes"] = "-1"
