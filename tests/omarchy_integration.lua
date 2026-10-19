local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)/[^/]+$") or "tests"
local root = tests_dir:match("^(.*)/tests$") or "."

local state_home = os.tmpname()
os.remove(state_home)
assert(os.execute("mkdir -p '" .. state_home .. "'"))
local original_getenv = os.getenv
os.getenv = function(name)
    if name == "XDG_STATE_HOME" or name == "XDG_RUNTIME_DIR" then return state_home end
    return original_getenv(name)
end

local function saved_workspaces()
    local file = io.open(state_home .. "/omalattice/workspaces", "r")
    if not file then return "" end
    local content = file:read("*a")
    file:close()
    return content
end

local bindings = {}
local dispatched = {}
local gestures = {}
local live_gestures = {}
local natural_scroll = false
local gesture_errors = 0
local timers = {}
local handlers = {}
local active_layout = "lua:omalattice"
local active_workspace = { id = 3, tiled_layout = "dwindle", special = false }
local workspace_rules = {}
local terminal_launches = 0
local terminal_action_creations = 0
local overview_active = false
_G.__omalattice_is_overview_active = function()
    return overview_active
end

_G.o = {
    bind = function(keys, _, action)
        bindings[keys] = action
    end,
    launch_terminal = function()
        terminal_action_creations = terminal_action_creations + 1
        return function()
            terminal_launches = terminal_launches + 1
        end
    end,
}

local scroll_binds = {}

_G.hl = {
    bind = function(keys, action)
        local bind = { keys = keys, action = action, enabled = true }
        function bind:set_enabled(value) self.enabled = value end
        scroll_binds[keys] = bind
        return bind
    end,
    layout = {
        register = function() end,
    },
    on = function(event, handler)
        handlers[event] = handlers[event] or {}
        table.insert(handlers[event], handler)
        return true
    end,
    timer = function(callback, options)
        table.insert(timers, { callback = callback, options = options })
        return { set_enabled = function() end }
    end,
    unbind = function() end,
    gesture = function(spec)
        if spec.action == "unset" then
            for index, existing in ipairs(live_gestures) do
                if existing.fingers == spec.fingers and existing.direction == spec.direction then
                    table.remove(live_gestures, index)
                    return
                end
            end
            -- Hyprland logs this instead of raising it.
            gesture_errors = gesture_errors + 1
            return
        end
        table.insert(gestures, spec)
        table.insert(live_gestures, spec)
    end,
    workspace_rule = function(rule)
        table.insert(workspace_rules, rule)
    end,
    get_config = function(key)
        assert(key == "input.touchpad.natural_scroll", "unexpected config key " .. key)
        return natural_scroll
    end,
    get_active_workspace = function()
        return active_workspace
    end,
    get_active_window = function()
        return { layout = { name = active_layout } }
    end,
    dispatch = function(value)
        table.insert(dispatched, value)
    end,
    dsp = {
        layout = function(message) return { kind = "layout", message = message } end,
        exec_cmd = function(command) return { kind = "exec", command = command } end,
        focus = function(options) return { kind = "focus", direction = options.direction } end,
        window = {
            swap = function(options) return { kind = "swap", direction = options.direction } end,
            resize = function(options) return { kind = "resize", options = options } end,
        },
        group = {
            prev = function() return { kind = "group-prev" } end,
            next = function() return { kind = "group-next" } end,
        },
    },
}

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
gestures = {}

-- Preserve coverage of the original snap mode with continuous pan disabled.
local original_dofile = dofile
dofile = function(path)
    local result = original_dofile(path)
    if path == root .. "/layout/config.lua" then result.three_finger_pan = false end
    return result
end
assert(loadfile(root .. "/integration/omarchy.lua"))()
dofile = original_dofile
table.sort(gestures, function(a, b) return a.fingers < b.fingers end)
assert(terminal_action_creations == 1, "terminal binding should be captured during integration setup")
assert(#gestures == 2, "vertical grid and overview gestures were not installed")
assert(gestures[1].fingers == 3 and gestures[1].direction == "vertical", "wrong vertical grid gesture")
assert(type(gestures[1].action) == "table" and gestures[1].action.start and gestures[1].action.update
    and gestures[1].action.finish, "swipes should report every step to follow the fingers")

-- Plays a swipe: Hyprland calls start once, update for every step and finish.
local function swipe(gesture, steps, options)
    options = options or {}
    local first = steps[1] or { x = 0, y = 0 }
    gesture.action.start({ phase = "start", direction = options.direction or "NONE", delta = first, time_ms = 0 })
    for index, step in ipairs(steps) do
        gesture.action.update({ phase = "update", delta = step, time_ms = index * 10 })
    end
    gesture.action.finish({ phase = "end", cancelled = options.cancelled == true })
end

assert(type(bindings["SUPER + LEFT"]) == "function", "left binding was not installed")
bindings["SUPER + LEFT"]()
assert(dispatched[#dispatched].kind == "layout", "2D layout did not receive focus")
assert(dispatched[#dispatched].message == "focus left", "wrong 2D focus message")

bindings["SUPER + RETURN"]()
assert(terminal_launches == 1, "Enter should launch the terminal outside overview")

bindings["SUPER + M"]()
assert(dispatched[#dispatched].message == "overview", "overview toggle did not reach the layout")
overview_active = true
bindings["SUPER + RETURN"]()
assert(dispatched[#dispatched].message == "overview-exit", "Enter did not exit the overview")
assert(terminal_launches == 1, "Enter should not launch a terminal in overview")
overview_active = false
bindings["SUPER + ESCAPE"]()
assert(dispatched[#dispatched].message == "overview-exit", "Escape did not exit the overview")

active_layout = "scrolling"
bindings["SUPER + LEFT"]()
assert(dispatched[#dispatched].kind == "focus", "normal layout fallback did not run")
assert(dispatched[#dispatched].direction == "l", "wrong normal focus direction")
local dispatch_count = #dispatched
bindings["SUPER + M"]()
assert(#dispatched == dispatch_count, "overview toggle should not run in another layout")
bindings["SUPER + RETURN"]()
assert(terminal_launches == 2, "Enter should launch the Omarchy terminal outside Omalattice")

-- Without the layout's gesture support a swipe still moves focus once.
active_layout = "lua:omalattice"
swipe(gestures[1], { { x = 0, y = -20 } })
assert(dispatched[#dispatched].kind == "layout", "up swipe did not focus in Omalattice")
assert(dispatched[#dispatched].message == "focus up", "up swipe sent the wrong layout command")
swipe(gestures[1], { { x = 0, y = 20 } })
assert(dispatched[#dispatched].message == "focus down", "down swipe sent the wrong layout command")

natural_scroll = true
swipe(gestures[1], { { x = 0, y = -20 } })
assert(dispatched[#dispatched].message == "focus down", "natural scrolling should invert the up swipe")
natural_scroll = false

-- With it, every step of the swipe drives the grid.
local api_calls = {}
local drag_allowed = true
_G.__omalattice_gestures = {
    drag_begin = function(axis) table.insert(api_calls, { "drag_begin", axis }); return drag_allowed end,
    drag_update = function(delta) table.insert(api_calls, { "drag_update", delta }) end,
    drag_end = function(cancelled) table.insert(api_calls, { "drag_end", cancelled }) end,
    overview_begin = function(direction) table.insert(api_calls, { "overview_begin", direction }); return true end,
    overview_update = function(dy) table.insert(api_calls, { "overview_update", dy }) end,
    overview_end = function(cancelled) table.insert(api_calls, { "overview_end", cancelled }) end,
}
local dispatch_before = #dispatched
swipe(gestures[1], { { x = 0, y = -10 }, { x = 0, y = -15 } })
assert(api_calls[1][1] == "drag_begin" and api_calls[1][2] == "y", "the swipe did not start a vertical drag")
assert(api_calls[2][2] == -10 and api_calls[3][2] == -15, "the drag did not receive each step")
assert(api_calls[4][1] == "drag_end" and api_calls[4][2] == false, "the drag did not end")
assert(#dispatched == dispatch_before, "a followed swipe should not also send a focus command")

api_calls = {}
natural_scroll = true
swipe(gestures[1], { { x = 0, y = -10 } }, { cancelled = true })
assert(api_calls[2][2] == 10, "natural scrolling should make the grid follow the fingers")
assert(api_calls[3][2] == true, "a cancelled swipe should say so")
natural_scroll = false

-- In an open overview the layout declines the drag and focus moves once.
api_calls = {}
drag_allowed = false
swipe(gestures[1], { { x = 0, y = 20 } })
assert(dispatched[#dispatched].message == "focus down", "a declined drag should still move focus")
drag_allowed = true

-- Four-finger swipes drive the overview with the swipe's direction.
assert(gestures[2].fingers == 4 and gestures[2].direction == "vertical", "wrong overview gesture")
api_calls = {}
swipe(gestures[2], { { x = 0, y = -30 } }, { direction = "UP" })
assert(api_calls[1][1] == "overview_begin" and api_calls[1][2] == "up", "the overview swipe did not start")
assert(api_calls[2][1] == "overview_update" and api_calls[2][2] == -30, "the overview swipe lost a step")
assert(api_calls[3][1] == "overview_end", "the overview swipe did not end")

-- Without gesture support the overview opens upward and closes downward in one step.
_G.__omalattice_gestures = nil
overview_active = false
swipe(gestures[2], { { x = 0, y = -30 } }, { direction = "UP" })
assert(dispatched[#dispatched].message == "overview", "swipe up did not open the overview")
local overview_dispatches = #dispatched
swipe(gestures[2], { { x = 0, y = 30 } }, { direction = "DOWN" })
assert(#dispatched == overview_dispatches, "swipe down should do nothing while the overview is closed")
overview_active = true
swipe(gestures[2], { { x = 0, y = 30 } }, { direction = "DOWN" })
assert(dispatched[#dispatched].message == "overview-exit", "swipe down did not close the overview")
overview_active = false

active_layout = "scrolling"
local gesture_dispatch_count = #dispatched
swipe(gestures[1], { { x = 0, y = -20 } })
swipe(gestures[2], { { x = 0, y = -20 } }, { direction = "UP" })
assert(#dispatched == gesture_dispatch_count, "vertical gestures should not affect other layouts")

active_layout = "lua:omalattice"
bindings["SUPER + SHIFT + code:21"]()
assert(dispatched[#dispatched].message == "resize height grow", "wrong height resize message")

local function last_exec()
    local item = dispatched[#dispatched]
    return item.kind == "exec" and item.command or nil
end

assert(type(bindings["SUPER + L"]) == "function", "layout rotation binding was not installed")
assert(_G.__omalattice_rotate_layout == bindings["SUPER + L"], "layout rotation was not exposed")

-- dwindle -> scrolling is left to Omarchy's own toggle.
active_workspace = { id = 3, tiled_layout = "dwindle", special = false }
bindings["SUPER + L"]()
assert(last_exec() == "omarchy-hyprland-workspace-layout-toggle", "dwindle should use Omarchy's toggle")
assert(saved_workspaces() == "", "dwindle step should not save a workspace")

-- scrolling -> Omalattice on the focused workspace only.
active_workspace = { id = 3, tiled_layout = "scrolling", special = false }
bindings["SUPER + L"]()
assert(#workspace_rules == 1 and workspace_rules[1].workspace == "3"
    and workspace_rules[1].layout == "lua:omalattice", "scrolling did not rotate into Omalattice")
assert(saved_workspaces() == "3\n", "rotated workspace was not saved")
assert(last_exec():find("omarchy-notification-send", 1, true), "rotation did not notify")

-- Omalattice -> dwindle, forgetting the workspace and leaving overview first.
active_workspace = { id = 3, tiled_layout = "lua:omalattice", special = false }
overview_active = true
bindings["SUPER + L"]()
assert(dispatched[#dispatched - 1].message == "overview-exit", "overview should exit before leaving the layout")
assert(last_exec() == "omarchy-hyprland-workspace-layout-toggle", "Omalattice should hand back to Omarchy")
assert(saved_workspaces() == "", "workspace was not forgotten")
overview_active = false

-- Special workspaces never rotate into Omalattice.
active_workspace = { id = -98, tiled_layout = "scrolling", special = true }
bindings["SUPER + L"]()
assert(last_exec() == "omarchy-hyprland-workspace-layout-toggle", "special workspace should use Omarchy's toggle")
assert(saved_workspaces() == "", "special workspace was saved")

-- Horizontal swipes switch workspaces, except on an Omalattice workspace where
-- they slide the grid. The workspace swipe is put back when leaving.
local function find_gesture(kind)
    for _, gesture in ipairs(live_gestures) do
        if gesture.direction == "horizontal"
            and (kind == "workspace") == (gesture.action == "workspace") then
            return gesture
        end
    end
end
local function activate_workspace(workspace)
    active_workspace = workspace
    for _, handler in ipairs(handlers["workspace.active"]) do handler() end
end

assert(find_gesture("workspace") and not find_gesture("grid"), "workspace swipe should stay on other layouts")
activate_workspace({ id = 3, tiled_layout = "lua:omalattice", special = false })
assert(not find_gesture("workspace"), "workspace swipe should yield on an Omalattice workspace")
assert(find_gesture("grid"), "the horizontal grid swipe was not installed")
active_layout = "lua:omalattice"
swipe(find_gesture("grid"), { { x = -20, y = 0 } })
assert(dispatched[#dispatched].message == "focus left", "left swipe sent the wrong layout command")
swipe(find_gesture("grid"), { { x = 20, y = 0 } })
assert(dispatched[#dispatched].message == "focus right", "right swipe sent the wrong layout command")
natural_scroll = true
swipe(find_gesture("grid"), { { x = -20, y = 0 } })
assert(dispatched[#dispatched].message == "focus right", "natural scrolling should invert the left swipe")
natural_scroll = false
activate_workspace({ id = 3, tiled_layout = "lua:omalattice", special = false })
assert(#live_gestures == 3, "repeated sync should not duplicate gestures")
activate_workspace({ id = 4, tiled_layout = "scrolling", special = false })
assert(find_gesture("workspace") and not find_gesture("grid"), "workspace swipe was not restored")
assert(#live_gestures == 3, "gesture swap leaked a gesture")

-- Rotating the layout refreshes the gestures once the toggle has applied.
timers = {}
active_workspace = { id = 3, tiled_layout = "dwindle", special = false }
bindings["SUPER + L"]()
assert(#timers == 1 and timers[1].options.type == "oneshot", "rotation did not schedule a resync")
active_workspace = { id = 3, tiled_layout = "lua:omalattice", special = false }
timers[1].callback()
assert(find_gesture("grid") and not find_gesture("workspace"), "resync did not swap the gestures")
activate_workspace({ id = 4, tiled_layout = "scrolling", special = false })

assert(gesture_errors == 0, "gesture swaps must never remove a missing gesture")

-- Without a workspace swipe the focus swipes are simply always on and nothing is removed.
local real_dofile = dofile
_G.dofile = function(path)
    local loaded = real_dofile(path)
    if path:match("config%.lua$") then
        loaded.workspace_swipe = false
        loaded.three_finger_pan = false
    end
    return loaded
end
_G.__omalattice_omarchy_integrated = nil
live_gestures = {}
handlers = {}
assert(loadfile(root .. "/integration/omarchy.lua"))()
_G.dofile = real_dofile
assert(find_gesture("grid") and not find_gesture("workspace"),
    "the grid swipe should be always on without a workspace swipe")
activate_workspace({ id = 3, tiled_layout = "lua:omalattice", special = false })
activate_workspace({ id = 4, tiled_layout = "scrolling", special = false })
assert(#live_gestures == 3 and gesture_errors == 0, "swipes should not be swapped without a workspace swipe")
_G.__omalattice_omarchy_integrated = true

-- Scroll binds are consuming, so they stay off until an overview is open.
for _, key in ipairs({ "mouse_down", "mouse_up", "mouse_left", "mouse_right" }) do
    assert(scroll_binds[key] and not scroll_binds[key].enabled, key .. " scroll bind should start disabled")
end
overview_active = true
_G.__omalattice_overview_changed()
for _, key in ipairs({ "mouse_down", "mouse_up", "mouse_left", "mouse_right" }) do
    assert(scroll_binds[key].enabled, key .. " scroll bind should enable with the overview")
end
scroll_binds.mouse_down.action()
assert(dispatched[#dispatched].message == "scroll down", "wheel down did not scroll the overview")
scroll_binds.mouse_left.action()
assert(dispatched[#dispatched].message == "scroll left", "wheel left did not scroll the overview")
overview_active = false
_G.__omalattice_overview_changed()
assert(not scroll_binds.mouse_down.enabled, "scroll bind should disable when the overview closes")

-- The plugin restores saved workspaces and pins nothing by default.
local workspace_file = assert(io.open(state_home .. "/omalattice/workspaces", "w"))
workspace_file:write("5\n7\n")
workspace_file:close()
workspace_rules = {}
assert(loadfile(root .. "/integration/plugin.lua"))()
assert(#workspace_rules == 2 and workspace_rules[1].workspace == "5" and workspace_rules[2].workspace == "7",
    "plugin did not restore saved workspaces")
timers = {}
workspace_rules = {}
assert(loadfile(root .. "/integration/plugin.lua"))()
assert(#timers == 1, "restored workspaces should schedule a gesture resync")
assert(#workspace_rules == 2, "plugin reload did not reapply saved workspaces")

local config = assert(loadfile(root .. "/layout/config.lua"))()
assert(config.workspace == nil, "Omalattice should not pin a workspace by default")

os.getenv = original_getenv
os.execute("rm -rf '" .. state_home .. "'")

print("ok - mocked Omarchy integration")
