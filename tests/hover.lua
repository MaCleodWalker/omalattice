local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)/[^/]+$") or "tests"
local root = tests_dir:match("^(.*)/tests$") or "."

local follow_mouse = 1
local config_sets = {}
local handlers = {}
local timer = { enabled = nil }
local timer_callback = nil
local cursor = { x = 500, y = 400 }
local dispatched = {}
local layers = {}
local overview = false
local workspace = { id = 1, tiled_layout = "lua:omalattice", special = false, has_fullscreen = false }

local function window(address, x, w, extra)
    local value = {
        address = address, mapped = true, hidden = false, floating = false, active = false,
        at = { x = x, y = 0 }, size = { x = w, y = 800 },
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
end
local main = window("0xA", 0, 900, { active = true })
local peek = window("0xB", 900, 300)
local windows = { main, peek }

function timer:set_enabled(value) self.enabled = value end

_G.hl = {
    get_config = function() return follow_mouse end,
    config = function(options)
        follow_mouse = options.input.follow_mouse
        table.insert(config_sets, follow_mouse)
    end,
    on = function(event, handler)
        handlers[event] = handlers[event] or {}
        table.insert(handlers[event], handler)
    end,
    timer = function(callback)
        timer_callback = callback
        return timer
    end,
    get_active_workspace = function() return workspace end,
    get_workspace_windows = function() return windows end,
    get_cursor_pos = function() return cursor end,
    get_layers = function() return layers end,
    dispatch = function(value) table.insert(dispatched, value) end,
    dsp = { focus = function(options) return { kind = "focus", window = options.window } end },
}

local hover = assert(loadfile(root .. "/layout/hover.lua"))()
local function start(delay)
    return hover.start({ hover_focus_delay = delay, hover_focus_peeks = true }, function() return overview end)
end

local instance = start(0)
assert(instance and start(nil), "hover focus should remain reconfigurable when disabled")
assert(follow_mouse == 1 and timer_callback == nil, "a disabled delay changed the input settings")

instance.set_settings(100, true)
assert(follow_mouse == 2 and timer.enabled, "hover focus did not take over follow_mouse")

local function ticks(count)
    for _ = 1, count do timer_callback() end
end
local function reset_cursor(x)
    cursor = { x = x, y = 400 }
    timer_callback()
end

-- Resting on the active window does nothing.
ticks(10)
assert(#dispatched == 0, "the active window should not be refocused")

-- Passing over the peek is ignored; resting on it focuses it after the delay.
reset_cursor(1000)
ticks(3)
reset_cursor(500)
ticks(10)
assert(#dispatched == 0, "a quick pass over the peek changed focus")
reset_cursor(1000)
ticks(4)
assert(#dispatched == 0, "focus changed before the delay elapsed")
ticks(2)
assert(#dispatched == 1 and dispatched[1].window == "address:0xB", "resting on the peek did not focus it")
dispatched = {}

-- Moving between candidates restarts the delay.
peek.active, main.active = true, false
reset_cursor(100)
ticks(3)
reset_cursor(1000)
ticks(4)
assert(#dispatched == 0, "the delay should restart for a new window")
peek.active, main.active = false, true

-- A stationary cursor does not undo keyboard focus changes.
dispatched = {}
reset_cursor(500)
reset_cursor(1000)
ticks(20)
assert(#dispatched == 1, "setup: stationary candidate should focus once, got " .. #dispatched .. " " .. tostring(peek.active) .. tostring(main.active))
dispatched = {}
reset_cursor(1000)
main.active, peek.active = false, true
ticks(20)
assert(#dispatched == 0, "a stationary cursor changed keyboard focus")
main.active, peek.active = true, false

-- A pointer left over a window when the overview closes must move before it can refocus.
reset_cursor(500)
overview = true
reset_cursor(1000)
ticks(3)
overview = false
dispatched = {}
ticks(20)
assert(#dispatched == 0, "closing the overview should not refocus the window under the pointer")
reset_cursor(500)

-- A keyboard-grabbing layer, fullscreen and the overview suppress hover focus.
local function blocked(setup, teardown, label)
    dispatched = {}
    setup()
    reset_cursor(1000)
    ticks(20)
    assert(#dispatched == 0, label .. " should block hover focus")
    teardown()
    reset_cursor(500)
end
blocked(function() layers = { { mapped = true, interactivity = 1, layer = 3, x = 0, y = 0, w = 10, h = 10 } } end,
    function() layers = {} end, "an exclusive-keyboard layer")
blocked(function() workspace.has_fullscreen = true end, function() workspace.has_fullscreen = false end, "fullscreen")
blocked(function() overview = true end, function() overview = false end, "the overview")

-- Click-through layers, even full-screen ones, do not block it.
layers = { { mapped = true, interactivity = 0, layer = 3, x = 0, y = 0, w = 2000, h = 800 } }
dispatched = {}
reset_cursor(1000)
ticks(6)
assert(#dispatched == 1, "a click-through layer should not block hover focus")
layers = {}
dispatched = {}

-- Floating windows win over the tiles below them.
local floating = window("0xC", 950, 100, { floating = true })
windows = { main, floating, peek }
reset_cursor(500)
reset_cursor(1000)
ticks(6)
assert(dispatched[1] and dispatched[1].window == "address:0xC", "the floating window should take focus")
windows = { main, peek }
dispatched = {}

-- Other layouts get Hyprland's native behaviour back.
workspace = { id = 2, tiled_layout = "dwindle", special = false }
for _, handler in ipairs(handlers["workspace.active"]) do handler() end
assert(follow_mouse == 1 and timer.enabled == false, "follow_mouse was not restored")
reset_cursor(1000)
ticks(10)
assert(#dispatched == 0, "other layouts must not use hover focus")

workspace = { id = 1, tiled_layout = "lua:omalattice", special = false }
instance.sync()
assert(follow_mouse == 2 and timer.enabled, "hover focus did not resume")
instance.set_settings(0, true)
assert(follow_mouse == 1 and timer.enabled == false, "disabling hover focus did not restore follow_mouse")
instance.set_settings(100, true)
assert(follow_mouse == 2 and timer.enabled, "re-enabling hover focus did not resume")
instance.set_settings(100, false)
assert(follow_mouse == 2 and timer.enabled == false,
    "disabling peek hover focus should preserve click-to-focus without polling")
dispatched = {}
reset_cursor(1000)
ticks(20)
assert(#dispatched == 0, "disabled peek hover focus changed the focused window")
instance.set_settings(100, true)
assert(follow_mouse == 2 and timer.enabled, "enabling peek hover focus should resume polling")

-- A deliberate follow_mouse setting is respected.
workspace = { id = 2, tiled_layout = "dwindle", special = false }
instance.sync()
follow_mouse = 3
workspace = { id = 1, tiled_layout = "lua:omalattice", special = false }
instance.sync()
assert(follow_mouse == 3 and timer.enabled == false, "a custom follow_mouse should not be overridden")

print("ok - debounced hover focus")
