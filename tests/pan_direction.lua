local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)/[^/]+$") or "tests"
local root = arg[1] or tests_dir:match("^(.*)/tests$") or "."
local original_dofile = dofile
local core = original_dofile(root .. "/layout/core.lua")
local config = original_dofile(root .. "/layout/config.lua")
config.three_finger_pan = true
config.workspace_swipe = true
config.overview_gesture_fingers = 0

-- Isolate this replay from the installed plugin's user-settings file.
dofile = function(path)
    if path == root .. "/layout/config.lua" then return config end
    if path == root .. "/layout/settings.lua" then
        return { apply = function() end }
    end
    return original_dofile(path)
end

local natural = true
local gesture
local registered = { ["3:horizontal"] = { action = "workspace" } }
local workspace_layout = "lua:omalattice"
local handlers = {}
local state
local release_direction
local release_target
local initial_visibility
local area = { x = 0, y = 0, w = 1000, h = 800 }
local function settle(direction)
    release_direction = direction
    release_target = direction and core.focus(state, direction)
        or core.most_revealed_window(state, area, config, initial_visibility,
            state.camera.offset_x, state.camera.offset_y)
end
local function reset_state()
    state = core.new_state()
    core.sync(state, { "A", "B" }, "A", config)
end
reset_state()

_G.__omalattice_gestures = {
    pan_begin = function()
        initial_visibility = core.visible_areas(state, area, config)
        return true
    end,
    pan_update = function(dx, dy) assert(core.pan_by(state, dx, dy)) end,
    pan_end = function(_, direction) settle(direction) end,
}
_G.o = { bind = function() end }
_G.hl = {
    get_active_window = function() return { layout = { name = "lua:omalattice" } } end,
    get_active_workspace = function() return { id = 3, tiled_layout = workspace_layout } end,
    get_config = function(key)
        assert(key == "input.touchpad.natural_scroll")
        return natural
    end,
    unbind = function() end,
    on = function(event, callback)
        handlers[event] = handlers[event] or {}
        table.insert(handlers[event], callback)
        return true
    end,
    bind = function() return { set_enabled = function() end } end,
    gesture = function(spec)
        local key = tostring(spec.fingers) .. ":" .. spec.direction
        if spec.action == "unset" then
            assert(registered[key], "attempted to remove an unregistered gesture")
            registered[key] = nil
            return
        end
        assert(not registered[key], "duplicate gesture registration")
        if spec.direction == "horizontal" then
            assert(not registered[tostring(spec.fingers) .. ":swipe"],
                "workspace swipe is shadowed by the still-registered pan gesture")
        end
        registered[key] = spec
        if spec.direction == "swipe" and type(spec.action) == "table" then gesture = spec.action end
    end,
    dispatch = function(dispatcher)
        local dx, dy = dispatcher:match("^pan%-by (%S+) (%S+)$")
        if dx then
            assert(core.pan_by(state, tonumber(dx), tonumber(dy)))
        else
            settle(dispatcher:match("^focus (%S+)$"))
        end
        return { ok = true }
    end,
    dsp = { layout = function(message) return message end },
}
assert(loadfile(root .. "/integration/omarchy.lua"))()
assert(gesture, "continuous pan callback was not registered")

local failures = {}
for _, enabled in ipairs({ true, false }) do
    natural = enabled
    for _, delta in ipairs({
        { x = -20, y = -10 },
        { x = 20, y = 10 },
        { x = -10, y = -20 },
        { x = 10, y = 20 },
    }) do
        reset_state()
        local before = core.placements(state, area, config).A
        gesture.start()
        gesture.update({ delta = delta, time_ms = 10 })
        gesture.update({ delta = delta, time_ms = 15 })
        local after = core.placements(state, area, config).A
        local sign = enabled and 1 or -1
        local expected_x, expected_y = delta.x * 2 * sign, delta.y * 2 * sign
        local expected_direction
        if math.abs(expected_x) > math.abs(expected_y) then
            expected_direction = expected_x < 0 and "right" or "left"
        else
            expected_direction = expected_y < 0 and "down" or "up"
        end
        gesture.finish({ cancelled = false, time_ms = 16 })
        local actual_x, actual_y = after.x - before.x, after.y - before.y
        if math.abs(actual_x - expected_x) > 1e-6 or math.abs(actual_y - expected_y) > 1e-6
            or release_direction ~= expected_direction then
            table.insert(failures, string.format(
                "natural_scroll=%s: expected content delta (%g,%g), release %s; got (%g,%g), release %s",
                tostring(enabled), expected_x, expected_y, expected_direction,
                actual_x, actual_y, tostring(release_direction)))
        end
    end
end
for _, enabled in ipairs({ true, false }) do
    natural = enabled
    for _, col in ipairs({ -1, 1 }) do
        for _, row in ipairs({ -1, 1 }) do
            reset_state()
            core.sync(state, { "A", "B", "C", "D" }, "A", config)
            state.positions = {
                A = { col = 0, row = 0 },
                B = { col = col, row = 0 },
                C = { col = 0, row = row },
                D = { col = col, row = row },
            }
            core.follow(state)
            local boxes = core.placements(state, area, config)
            local sign = enabled and 1 or -1
            local delta = {
                x = (boxes.A.x - boxes.D.x) * sign / 2,
                y = (boxes.A.y - boxes.D.y) * sign / 2,
            }
            gesture.start()
            gesture.update({ delta = delta, time_ms = 10 })
            gesture.update({ delta = delta, time_ms = 15 })
            gesture.finish({ cancelled = false })
            if release_target ~= "D" or release_direction ~= nil then
                table.insert(failures, string.format(
                    "diagonal (%d,%d), natural_scroll=%s: expected visibility-gain diagonal D; got %s via %s",
                    col, row, tostring(enabled), tostring(release_target), tostring(release_direction)))
            end
        end
    end
end
_G.__omalattice_configure_three_finger_pan(false)
assert(not registered["3:swipe"] and registered["3:horizontal"] and registered["3:vertical"],
    "disabling pan must restore axis-based snap gestures")
_G.__omalattice_configure_three_finger_pan(true)
_G.__omalattice_configure_three_finger_pan(true)
assert(registered["3:swipe"] and not registered["3:horizontal"] and not registered["3:vertical"],
    "enabling pan must replace axis-based gestures without duplicates")
for _, layout in ipairs({ "scrolling", "lua:omalattice", "dwindle", "lua:omalattice", "scrolling" }) do
    workspace_layout = layout
    for _, callback in ipairs(handlers["workspace.active"]) do callback() end
    local lattice = layout == "lua:omalattice"
    assert((registered["3:swipe"] ~= nil) == lattice, "pan registration leaked across workspaces")
    assert((registered["3:horizontal"] ~= nil) == not lattice,
        "workspace swipe was not restored outside Omalattice")
    if not lattice then
        assert(registered["3:horizontal"].action == "workspace", "restored wrong horizontal action")
    end
end
dofile = original_dofile
assert(#failures == 0, table.concat(failures, "\n"))
print("ok - actual pan callback moves content and releases in the scroll direction: " .. root)
