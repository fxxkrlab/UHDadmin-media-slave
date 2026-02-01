-- log_handler.lua: Log phase handler (log_by_lua_file)
-- Collects telemetry data after the request is proxied.
-- Increments Redis quota counters and decrements remaining capacity.
-- Runs in the log phase, so it cannot modify the response.

local telemetry = require("telemetry")
local redis_store = require("redis_store")

-- Collect request info from ngx variables and ctx
local client_name = ngx.ctx.client_name
local client_version = ngx.ctx.client_version
local device_id = ngx.ctx.device_id
local user_id = ngx.ctx.user_id
local client_ip = ngx.var.remote_addr
local bytes_sent = tonumber(ngx.var.bytes_sent) or 0
local request_time = tonumber(ngx.var.request_time) or 0
local upstream_response_time = tonumber(ngx.var.upstream_response_time) or 0
local status = ngx.var.status

-- ==================== Telemetry Buffer (shared_dict) ====================

telemetry.log_access({
    ip = client_ip,
    uri = ngx.var.uri,
    method = ngx.var.request_method,
    status = tonumber(status) or 0,
    bytes_sent = bytes_sent,
    request_time = request_time,
    upstream_time = upstream_response_time,
    client_name = client_name,
    client_version = client_version,
    device_id = device_id,
    user_id = user_id,
    user_agent = ngx.var.http_user_agent,
    timestamp = ngx.now(),
})

-- ==================== Redis Quota Counters + Remaining ====================

-- Period keys for quota tracking
local date = os.date("!*t")  -- UTC
local daily_key = os.date("!%Y-%m-%d")
local monthly_key = os.date("!%Y-%m")

-- TTLs: daily=86400, monthly=2678400 (31 days)
local DAILY_TTL = 86400
local MONTHLY_TTL = 2678400

-- Helper: increment counters + decrement remaining for one dimension
local function track_dimension(dimension, value)
    if not value then return end

    -- Increment quota counters in Redis (absolute, persisted)
    redis_store.incr_quota(dimension, value, "daily", daily_key, 1, bytes_sent, DAILY_TTL)
    redis_store.incr_quota(dimension, value, "monthly", monthly_key, 1, bytes_sent, MONTHLY_TTL)

    -- Decrement local remaining capacity (keeps it accurate between syncs)
    redis_store.decr_remaining(dimension, value, bytes_sent)
end

track_dimension("ip", client_ip)
track_dimension("user", user_id)
track_dimension("device", device_id)
