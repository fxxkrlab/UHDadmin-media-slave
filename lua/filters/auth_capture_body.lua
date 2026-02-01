-- auth_capture_body.lua: Body filter for login response interception
-- Collects response body chunks from POST /Users/AuthenticateByName,
-- parses the JSON to extract AccessToken + User.Id, and stores the
-- token → user mapping in Redis.
-- Runs in body_filter_by_lua_file phase.

if not ngx.ctx.capture_auth_body then
    return
end

local cjson = require("cjson.safe")
local redis_store = require("redis_store")
local client_detect = require("client_detect")

-- Collect body chunks (response may arrive in multiple chunks)
local chunk = ngx.arg[1]
if chunk and chunk ~= "" then
    local chunks = ngx.ctx.auth_body_chunks
    if chunks then
        chunks[#chunks + 1] = chunk
    end
end

-- ngx.arg[2] == true means this is the last chunk
if not ngx.arg[2] then
    return
end

-- Assemble full body
local chunks = ngx.ctx.auth_body_chunks
if not chunks or #chunks == 0 then
    return
end

local body = table.concat(chunks)
ngx.ctx.auth_body_chunks = nil
ngx.ctx.capture_auth_body = nil

-- Parse response JSON
local data = cjson.decode(body)
if not data then
    ngx.log(ngx.WARN, "auth_capture: failed to parse auth response body")
    return
end

-- Extract token and user info
local token = data.AccessToken
local user = data.User
local session_info = data.SessionInfo

if not token or not user or not user.Id then
    ngx.log(ngx.WARN, "auth_capture: missing AccessToken or User.Id in response")
    return
end

-- Extract client info from request headers (set during access phase or parse now)
local device_id = client_detect.get_device_id()
local device_name = client_detect.get_device_name()
local client_name = client_detect.get_client_name()
local client_version = client_detect.get_client_version()

-- Build token map entry
local token_info = {
    user_id = user.Id,
    username = user.Name,
    device_id = device_id or (session_info and session_info.DeviceId),
    device_name = device_name or (session_info and session_info.DeviceName),
    client_name = client_name or (session_info and session_info.Client),
    client_version = client_version or (session_info and session_info.ApplicationVersion),
    client_ip = ngx.var.remote_addr,
    login_time = ngx.now(),
    is_admin = user.Policy and user.Policy.IsAdministrator or false,
}

-- Store in Redis
local ok, err = redis_store.set_token_map(token, token_info)
if ok then
    ngx.log(ngx.INFO, "auth_capture: stored token mapping for user=",
            token_info.username, " user_id=", token_info.user_id,
            " client=", token_info.client_name or "unknown",
            " device=", token_info.device_name or "unknown")
else
    ngx.log(ngx.ERR, "auth_capture: failed to store token map: ", err)
end
