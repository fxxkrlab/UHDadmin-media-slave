-- access.lua: Main access control entry point (access_by_lua_file)
-- Runs for every request in the access phase.
-- Loads config from shared dict, enforces client whitelist, URI rules,
-- rate limits, enforcements, and fake counts.

local cjson = require("cjson.safe")
local config = require("config")
local client_detect = require("client_detect")
local rate_limiter = require("rate_limiter")
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

-- ==================== URI Skip List (streaming bypass) ====================

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

-- ==================== URI Block List ====================

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

-- ==================== Client Detection ====================

local client_name = client_detect.get_client_name()
local client_version = client_detect.get_client_version()
local device_id = client_detect.get_device_id()
local user_id = client_detect.get_user_id()
local client_ip = ngx.var.remote_addr

-- Store in ngx.ctx for log phase
ngx.ctx.client_name = client_name
ngx.ctx.client_version = client_version
ngx.ctx.device_id = device_id
ngx.ctx.user_id = user_id

-- ==================== Enforcement Check ====================
-- Check if there's an active enforcement (ban/throttle) for this IP/user/device

local function check_all_enforcements()
    -- Check IP enforcement
    local enf = rate_limiter.check_enforcement("ip", client_ip)
    if enf then return enf end

    -- Check user enforcement
    if user_id then
        enf = rate_limiter.check_enforcement("user", user_id)
        if enf then return enf end
    end

    -- Check device enforcement
    if device_id then
        enf = rate_limiter.check_enforcement("device", device_id)
        if enf then return enf end
    end

    return nil
end

local enforcement = check_all_enforcements()
if enforcement then
    if enforcement.action == "reject" then
        ngx.log(ngx.WARN, "Enforcement reject: ", enforcement.dimension, "=",
                enforcement.dimension_value, " reason=", enforcement.reason or "quota")
        telemetry.log_blocked({
            reason = "enforcement_reject",
            enforcement_id = enforcement.id,
            dimension = enforcement.dimension,
            dimension_value = enforcement.dimension_value,
            ip = client_ip,
            uri = uri,
            timestamp = ngx.now(),
        })
        return deny_request(ngx.HTTP_FORBIDDEN,
            enforcement.reason or "访问受限")
    end
    -- throttle: store in ctx for log phase (bandwidth limiting is handled at proxy level)
    if enforcement.action == "throttle" then
        ngx.ctx.throttle_rate_bps = enforcement.throttle_rate_bps
    end
end

-- ==================== Rate Limiting ====================

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
                    -- throttle: mark for bandwidth limiting
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

-- ==================== Client Whitelist ====================

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

-- ==================== Fake Counts (Items/Counts interception) ====================

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
-- Disable detail preload for all requests (configurable)
ngx.header["X-DetailPreload-Bytes"] = "-1"
