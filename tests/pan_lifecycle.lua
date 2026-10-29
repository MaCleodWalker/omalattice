local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)/[^/]+$") or "tests"
local root = arg[1] or tests_dir:match("^(.*)/tests$") or "."
local original_loadfile, original_open = loadfile, io.open
local core = assert(original_loadfile(root .. "/layout/core.lua"))()
local config = assert(original_loadfile(root .. "/layout/config.lua"))()
config.hover_focus_delay = 20
config.overview_autoscroll_speed = 0
local state
local new_state = core.new_state
core.new_state = function()
    state = new_state()
    return state
end

-- Replay layout, focus events and hover without touching desktop state files.
loadfile = function(path, ...)
    if path == root .. "/layout/core.lua" then return function() return core end end
    if path == root .. "/layout/config.lua" then return function() return config end end
    if path == root .. "/layout/settings.lua" then
        return function() return { apply = function() end } end
    end
    if path == root .. "/layout/persist.lua" then
        return function()
            return {
                load = function() return {} end,
                begin_restore = function() end,
                snapshot = function() return {} end,
                encode = function() return "" end,
                write = function() return true end,
            }
        end
    end
    return original_loadfile(path, ...)
end
io.open = function(_, mode)
    assert(mode == "w", "unexpected file read during replay")
    return { write = function() return true end, close = function() return true end }
end

local provider, active, ctx
local callbacks = {}
local cursor = { x = 500, y = 400 }
local follow_mouse = 1
local animations = true
local focus_history = {}
local function target(id)
    return {
        window = {
            stable_id = id, address = "0x" .. id, mapped = true,
            workspace = { id = 9 }, layout = { name = "lua:omalattice" },
        },
        place = function(self, box)
            self.placed = box
            self.window.at = { x = box.x, y = box.y }
            self.window.size = { x = box.w, y = box.h }
        end,
    }
end
local items = { target("A"), target("B"), target("C"), target("D") }
active = items[1].window
active.active = true
ctx = { area = { x = 0, y = 0, w = 1000, h = 800 }, targets = items }
_G.hl = {
    layout = { register = function(_, value) provider = value end },
    on = function(event, callback)
        callbacks[event] = callbacks[event] or {}
        table.insert(callbacks[event], callback)
        return true
    end,
    get_active_window = function() return active end,
    get_active_workspace = function() return { id = 9, tiled_layout = "lua:omalattice" } end,
    get_workspace_windows = function()
        local windows = {}
        for _, item in ipairs(items) do table.insert(windows, item.window) end
        return windows
    end,
    get_layers = function() return {} end,
    get_cursor_pos = function() return cursor end,
    get_config = function(key)
        if key == "input.follow_mouse" then return follow_mouse end
        if key == "animations.enabled" then return animations end
        return 0
    end,
    config = function(value)
        if value.input then follow_mouse = value.input.follow_mouse end
        if value.animations then animations = value.animations.enabled end
    end,
    timer = function() return { set_enabled = function() end } end,
    dsp = {
        layout = function(message) return { kind = "layout", message = message } end,
        focus = function(options) return { kind = "focus", window = options.window } end,
        cursor = { move = function(options) return { kind = "cursor", point = options } end },
    },
    dispatch = function(command)
        if command.kind == "layout" then
            assert(provider.layout_msg(ctx, command.message) == true)
            provider.recalculate(ctx)
        elseif command.kind == "cursor" then
            cursor = command.point
        elseif command.kind == "focus" then
            assert(state.drag == nil, "focus callbacks must not see a stale gesture displacement")
            assert(animations, "settling focus must run with animations restored")
            for _, item in ipairs(items) do
                item.window.active = command.window == "address:" .. item.window.address
                if item.window.active then active = item.window end
            end
            table.insert(focus_history, active.stable_id)
            for _, callback in ipairs(callbacks["window.active"] or {}) do callback(active) end
        end
        return { ok = true }
    end,
}
assert(loadfile(root .. "/layout/init.lua"))()
local api = assert(_G.__omalattice_gestures)
local hover = assert(_G.__omalattice_hover)
for _, col in ipairs({ -1, 1 }) do
    for _, row in ipairs({ -1, 1 }) do
        for _, mode in ipairs({
            "visibility-gain", "hidden-neighbor", "full-pan", "flick", "cancelled", "no-motion",
            "reverse-partway", "return-to-start", "return-after-flick",
        }) do
            config.peek_x, config.peek_y = 96, 32
            config.gap_x, config.gap_y = 12, 12
            if mode == "hidden-neighbor" then
                config.peek_x, config.peek_y = 0, 0
                config.gap_x, config.gap_y = 48, 48
            end
            for _, item in ipairs(items) do item.window.active = item == items[1] end
            active = items[1].window
            focus_history = {}
            provider.recalculate(ctx)
            state.positions = {
                A = { col = 0, row = 0 }, B = { col = col, row = 0 },
                C = { col = 0, row = row }, D = { col = col, row = row },
            }
            core.follow(state)
            provider.recalculate(ctx)
            local a, d = items[1].placed, items[4].placed
            local dx = a.x + a.w / 2 - d.x - d.w / 2
            local dy = a.y + a.h / 2 - d.y - d.h / 2
            if mode == "visibility-gain" then dx, dy = dx * 0.15, dy * 0.15 end
            if mode == "hidden-neighbor" then dx, dy = -col * 24, -row * 24 end
            if mode == "no-motion" then dx, dy = 0, 0 end
            if mode == "flick" then dy = 0 end
            hover.poll()
            assert(api.pan_begin())
            api.pan_update(dx, dy)
            if mode == "reverse-partway" then api.pan_update(-dx / 2, -dy / 2) end
            if mode == "return-to-start" or mode == "return-after-flick" then
                api.pan_update(-dx + 2, -dy + 2)
            end
            hover.poll()
            local direction = (mode == "flick" or mode == "return-after-flick")
                and (col > 0 and "right" or "left") or nil
            api.pan_end(mode == "cancelled", direction)
            local expected = (mode == "cancelled" or mode == "no-motion" or mode == "return-to-start"
                or mode == "return-after-flick") and "A"
                or mode == "flick" and "B" or "D"
            assert(active.stable_id == expected,
                mode .. " release did not focus " .. expected .. "; got " .. active.stable_id)
            for _ = 1, 4 do hover.poll() end
            assert(active.stable_id == expected,
                mode .. " release bounced from " .. expected .. " to " .. active.stable_id
                .. "; focus history: " .. table.concat(focus_history, " -> "))
            assert(animations, "release did not restore animations")
        end
    end
end
loadfile, io.open = original_loadfile, original_open
print("ok - pan release remains focused after focus callbacks and hover polling in all quadrants")
