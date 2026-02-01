-- auth_capture_header.lua: Header filter for login response interception
-- Marks responses from POST /Users/AuthenticateByName for body capture.
-- Runs in header_filter_by_lua_file phase.

-- Only capture successful auth responses
if ngx.status ~= 200 then
    return
end

-- Check if this is an auth request (set by access phase or by URI match)
local uri = ngx.var.uri or ""
local method = ngx.var.request_method or ""

-- Match Emby/Jellyfin auth endpoints
if method ~= "POST" then
    return
end

local is_auth = false
if uri:match("/[Uu]sers/[Aa]uthenticateByName") then
    is_auth = true
elseif uri:match("/[Uu]sers/[Aa]uthenticateWithQuickConnect") then
    is_auth = true
end

if not is_auth then
    return
end

-- Mark for body capture
ngx.ctx.capture_auth_body = true
ngx.ctx.auth_body_chunks = {}
