-- init_worker.lua: Background timer workers (init_worker_by_lua_file)
-- Starts periodic timers for:
-- 1. Config pull from UHDadmin
-- 2. Telemetry flush (access logs + blocked requests + token reports)
-- 3. Quota sync (Redis counters → UHDadmin → remaining capacity back to Redis)
-- 4. Heartbeat
-- 5. Token resolve (Plan B: query Emby API for unknown tokens)
-- 6. Session heartbeat (report active sessions to UHDadmin)

local cjson = require("cjson.safe")
local config = require("config")
local telemetry = require("telemetry")
local redis_store = require("redis_store")

-- ==================== Environment Config ====================

local UHDADMIN_URL = os.getenv("UHDADMIN_URL") or "http://localhost:8000"
local APP_TOKEN = os.getenv("APP_TOKEN") or ""
local AGENT_VERSION = "0.2.1"

-- Emby/Jellyfin server direct access (for Plan B token resolve)
local EMBY_API_KEY = os.getenv("EMBY_API_KEY") or ""
local EMBY_SERVER_URL = os.getenv("EMBY_SERVER_URL") or ""

-- Timer intervals (seconds)
local CONFIG_PULL_INTERVAL = tonumber(os.getenv("CONFIG_PULL_INTERVAL")) or 30
local TELEMETRY_FLUSH_INTERVAL = tonumber(os.getenv("TELEMETRY_FLUSH_INTERVAL")) or 60
local QUOTA_SYNC_INTERVAL = tonumber(os.getenv("QUOTA_SYNC_INTERVAL")) or 300
local HEARTBEAT_INTERVAL = tonumber(os.getenv("HEARTBEAT_INTERVAL")) or 60
local TOKEN_RESOLVE_INTERVAL = tonumber(os.getenv("TOKEN_RESOLVE_INTERVAL")) or 30
local SESSION_HEARTBEAT_INTERVAL = tonumber(os.getenv("SESSION_HEARTBEAT_INTERVAL")) or 30

-- ==================== HTTP Client Helper ====================

local function api_request(method, path, body)
    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(10000)  -- 10s timeout

    local url = UHDADMIN_URL .. "/api/v1/media-slave" .. path

    local headers = {
        ["Authorization"] = "App " .. APP_TOKEN,
        ["Content-Type"] = "application/json",
        ["User-Agent"] = "UHDSlave/" .. AGENT_VERSION,
    }

    local req_body = nil
    if body then
        req_body = cjson.encode(body)
    end

    local res, err = httpc:request_uri(url, {
        method = method,
        headers = headers,
        body = req_body,
    })

    if not res then
        ngx.log(ngx.ERR, "API request failed: ", path, " error=", err)
        return nil, err
    end

    if res.status >= 400 then
        ngx.log(ngx.ERR, "API error: ", path, " status=", res.status, " body=", res.body)
        return nil, "HTTP " .. res.status
    end

    local data = cjson.decode(res.body)
    if not data then
        return nil, "Invalid JSON response"
    end

    return data
end

--- HTTP request to Emby/Jellyfin server directly (for Plan B)
local function emby_request(method, path)
    if not EMBY_SERVER_URL or EMBY_SERVER_URL == "" then
        return nil, "EMBY_SERVER_URL not configured"
    end
    if not EMBY_API_KEY or EMBY_API_KEY == "" then
        return nil, "EMBY_API_KEY not configured"
    end

    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(5000)

    local url = EMBY_SERVER_URL .. path

    local res, err = httpc:request_uri(url, {
        method = method,
        headers = {
            ["X-Emby-Token"] = EMBY_API_KEY,
            ["Content-Type"] = "application/json",
        },
    })

    if not res then
        return nil, err
    end
    if res.status >= 400 then
        return nil, "HTTP " .. res.status
    end

    return cjson.decode(res.body)
end

-- ==================== Config Pull ====================

local function pull_config(premature)
    if premature then return end

    -- Check version first
    local ver_resp, err = api_request("GET", "/config/version")
    if not ver_resp then
        ngx.log(ngx.ERR, "Config version check failed: ", err)
        goto schedule
    end

    local ver_data = ver_resp.data
    if not ver_data then
        goto schedule
    end

    local current_version = config.get_version()
    if not ver_data.has_update and ver_data.version <= current_version then
        goto schedule
    end

    ngx.log(ngx.INFO, "Config update available: ", current_version, " -> ", ver_data.version)

    -- Pull full config
    do
        local cfg_resp, cfg_err = api_request("GET", "/config")
        if not cfg_resp then
            ngx.log(ngx.ERR, "Config pull failed: ", cfg_err)
            goto schedule
        end

        local cfg_data = cfg_resp.data
        if not cfg_data then
            goto schedule
        end

        -- Store lua config in shared_dict
        if cfg_data.lua_config then
            config.store_lua_config(cfg_data.lua_config)
            ngx.log(ngx.INFO, "Lua config updated")
        end

        -- Store rate limit config in shared_dict
        if cfg_data.rate_limit_config then
            config.store_rate_limit_config(cfg_data.rate_limit_config)

            -- Store enforcements in Redis for persistent access
            if cfg_data.rate_limit_config.enforcements then
                redis_store.store_enforcements(cfg_data.rate_limit_config.enforcements)
            end

            ngx.log(ngx.INFO, "Rate limit config updated")
        end

        -- Store service type
        if cfg_data.service_type then
            config.store_service_type(cfg_data.service_type)
        end

        -- Store version
        if cfg_data.version then
            config.store_version(cfg_data.version)
        end

        ngx.log(ngx.INFO, "Config updated to version ", cfg_data.version)

        -- Send ACK to UHDadmin
        if ver_data.snapshot_id then
            api_request("POST", "/ack", {
                snapshot_id = ver_data.snapshot_id,
                status = "applied",
            })
        end
    end

    ::schedule::
    local ok, timer_err = ngx.timer.at(CONFIG_PULL_INTERVAL, pull_config)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule config pull timer: ", timer_err)
    end
end

-- ==================== Telemetry Flush ====================

local function flush_telemetry(premature)
    if premature then return end

    -- Flush access logs
    local access_logs = telemetry.flush_access_logs(500)
    if #access_logs > 0 then
        local resp, err = api_request("POST", "/../slave/telemetry/access-logs", {
            entries = access_logs,
        })
        if not resp then
            ngx.log(ngx.ERR, "Telemetry flush (access logs) failed: ", err,
                    " (", #access_logs, " entries lost)")
        else
            ngx.log(ngx.INFO, "Flushed ", #access_logs, " access log entries")
        end
    end

    -- Flush blocked requests
    local blocked = telemetry.flush_blocked_requests(200)
    if #blocked > 0 then
        local resp, err = api_request("POST", "/../slave/telemetry/blocked-requests", {
            entries = blocked,
        })
        if not resp then
            ngx.log(ngx.ERR, "Telemetry flush (blocked) failed: ", err,
                    " (", #blocked, " entries lost)")
        else
            ngx.log(ngx.INFO, "Flushed ", #blocked, " blocked request entries")
        end
    end

    -- Flush pending token reports to UHDadmin
    local token_reports = redis_store.scan_token_reports(100)
    if #token_reports > 0 then
        local events = {}
        for _, t in ipairs(token_reports) do
            events[#events + 1] = {
                event_type = "login",
                emby_user_id = t.user_id,
                emby_username = t.username,
                device_id = t.device_id,
                device_name = t.device_name,
                client_name = t.client_name,
                client_version = t.client_version,
                client_ip = t.client_ip or "unknown",
                success = true,
            }
        end

        for _, event in ipairs(events) do
            api_request("POST", "/../slave/telemetry/login", event)
        end

        ngx.log(ngx.INFO, "Reported ", #events, " token/login events")
    end

    local ok, timer_err = ngx.timer.at(TELEMETRY_FLUSH_INTERVAL, flush_telemetry)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule telemetry flush timer: ", timer_err)
    end
end

-- ==================== Quota Sync ====================
-- Read counters from Redis, report to UHDadmin, store remaining back to Redis

local function sync_quotas(premature)
    if premature then return end

    -- Scan all quota counters from Redis
    local counters = redis_store.scan_quota_counters()

    if #counters > 0 then
        -- Report to UHDadmin and receive remaining capacity
        local resp, err = api_request("POST", "/../slave/telemetry/quota-sync", {
            counters = counters,
        })

        if not resp then
            ngx.log(ngx.ERR, "Quota sync failed: ", err)
        else
            ngx.log(ngx.INFO, "Synced ", #counters, " quota counters")

            -- Store remaining capacity from UHDadmin response into Redis
            if resp.data and resp.data.remaining then
                redis_store.store_remaining(resp.data.remaining)
                ngx.log(ngx.INFO, "Updated ", #resp.data.remaining, " remaining quotas")
            end

            -- Store enforcements from response into Redis
            if resp.data and resp.data.enforcements then
                redis_store.store_enforcements(resp.data.enforcements)
                ngx.log(ngx.INFO, "Updated ", #resp.data.enforcements, " enforcements")
            end
        end
    end

    -- Also pull latest enforcements + rate limit rules independently
    local enf_resp, enf_err = api_request("GET", "/rate-limits")
    if enf_resp and enf_resp.data then
        if enf_resp.data.enforcements then
            redis_store.store_enforcements(enf_resp.data.enforcements)
        end
        if enf_resp.data.rules then
            config.store_rate_limit_config(enf_resp.data)
        end
    end

    local ok, timer_err = ngx.timer.at(QUOTA_SYNC_INTERVAL, sync_quotas)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule quota sync timer: ", timer_err)
    end
end

-- ==================== Token Resolve (Plan B) ====================
-- Query Emby/Jellyfin Sessions API to build token→user mappings
-- for tokens not captured during login (e.g., after Slave restart)

local function resolve_tokens(premature)
    if premature then return end

    if not EMBY_SERVER_URL or EMBY_SERVER_URL == "" or
       not EMBY_API_KEY or EMBY_API_KEY == "" then
        goto schedule
    end

    do
        local sessions, err = emby_request("GET", "/emby/Sessions")
        if not sessions then
            ngx.log(ngx.WARN, "Token resolve: failed to query Emby sessions: ", err)
            goto schedule
        end

        local resolved = 0
        for _, session in ipairs(sessions) do
            local user_id = session.UserId
            local device_id = session.DeviceId

            if user_id and device_id then
                -- Check if we already have a mapping for this device
                -- (Sessions API doesn't return tokens directly, but we can
                --  build device_id → user_id mappings as fallback)
                local device_key = "device_user:" .. device_id
                local red, redis_err = redis_store.connect()
                if red then
                    local existing = red:get(device_key)
                    if not existing or existing == ngx.null then
                        local info = {
                            user_id = user_id,
                            username = session.UserName,
                            device_id = device_id,
                            device_name = session.DeviceName,
                            client_name = session.Client,
                            client_version = session.ApplicationVersion,
                            resolved_from = "emby_sessions_api",
                        }
                        red:set(device_key, cjson.encode(info), "EX", 604800)
                        resolved = resolved + 1
                    end
                    redis_store.keepalive(red)
                end
            end
        end

        if resolved > 0 then
            ngx.log(ngx.INFO, "Token resolve: resolved ", resolved, " device→user mappings from Emby sessions")
        end
    end

    ::schedule::
    local ok, timer_err = ngx.timer.at(TOKEN_RESOLVE_INTERVAL, resolve_tokens)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule token resolve timer: ", timer_err)
    end
end

-- ==================== Session Heartbeat ====================
-- Report active streaming sessions to UHDadmin for cross-Slave coordination

local function session_heartbeat(premature)
    if premature then return end

    -- Scan all active sessions from Redis
    local sessions = redis_store.scan_all_sessions()

    if #sessions > 0 then
        -- Format for UHDadmin realtime heartbeat API
        local session_data = {}
        for _, s in ipairs(sessions) do
            session_data[#session_data + 1] = {
                session_id = s.play_session_id,
                emby_user_id = s.user_id,
                device_id = s.device_id,
                device_name = s.device_name,
                client_name = s.client_name,
                client_ip = s.client_ip,
                is_playing = true,
                is_paused = false,
                started_at = s.started_at,
            }
        end

        local resp, err = api_request("POST", "/../slave/telemetry/realtime/heartbeat", {
            sessions = session_data,
        })

        if not resp then
            ngx.log(ngx.ERR, "Session heartbeat failed: ", err)
        else
            ngx.log(ngx.INFO, "Session heartbeat: ", #session_data, " active sessions reported")
        end
    else
        -- Report empty to clear stale sessions
        api_request("POST", "/../slave/telemetry/realtime/heartbeat", {
            sessions = {},
        })
    end

    local ok, timer_err = ngx.timer.at(SESSION_HEARTBEAT_INTERVAL, session_heartbeat)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule session heartbeat timer: ", timer_err)
    end
end

-- ==================== Heartbeat ====================

local function send_heartbeat(premature)
    if premature then return end

    local active_sessions = redis_store.scan_all_sessions()

    local resp, err = api_request("POST", "/heartbeat", {
        agent_version = AGENT_VERSION,
        current_config_version = config.get_version(),
        status = "online",
        metadata = {
            telemetry = telemetry.get_counts(),
            active_sessions = #active_sessions,
        },
    })

    if not resp then
        ngx.log(ngx.ERR, "Heartbeat failed: ", err)
    end

    local ok, timer_err = ngx.timer.at(HEARTBEAT_INTERVAL, send_heartbeat)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule heartbeat timer: ", timer_err)
    end
end

-- ==================== Start Timers ====================
-- Only start on worker 0 to avoid duplicate API calls from multiple workers

if ngx.worker.id() == 0 then
    ngx.log(ngx.INFO, "UHD Slave agent v", AGENT_VERSION, " starting on worker 0")
    ngx.log(ngx.INFO, "UHDadmin URL: ", UHDADMIN_URL)
    if EMBY_SERVER_URL ~= "" then
        ngx.log(ngx.INFO, "Emby server URL: ", EMBY_SERVER_URL)
    end

    -- Initial config pull (delay 1s to let nginx fully start)
    ngx.timer.at(1, pull_config)

    -- Start periodic timers (staggered to avoid thundering herd)
    ngx.timer.at(5, flush_telemetry)
    ngx.timer.at(10, sync_quotas)
    ngx.timer.at(3, send_heartbeat)
    ngx.timer.at(7, resolve_tokens)
    ngx.timer.at(8, session_heartbeat)

    ngx.log(ngx.INFO, "Background timers scheduled: config=", CONFIG_PULL_INTERVAL,
            "s telemetry=", TELEMETRY_FLUSH_INTERVAL,
            "s quota=", QUOTA_SYNC_INTERVAL,
            "s heartbeat=", HEARTBEAT_INTERVAL,
            "s token_resolve=", TOKEN_RESOLVE_INTERVAL,
            "s session_hb=", SESSION_HEARTBEAT_INTERVAL, "s")
end
