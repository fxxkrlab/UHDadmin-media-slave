-- log_handler.lua: Log phase handler (log_by_lua_file)
-- Collects telemetry data after the request is proxied.
-- Runs in the log phase, so it cannot modify the response.

local telemetry = require("telemetry")
local rate_limiter = require("rate_limiter")

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

-- Log access entry to telemetry buffer
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

-- Increment quota counters for periodic sync to UHDadmin
-- Count by IP
rate_limiter.increment_quota("ip", client_ip, bytes_sent)

-- Count by user (if identified)
if user_id then
    rate_limiter.increment_quota("user", user_id, bytes_sent)
end

-- Count by device (if identified)
if device_id then
    rate_limiter.increment_quota("device", device_id, bytes_sent)
end
