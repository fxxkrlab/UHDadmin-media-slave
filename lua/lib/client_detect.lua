-- client_detect.lua: Extract client info from Emby/Jellyfin request headers
-- Detects client name, version, device ID, user ID from various header formats.

local _M = {}

--- URL decode a string
local function urldecode(str)
    if not str then
        return nil
    end
    local result, _ = ngx.re.gsub(str, "(%%)([0-9A-Fa-f][0-9A-Fa-f])", function(m)
        return string.char(tonumber(m[2], 16))
    end, "jo")
    return result
end

--- Extract client name from request headers
function _M.get_client_name()
    local headers = ngx.req.get_headers()

    -- 1. X-Emby-Authorization header: Client="xxx"
    local emby_auth = headers["X-Emby-Authorization"]
    if emby_auth then
        local client = emby_auth:match('Client="(.-)"')
        if client then return client end
    end

    -- 2. Authorization header: Client="xxx"
    local auth = headers["Authorization"]
    if auth then
        local client = auth:match('Client="(.-)"')
        if client then return client end
    end

    -- 3. X-Emby-Client header
    local emby_client = headers["X-Emby-Client"]
    if emby_client then
        return emby_client
    end

    -- 4. Query parameter X-Emby-Client
    local args = ngx.req.get_uri_args()
    local arg_client = args["X-Emby-Client"]
    if arg_client then
        return urldecode(arg_client)
    end

    -- 5. User-Agent prefix (before /)
    local ua = headers["User-Agent"]
    if ua then
        local client = ua:match("^([^/]+)")
        if client then
            return urldecode(client)
        end
    end

    return nil
end

--- Extract client version from request headers
function _M.get_client_version()
    local headers = ngx.req.get_headers()

    -- 1. X-Emby-Authorization: Version="xxx"
    local emby_auth = headers["X-Emby-Authorization"]
    if emby_auth then
        local ver = emby_auth:match('Version="(.-)"')
        if ver then return ver end
    end

    -- 2. Authorization: Version="xxx"
    local auth = headers["Authorization"]
    if auth then
        local ver = auth:match('Version="(.-)"')
        if ver then return ver end
    end

    -- 3. X-Emby-Client-Version header
    local ver_header = headers["X-Emby-Client-Version"]
    if ver_header then
        return ver_header
    end

    -- 4. Query parameter
    local args = ngx.req.get_uri_args()
    local arg_ver = args["X-Emby-Client-Version"]
    if arg_ver then
        return arg_ver
    end

    -- 5. User-Agent version pattern
    local ua = headers["User-Agent"]
    if ua then
        local ver = ua:match("%d+%.%d+%.%d+")
        if ver then return ver end
        ver = ua:match("%d+%.%d+")
        if ver then return ver end
    end

    return nil
end

--- Extract device ID
function _M.get_device_id()
    local headers = ngx.req.get_headers()

    -- X-Emby-Authorization: DeviceId="xxx"
    local emby_auth = headers["X-Emby-Authorization"]
    if emby_auth then
        local id = emby_auth:match('DeviceId="(.-)"')
        if id then return id end
    end

    local auth = headers["Authorization"]
    if auth then
        local id = auth:match('DeviceId="(.-)"')
        if id then return id end
    end

    local args = ngx.req.get_uri_args()
    return args["DeviceId"] or args["deviceId"]
end

--- Extract user ID from token or headers
function _M.get_user_id()
    local headers = ngx.req.get_headers()

    -- X-Emby-Authorization: UserId="xxx"
    local emby_auth = headers["X-Emby-Authorization"]
    if emby_auth then
        local id = emby_auth:match('UserId="(.-)"')
        if id then return id end
    end

    local auth = headers["Authorization"]
    if auth then
        local id = auth:match('UserId="(.-)"')
        if id then return id end
    end

    local args = ngx.req.get_uri_args()
    return args["UserId"] or args["userId"]
end

--- Extract Emby token
function _M.get_token()
    local headers = ngx.req.get_headers()

    -- X-Emby-Token header
    local token = headers["X-Emby-Token"]
    if token then return token end

    -- X-Emby-Authorization: Token="xxx"
    local emby_auth = headers["X-Emby-Authorization"]
    if emby_auth then
        local t = emby_auth:match('Token="(.-)"')
        if t then return t end
    end

    local auth = headers["Authorization"]
    if auth then
        local t = auth:match('Token="(.-)"')
        if t then return t end
    end

    -- Query parameter
    local args = ngx.req.get_uri_args()
    return args["X-Emby-Token"] or args["api_key"]
end

--- Semantic version comparison: returns true if current >= required
function _M.is_version_sufficient(current, required)
    if not current or not required then
        return false
    end

    local function version_to_table(v)
        local t = {}
        for num in v:gmatch("%d+") do
            t[#t + 1] = tonumber(num)
        end
        return t
    end

    local cur = version_to_table(current)
    local req = version_to_table(required)

    for i = 1, math.max(#cur, #req) do
        local c = cur[i] or 0
        local r = req[i] or 0
        if c < r then return false end
        if c > r then return true end
    end
    return true
end

return _M
