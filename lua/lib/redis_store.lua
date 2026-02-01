-- redis_store.lua: Redis connection pool and helper operations
-- Provides persistent storage for quota counters, remaining capacity,
-- and enforcement instructions. Survives nginx restarts.

local cjson = require("cjson.safe")

local _M = {}

local REDIS_HOST = os.getenv("REDIS_HOST") or "127.0.0.1"
local REDIS_PORT = tonumber(os.getenv("REDIS_PORT")) or 6379
local REDIS_DB = tonumber(os.getenv("REDIS_DB")) or 0
local REDIS_PASSWORD = os.getenv("REDIS_PASSWORD")

local POOL_SIZE = 100
local POOL_IDLE_TIMEOUT = 10000  -- 10s

--- Get a Redis connection from the pool
-- @return redis instance or nil, error
function _M.connect()
    local redis = require("resty.redis")
    local red = redis:new()
    red:set_timeouts(1000, 1000, 1000)  -- connect, send, read

    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        ngx.log(ngx.ERR, "Redis connect failed: ", err)
        return nil, err
    end

    -- Only auth/select on new connections (not pooled)
    local reused = red:get_reused_times()
    if reused == 0 then
        if REDIS_PASSWORD and REDIS_PASSWORD ~= "" then
            local auth_ok, auth_err = red:auth(REDIS_PASSWORD)
            if not auth_ok then
                ngx.log(ngx.ERR, "Redis auth failed: ", auth_err)
                return nil, auth_err
            end
        end
        if REDIS_DB > 0 then
            red:select(REDIS_DB)
        end
    end

    return red
end

--- Return connection to pool
function _M.keepalive(red)
    if not red then return end
    red:set_keepalive(POOL_IDLE_TIMEOUT, POOL_SIZE)
end

--- Close connection (on error)
function _M.close(red)
    if not red then return end
    red:close()
end

-- ==================== Quota Counter Operations ====================

--- Increment a quota counter
-- @param dimension string: 'ip', 'user', 'device'
-- @param value string: dimension value
-- @param period string: 'daily', 'monthly', etc.
-- @param period_key string: '2026-02-01', '2026-02', etc.
-- @param req_count number: requests to add
-- @param bw_bytes number: bytes to add
-- @param ttl number: TTL in seconds
function _M.incr_quota(dimension, value, period, period_key, req_count, bw_bytes, ttl)
    local red, err = _M.connect()
    if not red then return nil, err end

    local req_key = "quota:req:" .. dimension .. ":" .. value .. ":" .. period .. ":" .. period_key
    local bw_key = "quota:bw:" .. dimension .. ":" .. value .. ":" .. period .. ":" .. period_key

    red:init_pipeline()

    if req_count and req_count > 0 then
        red:incrby(req_key, req_count)
        red:expire(req_key, ttl)
    end

    if bw_bytes and bw_bytes > 0 then
        red:incrby(bw_key, bw_bytes)
        red:expire(bw_key, ttl)
    end

    local results, pipeline_err = red:commit_pipeline()
    _M.keepalive(red)

    if not results then
        return nil, pipeline_err
    end
    return true
end

--- Get quota counter values
-- @return req_count, bw_bytes
function _M.get_quota(dimension, value, period, period_key)
    local red, err = _M.connect()
    if not red then return 0, 0 end

    local req_key = "quota:req:" .. dimension .. ":" .. value .. ":" .. period .. ":" .. period_key
    local bw_key = "quota:bw:" .. dimension .. ":" .. value .. ":" .. period .. ":" .. period_key

    red:init_pipeline()
    red:get(req_key)
    red:get(bw_key)

    local results, pipeline_err = red:commit_pipeline()
    _M.keepalive(red)

    if not results then return 0, 0 end

    local req_count = tonumber(results[1]) or 0
    local bw_bytes = tonumber(results[2]) or 0
    return req_count, bw_bytes
end

--- Get all quota counter keys matching a pattern
-- @return table of {dimension, value, period, period_key, request_count, bandwidth_bytes}
function _M.scan_quota_counters()
    local red, err = _M.connect()
    if not red then return {} end

    local counters = {}
    local cursor = "0"
    local seen = {}

    repeat
        local res, scan_err = red:scan(cursor, "MATCH", "quota:req:*", "COUNT", 200)
        if not res then
            ngx.log(ngx.ERR, "Redis SCAN failed: ", scan_err)
            break
        end

        cursor = res[1]
        local keys = res[2]

        for _, req_key in ipairs(keys) do
            if not seen[req_key] then
                seen[req_key] = true
                -- Parse key: quota:req:<dim>:<val>:<period>:<period_key>
                local dim, val, period, period_key = req_key:match(
                    "^quota:req:(%a+):(.+):(%a+):(.+)$"
                )
                if dim and val and period and period_key then
                    local bw_key = "quota:bw:" .. dim .. ":" .. val .. ":" .. period .. ":" .. period_key
                    local req_count = red:get(req_key)
                    local bw_bytes = red:get(bw_key)

                    counters[#counters + 1] = {
                        dimension = dim,
                        dimension_value = val,
                        period_type = period,
                        period_key = period_key,
                        request_count = tonumber(req_count) or 0,
                        bandwidth_bytes = tonumber(bw_bytes) or 0,
                    }
                end
            end
        end
    until cursor == "0"

    _M.keepalive(red)
    return counters
end

-- ==================== Remaining Capacity Operations ====================

--- Store remaining capacity (from UHDadmin sync response)
-- @param items table: list of {dimension, value, period, requests_left, bandwidth_left}
function _M.store_remaining(items)
    if not items or #items == 0 then return end

    local red, err = _M.connect()
    if not red then return nil, err end

    red:init_pipeline()

    for _, item in ipairs(items) do
        local req_key = "remain:req:" .. item.dimension .. ":" .. item.dimension_value .. ":" .. item.period
        local bw_key = "remain:bw:" .. item.dimension .. ":" .. item.dimension_value .. ":" .. item.period

        if item.requests_left then
            red:set(req_key, item.requests_left, "EX", 600)  -- 10min TTL, refreshed on sync
        end
        if item.bandwidth_left then
            red:set(bw_key, item.bandwidth_left, "EX", 600)
        end
    end

    red:commit_pipeline()
    _M.keepalive(red)
    return true
end

--- Check remaining capacity for a dimension
-- @return requests_left (number or nil), bandwidth_left (number or nil)
--   nil means no quota data (allow by default)
function _M.get_remaining(dimension, value)
    local red, err = _M.connect()
    if not red then return nil, nil end

    -- Check all period types: daily, weekly, monthly
    local periods = {"daily", "weekly", "monthly"}
    local min_req_left = nil
    local min_bw_left = nil

    red:init_pipeline()
    for _, period in ipairs(periods) do
        red:get("remain:req:" .. dimension .. ":" .. value .. ":" .. period)
        red:get("remain:bw:" .. dimension .. ":" .. value .. ":" .. period)
    end

    local results, pipeline_err = red:commit_pipeline()
    _M.keepalive(red)

    if not results then return nil, nil end

    -- Find the minimum remaining across all periods
    for i = 1, #periods do
        local req_left = tonumber(results[(i - 1) * 2 + 1])
        local bw_left = tonumber(results[(i - 1) * 2 + 2])

        if req_left then
            if not min_req_left or req_left < min_req_left then
                min_req_left = req_left
            end
        end
        if bw_left then
            if not min_bw_left or bw_left < min_bw_left then
                min_bw_left = bw_left
            end
        end
    end

    return min_req_left, min_bw_left
end

--- Decrement remaining capacity (called in log phase after each request)
-- @param dimension string
-- @param value string
-- @param bw_bytes number: bytes sent
function _M.decr_remaining(dimension, value, bw_bytes)
    local red, err = _M.connect()
    if not red then return end

    local periods = {"daily", "weekly", "monthly"}

    red:init_pipeline()
    for _, period in ipairs(periods) do
        local req_key = "remain:req:" .. dimension .. ":" .. value .. ":" .. period
        local bw_key = "remain:bw:" .. dimension .. ":" .. value .. ":" .. period
        -- DECRBY only affects keys that exist (returns error for non-existent, which we ignore)
        red:decrby(req_key, 1)
        if bw_bytes and bw_bytes > 0 then
            red:decrby(bw_key, bw_bytes)
        end
    end

    red:commit_pipeline()
    _M.keepalive(red)
end

-- ==================== Token Map Operations ====================

local TOKEN_MAP_TTL = 604800  -- 7 days

--- Store a token → user mapping (from login intercept or API resolve)
-- @param token string: Emby access token
-- @param info table: {user_id, username, device_id, device_name, client_name, client_version}
function _M.set_token_map(token, info)
    if not token or not info then return nil end

    local red, err = _M.connect()
    if not red then return nil, err end

    local key = "token_map:" .. token
    local json = cjson.encode(info)
    if not json then
        _M.keepalive(red)
        return nil, "json encode failed"
    end

    red:set(key, json, "EX", TOKEN_MAP_TTL)

    -- Also mark for pending report to UHDadmin
    local report_key = "token_report:" .. ngx.now() .. ":" .. math.random(100000)
    info.token = token
    local report_json = cjson.encode(info)
    if report_json then
        red:set(report_key, report_json, "EX", 600)  -- 10 min TTL for report queue
    end

    _M.keepalive(red)
    return true
end

--- Get token → user mapping
-- @param token string
-- @return table or nil: {user_id, username, device_id, device_name, ...}
function _M.get_token_map(token)
    if not token then return nil end

    local red, err = _M.connect()
    if not red then return nil end

    local key = "token_map:" .. token
    local raw = red:get(key)
    _M.keepalive(red)

    if not raw or raw == ngx.null then
        return nil
    end

    return cjson.decode(raw)
end

--- Refresh token map TTL (called on each request with known token)
function _M.touch_token_map(token)
    if not token then return end

    local red, err = _M.connect()
    if not red then return end

    local key = "token_map:" .. token
    red:expire(key, TOKEN_MAP_TTL)
    _M.keepalive(red)
end

--- Scan pending token reports (for flush to UHDadmin)
-- @param max number: max items to return
-- @return table of token info items
function _M.scan_token_reports(max)
    local red, err = _M.connect()
    if not red then return {} end

    local reports = {}
    local cursor = "0"

    repeat
        local res = red:scan(cursor, "MATCH", "token_report:*", "COUNT", 100)
        if not res then break end

        cursor = res[1]
        for _, key in ipairs(res[2]) do
            local raw = red:get(key)
            if raw and raw ~= ngx.null then
                local item = cjson.decode(raw)
                if item then
                    reports[#reports + 1] = item
                    red:del(key)
                end
            end
            if #reports >= (max or 100) then break end
        end
    until cursor == "0" or #reports >= (max or 100)

    _M.keepalive(red)
    return reports
end

-- ==================== Active Session Operations ====================

local SESSION_TTL = 90  -- seconds, auto-expire if no streaming requests

--- Register or refresh an active session
-- @param user_id string
-- @param play_session_id string
-- @param info table: {device_id, device_name, client_name, item_id, ...}
function _M.register_session(user_id, play_session_id, info)
    if not user_id or not play_session_id then return nil end

    local red, err = _M.connect()
    if not red then return nil, err end

    local key = "active_session:" .. user_id .. ":" .. play_session_id
    local existing = red:get(key)

    if existing and existing ~= ngx.null then
        -- Refresh TTL + update bytes_sent
        local data = cjson.decode(existing)
        if data and info.bytes_sent then
            data.bytes_sent = (data.bytes_sent or 0) + (info.bytes_sent or 0)
            data.last_seen = ngx.now()
            red:set(key, cjson.encode(data), "EX", SESSION_TTL)
        else
            red:expire(key, SESSION_TTL)
        end
    else
        -- New session
        info.started_at = info.started_at or ngx.now()
        info.last_seen = ngx.now()
        info.bytes_sent = info.bytes_sent or 0
        local json = cjson.encode(info)
        if json then
            red:set(key, json, "EX", SESSION_TTL)
        end
    end

    _M.keepalive(red)
    return true
end

--- Check if a session already exists
function _M.session_exists(user_id, play_session_id)
    if not user_id or not play_session_id then return false end

    local red, err = _M.connect()
    if not red then return false end

    local key = "active_session:" .. user_id .. ":" .. play_session_id
    local exists = red:exists(key)
    _M.keepalive(red)

    return exists == 1
end

--- Count active sessions for a user
-- @return number
function _M.count_user_sessions(user_id)
    if not user_id then return 0 end

    local red, err = _M.connect()
    if not red then return 0 end

    local count = 0
    local cursor = "0"
    local pattern = "active_session:" .. user_id .. ":*"

    repeat
        local res = red:scan(cursor, "MATCH", pattern, "COUNT", 100)
        if not res then break end
        cursor = res[1]
        count = count + #res[2]
    until cursor == "0"

    _M.keepalive(red)
    return count
end

--- Get all active sessions for a user
-- @return table of {play_session_id, info}
function _M.get_user_sessions(user_id)
    if not user_id then return {} end

    local red, err = _M.connect()
    if not red then return {} end

    local sessions = {}
    local cursor = "0"
    local pattern = "active_session:" .. user_id .. ":*"
    local prefix_len = #("active_session:" .. user_id .. ":")

    repeat
        local res = red:scan(cursor, "MATCH", pattern, "COUNT", 100)
        if not res then break end
        cursor = res[1]
        for _, key in ipairs(res[2]) do
            local raw = red:get(key)
            if raw and raw ~= ngx.null then
                local info = cjson.decode(raw)
                if info then
                    info.play_session_id = key:sub(prefix_len + 1)
                    sessions[#sessions + 1] = info
                end
            end
        end
    until cursor == "0"

    _M.keepalive(red)
    return sessions
end

--- Get ALL active sessions across all users (for heartbeat reporting)
-- @return table
function _M.scan_all_sessions()
    local red, err = _M.connect()
    if not red then return {} end

    local sessions = {}
    local cursor = "0"

    repeat
        local res = red:scan(cursor, "MATCH", "active_session:*", "COUNT", 200)
        if not res then break end
        cursor = res[1]
        for _, key in ipairs(res[2]) do
            local raw = red:get(key)
            if raw and raw ~= ngx.null then
                local info = cjson.decode(raw)
                if info then
                    -- Parse user_id and play_session_id from key
                    local uid, psid = key:match("^active_session:(.+):([^:]+)$")
                    if uid and psid then
                        info.user_id = uid
                        info.play_session_id = psid
                        sessions[#sessions + 1] = info
                    end
                end
            end
        end
    until cursor == "0"

    _M.keepalive(red)
    return sessions
end

-- ==================== Enforcement Operations ====================

--- Store enforcements from UHDadmin
-- @param enforcements table: list of enforcement items
function _M.store_enforcements(enforcements)
    if not enforcements then return end

    local red, err = _M.connect()
    if not red then return nil, err end

    -- Clear old enforcement keys first
    local cursor = "0"
    repeat
        local res = red:scan(cursor, "MATCH", "enforce:*", "COUNT", 100)
        if res then
            cursor = res[1]
            for _, key in ipairs(res[2]) do
                red:del(key)
            end
        else
            break
        end
    until cursor == "0"

    -- Store new enforcements
    for _, e in ipairs(enforcements) do
        local key = "enforce:" .. e.dimension .. ":" .. e.dimension_value
        local json = cjson.encode(e)
        if json then
            -- Calculate TTL from effective_until
            local ttl = 600  -- default 10 min
            if e.effective_until then
                -- Parse ISO timestamp to calculate remaining seconds
                -- Fallback to 10 min if parsing fails
                local y, mo, d, h, mi, s = e.effective_until:match(
                    "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
                )
                if y then
                    local t = os.time({
                        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
                    })
                    local remaining = t - os.time()
                    if remaining > 0 then
                        ttl = remaining
                    end
                end
            end
            red:set(key, json, "EX", ttl)
        end
    end

    _M.keepalive(red)
    return true
end

--- Check enforcement for a dimension
-- @return enforcement table or nil
function _M.check_enforcement(dimension, value)
    local red, err = _M.connect()
    if not red then return nil end

    local key = "enforce:" .. dimension .. ":" .. value
    local raw = red:get(key)
    _M.keepalive(red)

    if not raw or raw == ngx.null then
        return nil
    end

    return cjson.decode(raw)
end

return _M
