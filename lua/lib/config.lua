-- config.lua: Configuration management
-- Loads config from shared dict (populated by agent) and provides access to it.

local cjson = require("cjson.safe")

local _M = {}

local config_dict = ngx.shared.config_cache

-- Keys in shared dict
local KEY_LUA_CONFIG = "lua_config"
local KEY_RATE_LIMIT_CONFIG = "rate_limit_config"
local KEY_CONFIG_VERSION = "config_version"
local KEY_SERVICE_TYPE = "service_type"

--- Get parsed lua_config
function _M.get_lua_config()
    local raw = config_dict:get(KEY_LUA_CONFIG)
    if not raw then
        return nil
    end
    return cjson.decode(raw)
end

--- Get parsed rate_limit_config
function _M.get_rate_limit_config()
    local raw = config_dict:get(KEY_RATE_LIMIT_CONFIG)
    if not raw then
        return nil
    end
    return cjson.decode(raw)
end

--- Get current config version
function _M.get_version()
    return config_dict:get(KEY_CONFIG_VERSION) or 0
end

--- Get service type
function _M.get_service_type()
    return config_dict:get(KEY_SERVICE_TYPE) or "emby"
end

--- Store config in shared dict (called by agent)
function _M.store_lua_config(config_table)
    local json = cjson.encode(config_table)
    if json then
        config_dict:set(KEY_LUA_CONFIG, json)
        return true
    end
    return false
end

function _M.store_rate_limit_config(config_table)
    local json = cjson.encode(config_table)
    if json then
        config_dict:set(KEY_RATE_LIMIT_CONFIG, json)
        return true
    end
    return false
end

function _M.store_version(version)
    config_dict:set(KEY_CONFIG_VERSION, version)
end

function _M.store_service_type(service_type)
    config_dict:set(KEY_SERVICE_TYPE, service_type)
end

--- Build client whitelist set from lua_config
function _M.get_client_whitelist()
    local cfg = _M.get_lua_config()
    if not cfg or not cfg.allowed_clients then
        return {}
    end

    local set = {}
    for _, name in ipairs(cfg.allowed_clients) do
        set[name] = true
    end
    return set
end

--- Get min versions map
function _M.get_min_versions()
    local cfg = _M.get_lua_config()
    if not cfg then
        return {}
    end
    return cfg.min_versions or {}
end

return _M
