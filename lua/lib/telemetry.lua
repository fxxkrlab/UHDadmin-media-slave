-- telemetry.lua: Telemetry data collection and batching
-- Collects access logs, blocked requests, etc. in shared dict buffers.
-- Background timer flushes batches to UHDadmin.

local cjson = require("cjson.safe")

local _M = {}

local buffer = ngx.shared.telemetry_buffer

--- Add an access log entry to the buffer
function _M.log_access(entry)
    local key = "al:" .. ngx.now() .. ":" .. math.random(100000)
    buffer:set(key, cjson.encode(entry), 300)  -- 5 min TTL

    -- Increment counter
    local count = buffer:get("al_count") or 0
    buffer:set("al_count", count + 1, 300)
end

--- Add a blocked request to the buffer
function _M.log_blocked(entry)
    local key = "bl:" .. ngx.now() .. ":" .. math.random(100000)
    buffer:set(key, cjson.encode(entry), 300)
    local count = buffer:get("bl_count") or 0
    buffer:set("bl_count", count + 1, 300)
end

--- Collect and clear access log entries from buffer
-- @param max_count number: max entries to collect
-- @return table: list of entries
function _M.flush_access_logs(max_count)
    max_count = max_count or 500
    local entries = {}
    local keys = buffer:get_keys(max_count * 2)
    local removed = 0

    for _, key in ipairs(keys) do
        if key:sub(1, 3) == "al:" then
            local raw = buffer:get(key)
            if raw then
                local entry = cjson.decode(raw)
                if entry then
                    entries[#entries + 1] = entry
                end
                buffer:delete(key)
                removed = removed + 1
            end
            if #entries >= max_count then
                break
            end
        end
    end

    -- Reset counter
    local remaining = (buffer:get("al_count") or 0) - removed
    buffer:set("al_count", math.max(0, remaining), 300)

    return entries
end

--- Collect and clear blocked request entries from buffer
function _M.flush_blocked_requests(max_count)
    max_count = max_count or 200
    local entries = {}
    local keys = buffer:get_keys(max_count * 2)
    local removed = 0

    for _, key in ipairs(keys) do
        if key:sub(1, 3) == "bl:" then
            local raw = buffer:get(key)
            if raw then
                local entry = cjson.decode(raw)
                if entry then
                    entries[#entries + 1] = entry
                end
                buffer:delete(key)
                removed = removed + 1
            end
            if #entries >= max_count then
                break
            end
        end
    end

    local remaining = (buffer:get("bl_count") or 0) - removed
    buffer:set("bl_count", math.max(0, remaining), 300)

    return entries
end

--- Get current buffer counts
function _M.get_counts()
    return {
        access_logs = buffer:get("al_count") or 0,
        blocked = buffer:get("bl_count") or 0,
    }
end

return _M
