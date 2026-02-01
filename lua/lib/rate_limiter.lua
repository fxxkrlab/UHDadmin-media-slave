-- rate_limiter.lua: L1 rate limiting using shared_dict
-- Implements token bucket algorithm for req/s and req/min.

local _M = {}

local rate_dict = ngx.shared.rate_limit
local enf_dict = ngx.shared.enforcement_cache

--- Check rate limit for a key (e.g., "ip:1.2.3.4" or "user:abc123")
-- @param key string: the rate limit key
-- @param rate number: allowed requests per second
-- @param burst number: burst capacity
-- @return boolean: true if allowed, false if over limit
function _M.check_rate(key, rate, burst)
    if not rate or rate <= 0 then
        return true
    end

    burst = burst or rate

    local rkey = "rl:" .. key
    local current = rate_dict:get(rkey)

    if not current then
        -- First request: init with burst - 1
        rate_dict:set(rkey, burst - 1, 1 / rate)
        return true
    end

    if current <= 0 then
        return false
    end

    -- Decrement
    local new_val = rate_dict:incr(rkey, -1)
    return new_val >= 0
end

--- Simple sliding window counter for req/min
-- @param key string: counter key
-- @param limit number: max requests per minute
-- @return boolean: true if allowed
function _M.check_minute_rate(key, limit)
    if not limit or limit <= 0 then
        return true
    end

    local mkey = "rm:" .. key
    local count = rate_dict:get(mkey)

    if not count then
        rate_dict:set(mkey, 1, 60)  -- expires in 60s
        return true
    end

    if count >= limit then
        return false
    end

    rate_dict:incr(mkey, 1)
    return true
end

--- Increment quota counter in shared dict (for periodic sync to Redis/UHDadmin)
-- @param dimension string: 'ip', 'user', 'device'
-- @param dimension_value string: the actual value
-- @param bytes number: bytes transferred (for bandwidth quota)
function _M.increment_quota(dimension, dimension_value, bytes)
    if not dimension or not dimension_value then
        return
    end

    -- Request counter
    local req_key = "q:req:" .. dimension .. ":" .. dimension_value
    local current = rate_dict:get(req_key)
    if current then
        rate_dict:incr(req_key, 1)
    else
        rate_dict:set(req_key, 1, 3600)  -- 1 hour TTL
    end

    -- Bandwidth counter
    if bytes and bytes > 0 then
        local bw_key = "q:bw:" .. dimension .. ":" .. dimension_value
        local bw_current = rate_dict:get(bw_key)
        if bw_current then
            rate_dict:incr(bw_key, bytes)
        else
            rate_dict:set(bw_key, bytes, 3600)
        end
    end
end

--- Check if an enforcement is active for the given dimension
-- @param dimension string
-- @param dimension_value string
-- @return table|nil: enforcement entry if active, nil otherwise
function _M.check_enforcement(dimension, dimension_value)
    local cjson = require("cjson.safe")
    local enf_raw = enf_dict:get("enforcements")
    if not enf_raw then
        return nil
    end

    local enforcements = cjson.decode(enf_raw)
    if not enforcements then
        return nil
    end

    for _, e in ipairs(enforcements) do
        if e.dimension == dimension and e.dimension_value == dimension_value then
            return e
        end
    end

    return nil
end

--- Store enforcements in cache (called by agent after config pull)
function _M.store_enforcements(enforcements)
    local cjson = require("cjson.safe")
    local json = cjson.encode(enforcements)
    if json then
        enf_dict:set("enforcements", json, 600)  -- 10 min TTL
    end
end

return _M
