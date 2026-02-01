-- rate_limiter.lua: L1 rate limiting using shared_dict
-- Implements token bucket algorithm for req/s and req/min.
-- Only handles volatile, short-lived rate limits. Long-lived quota
-- counters and enforcements are handled by redis_store.lua.

local _M = {}

local rate_dict = ngx.shared.rate_limit

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

return _M
