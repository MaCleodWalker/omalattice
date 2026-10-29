local source = debug and debug.getinfo(1, "S").source
if type(source) ~= "string" or source:sub(1, 1) ~= "@" then
    error("omalattice: unable to resolve plugin directory")
end

local integration_dir = source:sub(2):match("^(.*)/[^/]*$")
local root_dir = integration_dir and integration_dir:match("^(.*)/integration$")
if not root_dir then error("omalattice: invalid plugin directory") end

local config = dofile(root_dir .. "/layout/config.lua")
local settings = dofile(root_dir .. "/layout/settings.lua")
local _, defaults = settings.apply(config)
local ok, publish_err = settings.publish(config, defaults)
if not ok then io.stderr:write("omalattice: unable to publish settings: " .. tostring(publish_err) .. "\n") end

local pinned = config.workspace
if pinned ~= nil and (type(pinned) ~= "number" or pinned < 1 or pinned % 1 ~= 0) then
    error("omalattice: config.workspace must be a positive integer")
end

local workspaces = dofile(root_dir .. "/integration/workspaces.lua")

-- Workspaces rotated into Omalattice with Super+L are restored here, and an
-- optional config.workspace stays pinned to the layout.
local function apply_workspaces()
    if pinned ~= nil then workspaces.apply(pinned) end
    workspaces.restore()
    -- Restored workspaces switch layout after this returns and no event
    -- announces it, so layout-dependent state is refreshed afterwards.
    local resync = rawget(_G, "__omalattice_resync_later")
    if resync then resync() end
    local configure_pan = rawget(_G, "__omalattice_configure_three_finger_pan")
    if configure_pan then configure_pan(config.three_finger_pan ~= false) end
end

if rawget(_G, "__omalattice_plugin_loaded") then
    -- A reload picks up edited settings without restarting Hyprland.
    local reload = rawget(_G, "__omalattice_reload_config")
    if reload then reload(config) end
    local reload_integration = rawget(_G, "__omalattice_reload_integration")
    if reload_integration then reload_integration(config) end
    apply_workspaces()
    return true
end

dofile(root_dir .. "/layout/init.lua")
dofile(root_dir .. "/integration/omarchy.lua")
apply_workspaces()

_G.__omalattice_plugin_loaded = true
return true
