-- User overrides for layout/config.lua.
--
-- The defaults stay in layout/config.lua. Overrides live in a separate Lua
-- table at ~/.config/omalattice/config.lua (or $OMALATTICE_CONFIG), which the
-- shell menu writes and which survives plugin updates. Only known keys with
-- valid values are applied. The effective values are published for the menu.
local M = {}

local SPEC = {
    workspace = { kind = "integer", min = 1, max = 1000000 },
    peek_x = { kind = "number", min = 0, max = 500 },
    peek_y = { kind = "number", min = 0, max = 500 },
    gap_x = { kind = "number", min = 0, max = 200 },
    gap_y = { kind = "number", min = 0, max = 200 },
    hover_focus_delay = { kind = "number", min = 0, max = 2000 },
    gesture_fingers = { kind = "integer", min = 3, max = 5 },
    overview_gesture_fingers = { kind = "integer", min = 0, max = 5 },
    swipe_distance = { kind = "integer", min = 50, max = 2000 },
    three_finger_pan = { kind = "boolean" },
    workspace_swipe = { kind = "boolean" },
    overview_thumbnails = { kind = "boolean" },
    overview_autoscroll_speed = { kind = "number", min = 0, max = 5000 },
    overview_min_width = { kind = "number", min = 0.05, max = 0.5 },
    overview_min_height = { kind = "number", min = 0.05, max = 0.5 },
    width_steps = { kind = "list", min = 0.1, max = 1 },
    height_steps = { kind = "list", min = 0.1, max = 1 },
    default_width_step = { kind = "integer", min = 1, max = 100 },
    default_height_step = { kind = "integer", min = 1, max = 100 },
}

M.SPEC = SPEC

local function getenv(name)
    local value = os.getenv(name)
    if value and value ~= "" then return value end
end

function M.path()
    local explicit = getenv("OMALATTICE_CONFIG")
    if explicit then return explicit end
    local base = getenv("XDG_CONFIG_HOME")
    if not base then
        local home = getenv("HOME")
        if not home then return nil end
        base = home .. "/.config"
    end
    return base .. "/omalattice/config.lua"
end

function M.status_path()
    local runtime = getenv("XDG_RUNTIME_DIR")
    return runtime and (runtime .. "/omalattice-config") or nil
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, spec)
    return math.max(spec.min, math.min(spec.max, value))
end

-- Returns the cleaned value, or nil when it cannot be used.
local function clean(value, spec)
    if spec.kind == "boolean" then
        if type(value) == "boolean" then return value end
    elseif spec.kind == "number" then
        if finite(value) then return clamp(value, spec) end
    elseif spec.kind == "integer" then
        if finite(value) and value % 1 == 0 then return clamp(value, spec) end
    elseif spec.kind == "list" then
        if type(value) ~= "table" or #value == 0 or #value > 16 then return nil end
        local list = {}
        for index = 1, #value do
            if not finite(value[index]) then return nil end
            list[index] = clamp(value[index], spec)
        end
        return list
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function read_overrides(path)
    -- An empty environment keeps the file to plain data.
    local chunk, err = loadfile(path, "t", {})
    if not chunk then
        -- A missing file just means there is nothing to override.
        if tostring(err):find("cannot open", 1, true) then return nil end
        return nil, err
    end
    local ok, result = pcall(chunk)
    if not ok then return nil, result end
    if type(result) ~= "table" then return nil, "must return a table" end
    return result
end

-- Applies the user's overrides to `config` in place. Returns `config` and a
-- copy of its values from before the overrides.
function M.apply(config)
    local defaults = copy(config)
    local path = M.path()
    if not path then return config, defaults end

    local overrides, err = read_overrides(path)
    if not overrides then
        if err then io.stderr:write("omalattice: ignoring " .. path .. ": " .. tostring(err) .. "\n") end
        return config, defaults
    end

    for key, spec in pairs(SPEC) do
        if overrides[key] ~= nil then
            local value = clean(overrides[key], spec)
            if value == nil then
                io.stderr:write("omalattice: ignoring invalid " .. key .. " in " .. path .. "\n")
            else
                config[key] = value
            end
        end
    end

    -- The default step must point at a preset that exists.
    for _, axis in ipairs({ "width", "height" }) do
        local steps = config[axis .. "_steps"]
        local key = "default_" .. axis .. "_step"
        if type(steps) == "table" and finite(config[key]) then
            config[key] = math.max(1, math.min(#steps, config[key]))
        end
    end

    return config, defaults
end

local function json_string(value)
    return '"' .. tostring(value):gsub('[%c"\\]', function(char)
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end

local function json(value)
    local kind = type(value)
    if kind == "string" then return json_string(value) end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return string.format("%.10g", value) end
    if kind == "table" then
        local items = {}
        if #value > 0 then
            for index = 1, #value do items[index] = json(value[index]) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do table.insert(keys, key) end
        table.sort(keys)
        for _, key in ipairs(keys) do
            table.insert(items, json_string(key) .. ":" .. json(value[key]))
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

-- Publishes the effective and default values for the shell menu.
function M.publish(config, defaults)
    local path = M.status_path()
    if not path then return nil, "XDG_RUNTIME_DIR is not set" end

    local values, base = {}, {}
    for key in pairs(SPEC) do
        values[key] = config[key]
        base[key] = defaults[key]
    end
    local status = string.format('{"path":%s,"values":%s,"defaults":%s}',
        json_string(M.path() or ""), json(values), json(base))

    local file, err = io.open(path, "w")
    if not file then return nil, err end
    local ok, write_err = file:write(status)
    local closed, close_err = file:close()
    if not ok then return nil, write_err end
    if not closed then return nil, close_err end
    return true
end

return M
