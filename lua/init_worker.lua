-- init_worker.lua: Background timer workers (init_worker_by_lua_file)
-- Starts periodic timers for:
-- 1. Config pull from UHDadmin
-- 2. Telemetry flush (access logs + blocked requests)
-- 3. Quota sync (upload counters to UHDadmin)
-- 4. Heartbeat

local cjson = require("cjson.safe")
local config = require("config")
local telemetry = require("telemetry")
local rate_limiter = require("rate_limiter")

-- ==================== Environment Config ====================

local UHDADMIN_URL = os.getenv("UHDADMIN_URL") or "http://localhost:8000"
local APP_TOKEN = os.getenv("APP_TOKEN") or ""
local AGENT_VERSION = "1.0.0"

-- Timer intervals (seconds)
local CONFIG_PULL_INTERVAL = tonumber(os.getenv("CONFIG_PULL_INTERVAL")) or 30
local TELEMETRY_FLUSH_INTERVAL = tonumber(os.getenv("TELEMETRY_FLUSH_INTERVAL")) or 60
local QUOTA_SYNC_INTERVAL = tonumber(os.getenv("QUOTA_SYNC_INTERVAL")) or 300
local HEARTBEAT_INTERVAL = tonumber(os.getenv("HEARTBEAT_INTERVAL")) or 60

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
        -- No update needed
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

        -- Store lua config
        if cfg_data.lua_config then
            config.store_lua_config(cfg_data.lua_config)
            ngx.log(ngx.INFO, "Lua config updated")
        end

        -- Store rate limit config
        if cfg_data.rate_limit_config then
            config.store_rate_limit_config(cfg_data.rate_limit_config)

            -- Store enforcements in enforcement cache for fast lookup
            if cfg_data.rate_limit_config.enforcements then
                rate_limiter.store_enforcements(cfg_data.rate_limit_config.enforcements)
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
        -- Find snapshot_id from version check response
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

    local ok, timer_err = ngx.timer.at(TELEMETRY_FLUSH_INTERVAL, flush_telemetry)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule telemetry flush timer: ", timer_err)
    end
end

-- ==================== Quota Sync ====================

local function sync_quotas(premature)
    if premature then return end

    local rate_dict = ngx.shared.rate_limit

    -- Collect quota counters from shared dict
    local counters = {}
    local keys = rate_dict:get_keys(2000)

    for _, key in ipairs(keys) do
        -- Match quota keys: q:req:<dim>:<val> and q:bw:<dim>:<val>
        local qtype, dimension, dimension_value = key:match("^q:(%a+):(%a+):(.+)$")
        if qtype and dimension and dimension_value then
            local value = rate_dict:get(key)
            if value and value > 0 then
                -- Find or create counter entry
                local counter_key = dimension .. ":" .. dimension_value
                if not counters[counter_key] then
                    counters[counter_key] = {
                        dimension = dimension,
                        dimension_value = dimension_value,
                        request_count = 0,
                        bandwidth_bytes = 0,
                    }
                end
                if qtype == "req" then
                    counters[counter_key].request_count = value
                elseif qtype == "bw" then
                    counters[counter_key].bandwidth_bytes = value
                end
            end
        end
    end

    -- Convert to list and send
    local counter_list = {}
    for _, c in pairs(counters) do
        counter_list[#counter_list + 1] = c
    end

    if #counter_list > 0 then
        local resp, err = api_request("POST", "/../slave/telemetry/quota-sync", {
            counters = counter_list,
        })
        if not resp then
            ngx.log(ngx.ERR, "Quota sync failed: ", err)
        else
            ngx.log(ngx.INFO, "Synced ", #counter_list, " quota counters")
            -- Reset synced counters
            for _, key in ipairs(keys) do
                if key:sub(1, 2) == "q:" then
                    rate_dict:delete(key)
                end
            end
        end
    end

    -- Also pull latest enforcements
    local enf_resp, enf_err = api_request("GET", "/rate-limits")
    if enf_resp and enf_resp.data then
        if enf_resp.data.enforcements then
            rate_limiter.store_enforcements(enf_resp.data.enforcements)
            ngx.log(ngx.INFO, "Updated ", #enf_resp.data.enforcements, " enforcements")
        end
        -- Also update rate limit rules in config
        if enf_resp.data.rules then
            config.store_rate_limit_config(enf_resp.data)
        end
    end

    local ok, timer_err = ngx.timer.at(QUOTA_SYNC_INTERVAL, sync_quotas)
    if not ok then
        ngx.log(ngx.ERR, "Failed to schedule quota sync timer: ", timer_err)
    end
end

-- ==================== Heartbeat ====================

local function send_heartbeat(premature)
    if premature then return end

    local resp, err = api_request("POST", "/heartbeat", {
        agent_version = AGENT_VERSION,
        current_config_version = config.get_version(),
        status = "online",
        metadata = {
            telemetry = telemetry.get_counts(),
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
    ngx.log(ngx.INFO, "UHD Slave agent starting on worker 0")
    ngx.log(ngx.INFO, "UHDadmin URL: ", UHDADMIN_URL)

    -- Initial config pull (delay 1s to let nginx fully start)
    ngx.timer.at(1, pull_config)

    -- Start periodic timers (staggered to avoid thundering herd)
    ngx.timer.at(5, flush_telemetry)
    ngx.timer.at(10, sync_quotas)
    ngx.timer.at(3, send_heartbeat)

    ngx.log(ngx.INFO, "Background timers scheduled: config=", CONFIG_PULL_INTERVAL,
            "s telemetry=", TELEMETRY_FLUSH_INTERVAL,
            "s quota=", QUOTA_SYNC_INTERVAL,
            "s heartbeat=", HEARTBEAT_INTERVAL, "s")
end
