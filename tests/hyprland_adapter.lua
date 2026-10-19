local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)/[^/]+$") or "tests"
local root = tests_dir:match("^(.*)/tests$") or "."

local registered = nil
local dispatched = {}
local active_callback = nil
local dispatch_context = nil
local cursor = nil
local timer_callback = nil
local timer_enabled = nil
local overview_status = nil
local overview_progress = nil
local original_getenv = os.getenv
local original_open = io.open

local state_home = os.tmpname()
os.remove(state_home)
assert(os.execute("mkdir -p '" .. state_home .. "'"))
os.getenv = function(name)
    if name == "XDG_RUNTIME_DIR" then return "/tmp" end
    if name == "XDG_STATE_HOME" then return state_home end
    if name == "OMALATTICE_CONFIG" then return state_home .. "/config.lua" end
    return original_getenv(name)
end
-- The cursor positions below assume 48 px peeks.
local overrides = assert(original_open(state_home .. "/config.lua", "w"))
overrides:write("return { peek_x = 48, peek_y = 48 }\n")
overrides:close()
io.open = function(path, mode)
    if path == "/tmp/omalattice-overview-progress" then
        return {
            write = function(_, value) overview_progress = value; return true end,
            close = function() return true end,
        }
    end
    if path ~= "/tmp/omalattice-overview" then return original_open(path, mode) end
    assert(mode == "w", "unexpected overview status mode")
    return {
        write = function(_, value)
            overview_status = value
            return true
        end,
        close = function()
            return true
        end,
    }
end

_G.__omalattice_focus_subscription = nil
_G.hl = {
    layout = {
        register = function(name, provider)
            registered = { name = name, provider = provider }
        end,
    },
    on = function(event, callback)
        if event == "window.active" and not active_callback then active_callback = callback end
        return true
    end,
    get_active_window = function()
        return { workspace = { id = 9 } }
    end,
    get_cursor_pos = function() return cursor end,
    timer = function(callback)
        timer_callback = callback
        return { set_enabled = function(_, value) timer_enabled = value end }
    end,
    dispatch = function(dispatcher)
        table.insert(dispatched, dispatcher)
        if dispatcher.kind == "layout" and dispatch_context then
            registered.provider.layout_msg(dispatch_context, dispatcher.message)
            registered.provider.recalculate(dispatch_context)
        elseif dispatcher.kind == "cursor" then
            cursor = { x = dispatcher.x, y = dispatcher.y }
        end
        return { ok = true }
    end,
    dsp = {
        layout = function(message)
            return { kind = "layout", message = message }
        end,
        focus = function(options)
            return { kind = "focus", window = options.window }
        end,
        cursor = {
            move = function(options)
                return { kind = "cursor", x = options.x, y = options.y }
            end,
        },
    },
}

assert(loadfile(root .. "/layout/init.lua"))()
assert(registered and registered.name == "omalattice", "layout did not register")
assert(overview_status == '{"workspace":"none","overview":false}', "overview status was not reset on load")

local function target(id, active, workspace, class, title)
    return {
        window = {
            class = class,
            title = title,
            stable_id = id,
            address = "0x" .. id,
            active = active,
            mapped = true,
            workspace = { id = workspace or 9 },
            layout = { name = "lua:omalattice" },
        },
        place = function(self, box)
            self.placed = box
            self.window.at = { x = box.x, y = box.y }
            self.window.size = { x = box.w, y = box.h }
        end,
    }
end

local a = target("A", true)
local b = target("B", false)
local ctx = {
    area = { x = 0, y = 0, w = 1000, h = 800 },
    targets = { a, b },
}

registered.provider.recalculate(ctx)
assert(a.placed and b.placed, "recalculate did not place every target")
assert(a.placed.x < b.placed.x, "new targets should initially extend right")

local initial_x, initial_y = a.placed.x, a.placed.y
assert(registered.provider.layout_msg(ctx, "pan-by 17.5 -8.25") == true, "continuous pan command was rejected")
registered.provider.recalculate(ctx)
assert(math.abs(a.placed.x - initial_x - 17.5) < 1e-6, "horizontal pan delta was not preserved")
assert(math.abs(a.placed.y - initial_y + 8.25) < 1e-6, "vertical pan delta was not preserved")
assert(type(registered.provider.layout_msg(ctx, "pan-by nan 2")) == "string",
    "invalid continuous pan delta should return an error")
assert(registered.provider.layout_msg(ctx, "snap-nearest") == true, "nearest-window snap command was rejected")
assert(dispatched[#dispatched].kind == "focus", "nearest-window snap did not focus a window")

local response = registered.provider.layout_msg(ctx, "focus right")
assert(response == true, "focus command was rejected")
assert(dispatched[#dispatched].kind == "focus", "focus command did not dispatch")
assert(dispatched[#dispatched].window == "address:0xB", "focus targeted the wrong window")

response = registered.provider.layout_msg(ctx, "resize height shrink")
assert(response == true, "height resize command was rejected")

response = registered.provider.layout_msg(ctx, "resize height sideways")
assert(type(response) == "string", "invalid resize command should return an error")

response = registered.provider.layout_msg(ctx, "overview")
assert(response == true, "overview command was rejected")
assert(_G.__omalattice_is_overview_active(), "overview state was not exposed to keybindings")
assert(overview_status == '{"workspace":"workspace:9","overview":true}', "overview status was not published")
local normal_width = a.placed.w
registered.provider.recalculate(ctx)

-- The shell draws scaled tiles inside the viewport; the real windows keep their size.
local function tile(address)
    local x, y, w, h = overview_status:match('"address":"' .. address .. '","x":([%-%d.]+),"y":([%-%d.]+),"w":([%d.]+),"h":([%d.]+)')
    return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
end
local ax, _, aw = tile("0xA")
local bx, _, bw = tile("0xB")
assert(ax and bx, "overview tiles were not published: " .. tostring(overview_status))
assert(ax >= 0 and bx + bw <= ctx.area.w, "overview tiles should fit the viewport")
assert(aw < normal_width, "overview tiles should be smaller than the windows")
assert(a.placed.w == normal_width, "overview should not resize the real windows")
assert(a.placed.x >= 0 and a.placed.x + a.placed.w <= ctx.area.w, "overview windows should stay on screen to be captured")
assert(a.placed.x == b.placed.x, "overview windows should be stacked")
assert(overview_status:find('"thumbnails":true', 1, true), "thumbnails should be enabled by default")

assert(overview_status:find('"columns":[0,1],"rows":[0]', 1, true), "drop grid axes were not published")
local before_drop_dispatches = #dispatched
assert(registered.provider.layout_msg(ctx, "overview-drop 0xB 0 0 workspace:9") == true)
registered.provider.recalculate(ctx)
assert(tile("0xB") < tile("0xA"), "an occupied drop should swap the thumbnails")
assert(#dispatched == before_drop_dispatches, "a drop should not change focus")
assert(_G.__omalattice_is_overview_active(), "a drop should keep the overview open")
assert(registered.provider.layout_msg(ctx, "overview-drop 0xB 1 0 workspace:9") == true)
registered.provider.recalculate(ctx)
assert(registered.provider.layout_msg(ctx, "overview-drop 0xB 0 1 workspace:9") == true)
registered.provider.recalculate(ctx)
local _, drop_ay = tile("0xA")
local _, drop_by = tile("0xB")
assert(drop_by > drop_ay, "an empty drop should create a second row")
local saved_drop = assert(loadfile(root .. "/layout/persist.lua"))().load()["workspace:9"]
assert(saved_drop and #saved_drop.windows == 2, "the dropped layout was not saved")
assert(saved_drop.windows[2].row == 1, "the saved layout did not retain the dropped row")
for _, invalid in ipairs({
    "overview-drop", "overview-drop 0xB 0.5 0 workspace:9",
    "overview-drop 0xB 1000000 0 workspace:9",
    "overview-drop 0xB 0 0 workspace:10",
    "overview-drop 0xmissing 0 0 workspace:9",
}) do
    assert(type(registered.provider.layout_msg(ctx, invalid)) == "string", "invalid drop was accepted: " .. invalid)
end
registered.provider.recalculate(ctx)
local _, unchanged_by = tile("0xB")
assert(unchanged_by == drop_by, "a rejected drop changed the layout")
assert(registered.provider.layout_msg(ctx, "overview-drop 0xB 1 0 workspace:9") == true)
registered.provider.recalculate(ctx)

a.window.active = false
b.window.active = true
local dispatch_count = #dispatched
active_callback(b.window)
assert(#dispatched == dispatch_count, "mouse selection should not exit overview")

response = registered.provider.layout_msg(ctx, "overview-exit")
assert(response == true, "overview exit command was rejected")
assert(not _G.__omalattice_is_overview_active(), "overview state remained active after exit")
assert(overview_status == '{"workspace":"workspace:9","overview":false}', "overview exit status was not published")
assert(type(registered.provider.layout_msg(ctx, "overview-drop 0xB 0 0 workspace:9")) == "string",
    "a closed overview must reject drops")
registered.provider.recalculate(ctx)
assert(b.placed.x > a.placed.x, "overview exit should restore the normal layout")

-- A workspace too large for the minimum cell size scrolls and reports scroll bars.
local overview_changes = 0
_G.__omalattice_overview_changed = function() overview_changes = overview_changes + 1 end
local crowded_targets = {}
for i = 1, 8 do crowded_targets[i] = target("crowd" .. i, i == 1, 30) end
local crowded = { area = { x = 0, y = 0, w = 1000, h = 800 }, targets = crowded_targets }
registered.provider.recalculate(crowded)
assert(registered.provider.layout_msg(crowded, "scroll right") == true, "scroll command was rejected")

response = registered.provider.layout_msg(crowded, "overview")
assert(response == true, "overview command was rejected for the crowded workspace")
assert(overview_changes == 1, "overview change was not announced")
registered.provider.recalculate(crowded)
local x_start, x_size = overview_status:match('"bars":%[([%d.]+),([%d.]+),')
assert(x_start and tonumber(x_size) < 1, "scroll bars were not published: " .. tostring(overview_status))

local before_scroll = tile("0xcrowd1")
assert(registered.provider.layout_msg(crowded, "scroll right") == true, "scroll command was rejected")
registered.provider.recalculate(crowded)
assert(tile("0xcrowd1") < before_scroll, "scrolling right should move the tiles left")

response = registered.provider.layout_msg(crowded, "overview-exit")
assert(response == true and overview_changes == 2, "overview exit was not announced")
assert(overview_status == '{"workspace":"workspace:30","overview":false}', "overview exit should clear the scroll bars")
_G.__omalattice_overview_changed = nil

local function activate(context, selected)
    for _, item in ipairs(context.targets) do
        item.window.active = item == selected
    end
end

local function under_cursor(context)
    for _, item in ipairs(context.targets) do
        local box = item.placed
        if cursor.x >= box.x and cursor.x < box.x + box.w
            and cursor.y >= box.y and cursor.y < box.y + box.h then
            return item
        end
    end
end

local function open_row(context)
    local items, active = context.targets, {}
    context.targets = {}
    for _, item in ipairs(items) do
        active[item] = item.window.active
        for _, opened in ipairs(context.targets) do opened.window.active = false end
        item.window.active = true
        table.insert(context.targets, item)
        registered.provider.recalculate(context)
    end
    for _, item in ipairs(items) do item.window.active = active[item] end
    registered.provider.recalculate(context)
end

local spawn_a, spawn_b, spawn_c = target("spawnA", true, 102),
    target("spawnB", false, 102), target("spawnC", false, 102)
local spawn = {
    area = { x = 0, y = 0, w = 1000, h = 800 },
    targets = { spawn_a, spawn_b, spawn_c },
}
open_row(spawn)
local spawn_d = target("spawnD", true, 102)
activate(spawn, spawn_b)
registered.provider.recalculate(spawn)
activate(spawn, spawn_d)
table.insert(spawn.targets, spawn_d)
registered.provider.recalculate(spawn)
assert(spawn_a.placed.x < spawn_b.placed.x and spawn_b.placed.x < spawn_c.placed.x
    and spawn_d.placed.x == spawn_b.placed.x and spawn_d.placed.y > spawn_b.placed.y,
    "new active windows must expand downward instead of pushing the right neighbor")
activate(spawn, spawn_a)
registered.provider.recalculate(spawn)
local spawn_e = target("spawnE", true, 102)
activate(spawn, spawn_e)
table.insert(spawn.targets, spawn_e)
registered.provider.recalculate(spawn)
assert(spawn_e.placed.y > spawn_a.placed.y and spawn_e.placed.x == spawn_a.placed.x,
    "new active windows must fill the adjacent hole below the previous focus")

for index, direction in ipairs({ "right", "left", "down", "up" }) do
    local vertical = direction == "down" or direction == "up"
    local forward = direction == "right" or direction == "down"
    local items = {}
    for i = 1, 4 do
        items[i] = target(direction .. i, i == 1, 20 + index)
    end
    local context = {
        area = { x = 100, y = 200, w = 1000, h = 800 },
        targets = items,
    }
    open_row(context)
    if vertical then
        for i = 2, #items do
            activate(context, items[i])
            for _ = 1, i - 1 do
                registered.provider.layout_msg(context, "move down")
            end
            -- Gaps close up, so the next window is always one column from the stack.
            registered.provider.layout_msg(context, "move left")
        end
    end
    activate(context, items[forward and 1 or 4])
    registered.provider.recalculate(context)
    cursor = {
        x = vertical and 600 or (forward and 1080 or 120),
        y = vertical and (forward and 980 or 220) or 600,
    }
    local next_window = items[forward and 2 or 3]
    assert(under_cursor(context) == next_window, direction .. " peek should show the next window")

    dispatch_context = context
    activate(context, next_window)
    active_callback(next_window.window)
    assert(under_cursor(context) == next_window,
        direction .. " mouse focus must stop at the next window after scrolling")
    assert(next_window.window.active, direction .. " next window should remain focused")
    assert(cursor.x == 600 and cursor.y == 600,
        direction .. " cursor should use the centered geometry, not the old peek")
    dispatch_context = nil
end

dispatch_count = #dispatched
active_callback({ layout = { name = "dwindle" } })
assert(#dispatched == dispatch_count, "other layouts should not move the cursor")

-- Without thumbnails the overview resizes the real windows, as before.
local real_loadfile = loadfile
_G.__omalattice_layout_registered = nil
_G.loadfile = function(path)
    local chunk, err = real_loadfile(path)
    if chunk and path:match("config%.lua$") then
        return function()
            local loaded = chunk()
            loaded.overview_thumbnails = false
            return loaded
        end
    end
    return chunk, err
end
assert(real_loadfile(root .. "/layout/init.lua"))()
_G.loadfile = real_loadfile

local legacy_a = target("legacyA", true, 40)
local legacy_b = target("legacyB", false, 40)
local legacy = { area = { x = 0, y = 0, w = 1000, h = 800 }, targets = { legacy_a, legacy_b } }
registered.provider.recalculate(legacy)
local full_width = legacy_a.placed.w
assert(registered.provider.layout_msg(legacy, "overview") == true, "legacy overview command was rejected")
registered.provider.recalculate(legacy)
assert(legacy_a.placed.w < full_width, "legacy overview should resize the real windows")
assert(overview_status:find('"thumbnails":false', 1, true), "legacy overview should not request thumbnails")

-- A crowded overview pans on its own while the pointer rests near an edge.
local crowded9_targets = {}
for i = 1, 8 do crowded9_targets[i] = target("auto" .. i, i == 1, 9) end
local crowded9 = { area = { x = 100, y = 200, w = 1000, h = 800 }, targets = crowded9_targets }
registered.provider.recalculate(crowded9)
assert(registered.provider.layout_msg(crowded9, "overview") == true, "overview command was rejected")
assert(timer_callback and timer_enabled == true, "auto-scroll did not start with the overview")
dispatch_context = crowded9
registered.provider.recalculate(crowded9)
local first_tile = tile("0xauto1")

cursor = { x = 600, y = 600 }
dispatch_count = #dispatched
timer_callback()
assert(#dispatched == dispatch_count, "a centred pointer should not scroll")

cursor = { x = 1099, y = 600 }
timer_callback()
assert(dispatched[#dispatched].message == "refresh", "an edge pointer did not refresh the overview")
assert(tile("0xauto1") < first_tile, "the overview did not pan toward the pointer")

cursor = { x = 500, y = 600 }
for _ = 1, 400 do
    cursor = { x = 1099, y = 600 }
    timer_callback()
end
dispatch_count = #dispatched
timer_callback()
assert(#dispatched == dispatch_count, "scrolling should stop at the end of the content")

-- Clicking a thumbnail closes the overview and moves the pointer into the window.
cursor = { x = 5, y = 5 }
registered.provider.layout_msg(crowded9, "overview-exit click")
assert(timer_enabled == false, "auto-scroll kept running after the overview closed")
registered.provider.recalculate(crowded9)
local entered = crowded9_targets[1].placed
assert(cursor.x == entered.x + entered.w / 2 and cursor.y == entered.y + entered.h / 2,
    "the pointer did not move into the entered window")
dispatch_context = nil

-- Three-finger swipes slide the grid with the fingers and settle on a window.
-- Reload with thumbnails on, as configured by default.
_G.__omalattice_layout_registered = nil
assert(real_loadfile(root .. "/layout/init.lua"))()
local real_active_window = hl.get_active_window
hl.get_active_window = function() return { workspace = { id = 60 } } end
local swipe_targets = { target("swipe1", true, 60), target("swipe2", false, 60), target("swipe3", false, 60) }
local swipe_ctx = { area = { x = 0, y = 0, w = 1000, h = 800 }, targets = swipe_targets }
open_row(swipe_ctx)
dispatch_context = swipe_ctx
local gestures_api = _G.__omalattice_gestures
-- Hyprland makes the focused window active; the mock has to do that by hand.
local function settle(focused)
    activate(swipe_ctx, focused)
    registered.provider.recalculate(swipe_ctx)
end
local home_x = swipe_targets[1].placed.x
local window_step = swipe_targets[2].placed.x - swipe_targets[1].placed.x

local animations = true
hl.get_config = function(key)
    if key == "animations.enabled" then return animations end
end
hl.config = function(options)
    if options.animations then animations = options.animations.enabled end
end
assert(gestures_api.drag_begin("x"), "the drag did not start")
assert(animations == false, "animations should pause so the grid tracks the fingers")
gestures_api.drag_update(150, 10)
assert(math.abs((home_x - swipe_targets[1].placed.x) - window_step / 2) < 0.5,
    "half a swipe distance should slide the grid half a window")
gestures_api.drag_update(-30, 1000)
gestures_api.drag_end(false)
assert(dispatched[#dispatched - 1].kind == "focus" and dispatched[#dispatched - 1].window == "address:0xswipe2",
    "a drag past the commit point should focus the next window")
assert(animations == true, "animations should resume when the fingers lift")
assert(math.abs(swipe_targets[2].placed.x - home_x) < 0.5, "the grid should settle on the next window")
settle(swipe_targets[2])

assert(gestures_api.drag_begin("x"))
gestures_api.drag_update(60, 10)
gestures_api.drag_update(1, 1000)
gestures_api.drag_end(false)
assert(math.abs(swipe_targets[2].placed.x - home_x) < 0.5, "a short slow drag should spring back")

assert(gestures_api.drag_begin("x"))
gestures_api.drag_update(30, 10)
gestures_api.drag_update(30, 15)
gestures_api.drag_end(false)
assert(math.abs(swipe_targets[3].placed.x - home_x) < 0.5, "a flick should move to the next window")
settle(swipe_targets[3])

assert(gestures_api.drag_begin("x"))
gestures_api.drag_update(600, 10)
local overshoot = home_x - swipe_targets[3].placed.x
assert(overshoot > 0 and overshoot <= 100, "the last window should resist instead of sliding away")
gestures_api.drag_end(true)
assert(math.abs(swipe_targets[3].placed.x - home_x) < 0.5, "a cancelled drag should spring back")

-- Four-finger swipes open the overview as far as the fingers go.
assert(not gestures_api.overview_begin("down"), "swiping down should not open the overview")
assert(gestures_api.overview_begin("up"), "swiping up should start opening the overview")
assert(_G.__omalattice_is_overview_active(), "the overview should open as the swipe starts")
assert(overview_progress == '{"progress":0.0000,"dragging":true}', "the swipe should start closed")
assert(overview_status:find('"fx":', 1, true), "tiles should say where their windows are")
gestures_api.overview_update(-150, 10)
assert(overview_progress == '{"progress":0.5000,"dragging":true}', "the overview should follow the fingers")
gestures_api.overview_end(false)
assert(_G.__omalattice_is_overview_active(), "half way should stay open")
assert(overview_progress == '{"progress":1.0000,"dragging":false}', "the overview should finish opening")

assert(gestures_api.overview_begin("down"), "swiping down should start closing the overview")
gestures_api.overview_update(200, 10)
gestures_api.overview_update(1, 1000)
gestures_api.overview_end(false)
assert(not _G.__omalattice_is_overview_active(), "the overview should close past half way")
assert(overview_progress == '{"progress":0.0000,"dragging":false}', "the overview should finish closing")
assert(overview_status:find('"overview":false', 1, true) and overview_status:find('"fx":', 1, true),
    "closing should tell the shell where the windows return to")

dispatch_context = nil
hl.get_active_window = real_active_window

-- A workspace's grid survives a restart: new windows are matched by class and title.
local function restart_layout()
    _G.__omalattice_layout_registered = nil
    assert(real_loadfile(root .. "/layout/init.lua"))()
end

local function workspace_77(prefix, only)
    local all = {
        { "term", "shell" }, { "web", "docs" }, { "web", "mail" },
    }
    local targets = {}
    for index, entry in ipairs(all) do
        if not only or only[index] then
            table.insert(targets, target(prefix .. index, index == 1, 77, entry[1], entry[2]))
        end
    end
    return { area = { x = 0, y = 0, w = 1000, h = 800 }, targets = targets }, targets
end

local first, first_targets = workspace_77("first")
registered.provider.recalculate(first)
activate(first, first_targets[2])
assert(registered.provider.layout_msg(first, "move down") == true, "move command was rejected")
assert(registered.provider.layout_msg(first, "resize width grow") == true, "resize command was rejected")
registered.provider.recalculate(first)
local saved_docs = first_targets[2].placed
assert(saved_docs.y > first_targets[1].placed.y, "the moved window should sit below the first")

restart_layout()
local second, second_targets = workspace_77("second")
registered.provider.recalculate(second)
for index = 1, 3 do
    local old, new = first_targets[index].placed, second_targets[index].placed
    assert(math.abs(old.x - new.x) < 0.01 and math.abs(old.y - new.y) < 0.01
        and math.abs(old.w - new.w) < 0.01 and math.abs(old.h - new.h) < 0.01,
        "window " .. index .. " was not restored to its saved place")
end

-- Windows that return one by one keep their saved places, gaps included.
restart_layout()
local third, third_targets = workspace_77("third", { [2] = true })
registered.provider.recalculate(third)
assert(third_targets[1].placed.y > first_targets[1].placed.y - 0.01, "a lone restored window lost its row")
local partial_y = third_targets[1].placed.y
local fourth, fourth_targets = workspace_77("third", nil)
registered.provider.recalculate(fourth)
assert(math.abs(fourth_targets[2].placed.y - partial_y) < 0.01, "late windows moved the restored one")
assert(fourth_targets[1].placed.y < fourth_targets[2].placed.y, "a late window did not take its saved row")

-- Menu changes refresh existing windows, including zero-gap display edges.
local edge_config = assert(real_loadfile(root .. "/layout/config.lua"))()
edge_config.peek_x, edge_config.peek_y = 0, 0
edge_config.gap_x, edge_config.gap_y = 0, 0
hl.get_config = function(key)
    if key == "general.gaps_in" then return { left = 3, top = 5, right = 9, bottom = 11 } end
    if key == "general.border_size" then return 2 end
end
local edge_monitor = {
    x = -1280, y = 100,
    width = 1920, height = 1080, scale = 1.5, transform = 0,
    reserved = { left = 0, top = 20, right = 0, bottom = 0 },
}
local edge_a, edge_b, edge_c = target("edgeA", true, 101), target("edgeB", false, 101), target("edgeC", false, 101)
for _, item in ipairs({ edge_a, edge_b, edge_c }) do
    item.window.workspace.monitor = edge_monitor
end
local edges = {
    area = { x = -1270, y = 130, w = 1260, h = 680 },
    targets = { edge_a, edge_b, edge_c },
}
dispatch_context = edges
open_row(edges)
assert(_G.__omalattice_reload_config(edge_config))
activate(edges, edge_c)
assert(registered.provider.layout_msg(edges, "move down") == true)
assert(registered.provider.layout_msg(edges, "move left") == true)
assert(registered.provider.layout_msg(edges, "move left") == true)
activate(edges, edge_a)
registered.provider.recalculate(edges)

local function visible_box(item)
    local box = item.placed
    return { x = box.x + 5, y = box.y + 7, w = box.w - 16, h = box.h - 20 }
end
local edge_box, right_box, below_box = visible_box(edge_a), visible_box(edge_b), visible_box(edge_c)
assert(edge_box.x == -1280 and edge_box.y == 120, "zero peeks and gaps must remove outer margins, not bar reservations")
assert(edge_box.w == 1280 and edge_box.h == 700, "full-cell window must fill the monitor's usable area")
assert(right_box.x == edge_box.x + edge_box.w, "zero horizontal gap must make visible windows touch")
assert(below_box.y == edge_box.y + edge_box.h, "zero vertical gap must make visible windows touch")
assert(edges.area.x == -1270 and edges.area.w == 1260, "the compositor context must not be mutated")

edge_config.gap_x, edge_config.gap_y = 18, 24
assert(_G.__omalattice_reload_config(edge_config))
edge_box, right_box, below_box = visible_box(edge_a), visible_box(edge_b), visible_box(edge_c)
assert(right_box.x - edge_box.x - edge_box.w == 18, "menu horizontal gap must apply immediately without extra inset")
assert(below_box.y - edge_box.y - edge_box.h == 24, "menu vertical gap must apply immediately without extra inset")
assert(edge_box.x == edges.area.x and edge_box.y == edges.area.y, "nonzero gaps must preserve the normal outer area")

edge_config.gap_x = 0
assert(_G.__omalattice_reload_config(edge_config))
edge_box = visible_box(edge_a)
assert(edge_box.x == -1280 and edge_box.y == edges.area.y, "zero-gap edge expansion must be independent per axis")

edge_config.gap_y = 0
edge_monitor.transform = 1
assert(_G.__omalattice_reload_config(edge_config))
edge_box = visible_box(edge_a)
assert(edge_box.w == 720 and edge_box.h == 1260, "rotated scaled monitors must use transformed logical dimensions")
edge_monitor.scale = 1.3
assert(_G.__omalattice_reload_config(edge_config))
edge_box = visible_box(edge_a)
assert(edge_box.w == 831 and edge_box.h == 1457, "fractional scaling must round like the compositor")
dispatch_context = nil

os.execute("rm -rf '" .. state_home .. "'")
os.getenv = original_getenv
io.open = original_open

print("ok - mocked Hyprland adapter")
