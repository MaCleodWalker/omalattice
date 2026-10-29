if rawget(_G, "__omalattice_layout_registered") then return true end

local function current_dir()
    local source = debug and debug.getinfo(1, "S").source
    if type(source) ~= "string" or source:sub(1, 1) ~= "@" then
        error("omalattice: unable to resolve layout directory")
    end
    return source:sub(2):match("^(.*)/[^/]*$")
end

local function load_relative(filename)
    local chunk, err = loadfile(current_dir() .. "/" .. filename)
    if not chunk then error(err) end
    return chunk()
end

local config = load_relative("config.lua")
local settings = load_relative("settings.lua")
settings.apply(config)
local core = load_relative("core.lua")
local persist = load_relative("persist.lua")
local saved_layouts = persist.load()
local last_saved = {}
local save_failed = false
local workspaces = {}
local overview_status_path = os.getenv("XDG_RUNTIME_DIR")
    and (os.getenv("XDG_RUNTIME_DIR") .. "/omalattice-overview")
local overview_progress_path = overview_status_path and (overview_status_path .. "-progress")

local last_overview_status = nil

local function json_string(value)
    return '"' .. tostring(value):gsub('[%c"\\]', function(char)
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end

-- The shell reads this JSON to draw the overview. "payload" carries the
-- scroll bars and the window tiles while an overview is open, and once more as
-- it closes so the thumbnails can return to the windows.
local function write_overview_status(key, enabled, payload)
    if not overview_status_path then
        return nil, "XDG_RUNTIME_DIR is not set"
    end

    local status = string.format('{"workspace":%s,"overview":%s%s}',
        json_string(key), enabled and "true" or "false", payload or "")
    if status == last_overview_status then return true end

    local file, err = io.open(overview_status_path, "w")
    if not file then return nil, err end
    local ok, write_err = file:write(status)
    local closed, close_err = file:close()
    if not ok then return nil, write_err end
    if not closed then return nil, close_err end
    last_overview_status = status
    return true
end

-- How far a window is drawn inside its placed box: Hyprland's inner gaps and
-- the border.
local function window_insets()
    local ok, gaps = pcall(hl.get_config, "general.gaps_in")
    local border_ok, border = pcall(hl.get_config, "general.border_size")
    border = border_ok and tonumber(border) or 0
    local insets = {}
    for _, side in ipairs({ "left", "top", "right", "bottom" }) do
        local gap = ok and (type(gaps) == "table" and tonumber(gaps[side]) or tonumber(gaps)) or 0
        insets[side] = (gap or 0) + border
    end
    return insets
end

local function window_frame(box, insets)
    return {
        x = box.x - insets.left,
        y = box.y - insets.top,
        w = box.w + insets.left + insets.right,
        h = box.h + insets.top + insets.bottom,
    }
end

-- "origins" are the windows' boxes outside the overview. The shell grows each
-- thumbnail out of its window, so opening and closing look continuous.
local function overview_payload(ctx, state, descriptors, tiles, origins)
    local bars = core.overview_scrollbars(state, ctx.area, config)
    local grid = core.overview_grid(state, ctx.area, config)
    local grid_json = grid and string.format(
        ',"grid":{"x":%.2f,"y":%.2f,"w":%.2f,"h":%.2f,"gapX":%.2f,"gapY":%.2f,"columns":[%s],"rows":[%s]}',
        grid.x, grid.y, grid.w, grid.h, grid.gap_x, grid.gap_y,
        table.concat(grid.columns, ","), table.concat(grid.rows, ",")) or ""
    local entries = {}
    for _, id in ipairs(state.ids) do
        local descriptor, tile = descriptors[id], tiles[id]
        if descriptor and descriptor.address and tile then
            local origin = origins and origins[id]
            local from = ""
            if origin then
                from = string.format(',"fx":%.2f,"fy":%.2f,"fw":%.2f,"fh":%.2f',
                    origin.x, origin.y, origin.w, origin.h)
            end
            table.insert(entries, string.format('{"address":%s,"x":%.2f,"y":%.2f,"w":%.2f,"h":%.2f%s}',
                json_string(descriptor.address), tile.x, tile.y, tile.w, tile.h, from))
        end
    end

    return string.format(
        ',"thumbnails":%s,"area":{"x":%.2f,"y":%.2f,"w":%.2f,"h":%.2f},"bars":[%.4f,%.4f,%.4f,%.4f],"tiles":[%s]%s',
        config.overview_thumbnails ~= false and "true" or "false",
        ctx.area.x, ctx.area.y, ctx.area.w, ctx.area.h,
        bars.x.start, bars.x.size, bars.y.start, bars.y.size,
        table.concat(entries, ","), grid_json)
end

-- How far open the overview is while a swipe drives it. The shell follows
-- this while "dragging" is true and animates on its own otherwise.
local function write_overview_progress(progress, dragging)
    if not overview_progress_path then return end
    local file = io.open(overview_progress_path, "w")
    if not file then return end
    file:write(string.format('{"progress":%.4f,"dragging":%s}', progress, dragging and "true" or "false"))
    file:close()
end

if overview_status_path then
    local ok, err = write_overview_status("none", false)
    if not ok then
        io.stderr:write("omalattice: unable to reset overview status: " .. tostring(err) .. "\n")
    end
    write_overview_progress(0, false)
end

local function safe_field(value, field)
    if value == nil then return nil end
    local ok, result = pcall(function() return value[field] end)
    if ok then return result end
end

local function target_id(target, index)
    local window = safe_field(target, "window")
    local stable_id = safe_field(window, "stable_id")
    if stable_id ~= nil then return tostring(stable_id) end
    local address = safe_field(window, "address")
    if address then return "address:" .. tostring(address) end
    return "target:" .. tostring(safe_field(target, "index") or index)
end

local function workspace_key(ctx)
    for _, target in ipairs(ctx.targets or {}) do
        local window = safe_field(target, "window")
        local workspace = safe_field(window, "workspace")
        local id = safe_field(workspace, "id")
        if id ~= nil then return "workspace:" .. tostring(id) end
        local name = safe_field(workspace, "name")
        if name then return "workspace-name:" .. tostring(name) end
    end
    return "global"
end

local function layout_context(ctx)
    local edge_x = config.peek_x == 0 and config.gap_x == 0
    local edge_y = config.peek_y == 0 and config.gap_y == 0
    if not edge_x and not edge_y then return ctx end

    local monitor
    for _, target in ipairs(ctx.targets or {}) do
        local workspace = safe_field(safe_field(target, "window"), "workspace")
        monitor = safe_field(workspace, "monitor")
        if monitor then break end
    end
    if not monitor then return ctx end

    -- ctx.area excludes Hyprland's outer gaps as well as reserved layer surfaces.
    local width, height = monitor.width, monitor.height
    if monitor.transform % 2 == 1 then width, height = height, width end
    local reserved = monitor.reserved
    local area = {
        x = ctx.area.x, y = ctx.area.y,
        w = ctx.area.w, h = ctx.area.h,
    }
    if edge_x then
        area.x = monitor.x + reserved.left
        area.w = math.floor(width / monitor.scale + 0.5) - reserved.left - reserved.right
    end
    if edge_y then
        area.y = monitor.y + reserved.top
        area.h = math.floor(height / monitor.scale + 0.5) - reserved.top - reserved.bottom
    end
    return { area = area, targets = ctx.targets }
end

local function active_state()
    local ok, window = pcall(hl.get_active_window)
    if not ok or not window then return nil end

    local workspace = safe_field(window, "workspace")
    local id = safe_field(workspace, "id")
    local name = safe_field(workspace, "name")
    return id and workspaces["workspace:" .. tostring(id)]
        or name and workspaces["workspace-name:" .. tostring(name)]
        or workspaces.global
end

_G.__omalattice_is_overview_active = function()
    local state = active_state()
    return state and state.overview == true or false
end

-- Pans a scrollable overview while the pointer rests near the edge of the viewport.
local AUTOSCROLL_MS = 16
local autoscroll_timer = nil

local function autoscroll_tick()
    local state = active_state()
    local area = state and state.overview and state.view_area
    if not area then return end

    local ok, point = pcall(hl.get_cursor_pos)
    if not ok or not point then return end
    local vx, vy = core.edge_scroll_velocity(point, area, config)
    if vx == 0 and vy == 0 then return end

    local seconds = AUTOSCROLL_MS / 1000
    if core.scroll_overview_by(state, vx * seconds, vy * seconds, area, config) then
        hl.dispatch(hl.dsp.layout("refresh"))
    end
end

local function set_autoscroll(enabled)
    local speed = config.overview_autoscroll_speed
    if type(speed) ~= "number" or speed <= 0 then return end
    if not autoscroll_timer then
        if not enabled then return end
        autoscroll_timer = hl.timer(autoscroll_tick, { timeout = AUTOSCROLL_MS, type = "repeat" })
    end
    autoscroll_timer:set_enabled(enabled)
end

local function describe(ctx)
    local descriptors = {}
    local active_id = nil

    for index, target in ipairs(ctx.targets or {}) do
        local window = safe_field(target, "window")
        local id = target_id(target, index)
        descriptors[id] = {
            id = id,
            target = target,
            window = window,
            address = safe_field(window, "address"),
            class = safe_field(window, "class") or safe_field(window, "initial_class") or "",
            title = safe_field(window, "title") or "",
        }
        if safe_field(window, "active") then active_id = id end
    end

    return descriptors, active_id
end

local function context(ctx)
    local key = workspace_key(ctx)
    local state = workspaces[key]
    if not state then
        state = core.new_state()
        if key ~= "global" then state.restore = persist.begin_restore(saved_layouts[key]) end
        workspaces[key] = state
    end

    local descriptors, active_id = describe(ctx)
    local ids = {}
    for _, target in ipairs(ctx.targets or {}) do
        table.insert(ids, target_id(target, #ids + 1))
    end

    local restored = true
    if state.restore then
        restored = persist.claim(state, ids, descriptors, config)
        state.defer_compact = not restored
    end
    core.sync(state, ids, active_id, config)
    if state.restore and restored then persist.finish(state) end
    state.area = ctx.area
    state.descriptors = descriptors

    return state, descriptors
end

local function focus_descriptor(descriptor)
    if not descriptor or not descriptor.address then return end
    hl.dispatch(hl.dsp.focus({ window = "address:" .. descriptor.address }))
end

local function overview_changed()
    local state = active_state()
    set_autoscroll(state ~= nil and state.overview == true)
    local callback = rawget(_G, "__omalattice_overview_changed")
    if callback then pcall(callback) end
end

-- Saves the grid whenever it changes, but not while an earlier one is still
-- waiting for its windows, so a slow start cannot overwrite it.
local function save_layout(key, state, descriptors)
    if key == "global" or state.restore then return end

    local snapshot = persist.snapshot(state, descriptors)
    local encoded = persist.encode({ [key] = snapshot })
    if last_saved[key] == encoded then return end
    last_saved[key] = encoded
    saved_layouts[key] = snapshot

    local ok, written = pcall(persist.write, saved_layouts)
    if not ok or not written then
        if not save_failed then
            save_failed = true
            io.stderr:write("omalattice: unable to save workspace layouts\n")
        end
    end
end

local function recalculate(ctx)
    ctx = layout_context(ctx)
    local state, descriptors = context(ctx)
    local placements
    state.view_area = state.overview and ctx.area or nil
    if state.overview then
        local tiles = core.overview_placements(state, ctx.area, config)
        local thumbnails = config.overview_thumbnails ~= false
        local normal = core.placements(state, ctx.area, config)
        write_overview_status(workspace_key(ctx), true,
            overview_payload(ctx, state, descriptors, tiles, thumbnails and normal or nil))
        if thumbnails then
            -- The shell draws the thumbnails, so the windows keep their size. They are
            -- stacked on screen because the compositor only captures visible windows.
            placements = {}
            for id, box in pairs(normal) do
                placements[id] = {
                    x = ctx.area.x + (ctx.area.w - box.w) / 2,
                    y = ctx.area.y + (ctx.area.h - box.h) / 2,
                    w = box.w,
                    h = box.h,
                }
            end
        else
            placements = tiles
        end
    else
        placements = core.placements(state, ctx.area, config)
        if state.overview_closing then
            -- Tell the shell where the windows are going so the thumbnails meet them.
            state.overview_closing = nil
            local tiles = core.overview_placements(state, ctx.area, config)
            write_overview_status(workspace_key(ctx), false,
                overview_payload(ctx, state, descriptors, tiles, placements))
        end
        -- A swipe in progress slides the whole grid with the fingers.
        local drag = state.drag
        if drag and (drag.x ~= 0 or drag.y ~= 0) then
            for _, box in pairs(placements) do
                box.x = box.x - drag.x
                box.y = box.y - drag.y
            end
        end
    end

    local insets = window_insets()
    for id, descriptor in pairs(descriptors) do
        local placement = placements[id]
        if placement then descriptor.target:place(window_frame(placement, insets)) end
    end

    save_layout(workspace_key(ctx), state, descriptors)

    -- A click in the overview leaves the pointer over its thumbnail, so move it
    -- into the window that was just entered.
    if state.recenter_cursor and not state.overview then
        state.recenter_cursor = nil
        local active = placements[state.focused_id]
        if active then
            hl.dispatch(hl.dsp.cursor.move({ x = active.x + active.w / 2, y = active.y + active.h / 2 }))
        end
    end
end

local function layout_msg(ctx, message)
    ctx = layout_context(ctx)
    local state, descriptors = context(ctx)
    if message:match("^overview%-drop") then
        local address, col, row, workspace = message:match(
            "^overview%-drop%s+(%S+)%s+([%-]?%d+)%s+([%-]?%d+)%s+(.+)$")
        if not address then return "omalattice: overview-drop expects address column row workspace" end
        if not state.overview then return "omalattice: drops require an open overview" end
        if workspace ~= workspace_key(ctx) then return "omalattice: drop workspace has changed" end
        local id
        for candidate, descriptor in pairs(descriptors) do
            if descriptor.address == address then id = candidate; break end
        end
        if not id then return "omalattice: dropped window is no longer in this workspace" end
        local ok, err = core.move_to(state, id, tonumber(col), tonumber(row))
        if not ok then return "omalattice: " .. err end
        return true
    end
    local command, argument, extra = message:match("^(%S+)%s*(%S*)%s*(%S*)$")

    if command == "focus" then
        local id = core.focus(state, argument)
        focus_descriptor(id and descriptors[id])
    elseif command == "move" then
        core.move(state, argument)
    elseif command == "pan" then
        core.pan(state, argument)
    elseif command == "follow" or command == "center" then
        core.follow(state)
    elseif command == "overview" then
        local enabled = not state.overview
        local ok, err = write_overview_status(workspace_key(ctx), enabled)
        if not ok then return "omalattice: unable to update overview status: " .. tostring(err) end
        state.drag = nil
        state.overview_closing = not enabled and config.overview_thumbnails ~= false or nil
        core.set_overview(state, enabled)
        overview_changed()
    elseif command == "refresh" then
        return true
    elseif command == "overview-exit" then
        state.recenter_cursor = argument == "click" or nil
        local ok, err = write_overview_status(workspace_key(ctx), false)
        if not ok then return "omalattice: unable to update overview status: " .. tostring(err) end
        state.overview_closing = state.overview and config.overview_thumbnails ~= false or nil
        core.set_overview(state, false)
        overview_changed()
    elseif command == "scroll" then
        if state.overview then core.scroll_overview(state, argument, ctx.area, config) end
    elseif command == "pan-by" then
        local dx, dy = tonumber(argument), tonumber(extra)
        if not dx or not dy or dx ~= dx or dy ~= dy
            or dx == math.huge or dx == -math.huge or dy == math.huge or dy == -math.huge then
            return "omalattice: pan-by expects finite x and y deltas"
        end
        if state.overview then
            core.pan_overview_by(state, dx, dy, ctx.area, config)
        else
            core.pan_by(state, dx, dy)
        end
    elseif command == "snap-nearest" then
        local id = core.nearest_window(state, ctx.area, config)
        if id then
            state.focused_id = id
            if state.overview then
                state.overview_follow = true
            else
                core.follow(state)
                focus_descriptor(descriptors[id])
            end
        end
    elseif command == "resize" and argument == "width" then
        if extra ~= "grow" and extra ~= "shrink" then
            return "omalattice: resize width expects grow or shrink"
        end
        core.resize_width(state, config, extra == "grow" and 1 or -1)
    elseif command == "resize" and argument == "height" then
        if extra ~= "grow" and extra ~= "shrink" then
            return "omalattice: resize height expects grow or shrink"
        end
        core.resize_height(state, config, extra == "grow" and 1 or -1)
    else
        return "omalattice: expected focus/move/pan/scroll <direction>, pan-by <x> <y>, snap-nearest, resize width/height grow/shrink, or center"
    end

    return true
end

-- Touchpad swipes ----------------------------------------------------------
--
-- Hyprland reports every step of a swipe. Three-finger swipes slide the grid
-- with the fingers and settle on the nearest window when they lift (or the next
-- one after a flick). Four-finger swipes open the overview by the same amount.
-- `swipe_distance` is the touchpad travel that moves one window or fully opens
-- the overview.

local DRAG_DIRECTIONS = { x = { "left", "right" }, y = { "up", "down" } }
-- Windows per millisecond that count as a flick (one window in 250 ms).
local FLICK = 0.004
-- How far past a window a drag has to go before it settles on the next one.
local COMMIT = 0.3

local gesture = nil

-- Hyprland eases every window move, which would make the grid trail the
-- fingers, so animations are off while a drag is in progress.
local paused_animations = nil

local function pause_animations()
    if paused_animations ~= nil then return end
    local ok, enabled = pcall(hl.get_config, "animations.enabled")
    if not ok or enabled == false then return end
    paused_animations = enabled
    pcall(hl.config, { animations = { enabled = false } })
end

local function resume_animations()
    if paused_animations == nil then return end
    paused_animations = nil
    pcall(hl.config, { animations = { enabled = true } })
end

local function swipe_distance()
    local distance = tonumber(config.swipe_distance)
    return distance and distance > 0 and distance or 300
end

local function track_velocity(g, step, time_ms)
    time_ms = tonumber(time_ms)
    if time_ms and g.time and time_ms > g.time then
        g.velocity = step / (time_ms - g.time)
    end
    g.time = time_ms
end

-- Distances from the focused window to each window beyond it in `direction`.
local function drag_chain(state, axis, direction)
    local placements = core.placements(state, state.area, config)
    local size = axis == "x" and "w" or "h"
    local function center(box) return box[axis] + box[size] / 2 end
    local origin = placements[state.focused_id]
    local chain = { distances = {}, ids = {} }
    if not origin then return chain end

    local current = state.focused_id
    for _ = 1, 256 do
        local next_id = core.neighbor(state, direction, current)
        local box = next_id and placements[next_id]
        if not box then break end
        table.insert(chain.distances, math.abs(center(box) - center(origin)))
        table.insert(chain.ids, next_id)
        current = next_id
    end
    return chain
end

-- Pixel offset of the grid after dragging `windows` windows (fractional).
local function drag_offset(g, windows)
    local chain = windows >= 0 and g.forward or g.backward
    local sign = windows >= 0 and 1 or -1
    local amount = math.abs(windows)
    local distances = chain.distances
    local whole = math.floor(amount)

    if whole < #distances then
        local from = whole == 0 and 0 or distances[whole]
        return sign * (from + (amount - whole) * (distances[whole + 1] - from))
    end

    -- Past the last window the grid gives a little and then stops.
    local last = distances[#distances] or 0
    local span = g.axis == "x" and g.state.area.w or g.state.area.h
    local extra = amount - #distances
    return sign * (last + span * 0.1 * (1 - 1 / (1 + extra * 2)))
end

local function drag_begin(axis)
    local state = active_state()
    if not DRAG_DIRECTIONS[axis] or not state or state.overview or not state.area
        or not state.focused_id or not state.positions[state.focused_id] then
        return false
    end

    gesture = {
        kind = "drag",
        state = state,
        axis = axis,
        windows = 0,
        velocity = 0,
        backward = drag_chain(state, axis, DRAG_DIRECTIONS[axis][1]),
        forward = drag_chain(state, axis, DRAG_DIRECTIONS[axis][2]),
    }
    state.drag = { x = 0, y = 0 }
    pause_animations()
    return true
end

local function drag_update(delta, time_ms)
    local g = gesture
    if not g or g.kind ~= "drag" then return end

    local step = (tonumber(delta) or 0) / swipe_distance()
    g.windows = g.windows + step
    track_velocity(g, step, time_ms)

    local offset = drag_offset(g, g.windows)
    g.state.drag = { x = g.axis == "x" and offset or 0, y = g.axis == "y" and offset or 0 }
    hl.dispatch(hl.dsp.layout("refresh"))
end

-- Index of the window the drag settles on: 0 stays, n is the nth window along.
local function drag_target(g)
    local chain = g.windows >= 0 and g.forward or g.backward
    local amount = math.abs(g.windows)
    local index = math.floor(amount + (1 - COMMIT))
    local toward = g.velocity * (g.windows >= 0 and 1 or -1)
    if toward > FLICK then
        index = math.max(index, math.floor(amount) + 1)
    elseif toward < -FLICK then
        index = math.min(index, math.floor(amount))
    end
    index = math.min(index, #chain.ids)
    return index > 0 and chain.ids[index] or nil
end

local function drag_end(cancelled)
    local g = gesture
    if not g or g.kind ~= "drag" then return end
    gesture = nil

    local state = g.state
    state.drag = nil
    -- Back on before the grid settles, so it eases into place.
    resume_animations()
    local target = not cancelled and drag_target(g) or nil
    if target and state.positions[target] then
        state.focused_id = target
        core.follow(state)
        focus_descriptor(state.descriptors and state.descriptors[target])
    end
    hl.dispatch(hl.dsp.layout("refresh"))
end

local function pan_begin()
    local state = active_state()
    if not state or not state.area or gesture ~= nil then return false end

    gesture = {
        kind = "pan",
        state = state,
        x = 0,
        y = 0,
        scroll_x = state.overview_scroll.x,
        scroll_y = state.overview_scroll.y,
        initial_visibility = core.visible_areas(state, state.view_area or state.area, config),
    }
    if not state.overview then
        state.drag = { x = 0, y = 0 }
        pause_animations()
    end
    return true
end

local function pan_update(dx, dy)
    local g = gesture
    local function is_finite(value)
        return type(value) == "number" and value == value
            and value ~= math.huge and value ~= -math.huge
    end
    if not g or g.kind ~= "pan" or not is_finite(dx) or not is_finite(dy) then return end

    g.x = g.x + dx
    g.y = g.y + dy
    if g.state.overview then
        core.pan_overview_by(g.state, dx, dy, g.state.view_area, config)
    else
        g.state.drag = { x = -g.x, y = -g.y }
    end
    hl.dispatch(hl.dsp.layout("refresh"))
end

local function pan_end(cancelled, quick_direction)
    local g = gesture
    if not g or g.kind ~= "pan" then return end
    gesture = nil

    if core.pan_at_start(g.x, g.y) then quick_direction = nil end

    if g.state.overview then
        if cancelled then
            g.state.overview_scroll.x = g.scroll_x
            g.state.overview_scroll.y = g.scroll_y
        else
            local target
            if quick_direction then
                target = core.focus(g.state, quick_direction)
                    or core.nearest_window(g.state, g.state.view_area, config)
            else
                target = core.most_revealed_window(g.state, g.state.view_area, config,
                    g.initial_visibility, g.x, g.y)
            end
            if target then
                g.state.focused_id = target
                g.state.overview_follow = true
            end
        end
    else
        local target
        if not cancelled then
            if quick_direction then
                target = core.neighbor(g.state, quick_direction)
            else
                target = core.most_revealed_window(g.state, g.state.area, config,
                    g.initial_visibility, g.x, g.y)
            end
        end
        -- Focus callbacks must see the settled grid before warping the cursor.
        g.state.drag = nil
        resume_animations()
        if target then
            g.state.focused_id = target
            core.follow(g.state)
            focus_descriptor(g.state.descriptors and g.state.descriptors[target])
        end
    end
    hl.dispatch(hl.dsp.layout("refresh"))
end

-- `direction` is "up" or "down", from the start of the swipe.
local function overview_begin(direction)
    local state = active_state()
    if not state then return false end
    local open = state.overview == true
    direction = tostring(direction or ""):lower()
    if (open and direction ~= "down") or (not open and direction ~= "up") then return false end

    gesture = { kind = "overview", state = state, open = open, progress = open and 1 or 0, velocity = 0 }
    if config.overview_thumbnails ~= false then
        -- Written first, so the shell never starts its own opening animation.
        write_overview_progress(gesture.progress, true)
        if not open then hl.dispatch(hl.dsp.layout("overview")) end
    end
    return true
end

local function overview_update(dy, time_ms)
    local g = gesture
    if not g or g.kind ~= "overview" then return end

    local step = -(tonumber(dy) or 0) / swipe_distance()
    g.progress = math.max(0, math.min(1, g.progress + step))
    track_velocity(g, step, time_ms)
    if config.overview_thumbnails ~= false then write_overview_progress(g.progress, true) end
end

local function overview_end(cancelled)
    local g = gesture
    if not g or g.kind ~= "overview" then return end
    gesture = nil

    local open = g.open
    if not cancelled then
        open = g.progress >= 0.5
        if g.velocity > FLICK then
            open = true
        elseif g.velocity < -FLICK then
            open = false
        end
    end

    if open ~= (g.state.overview == true) then
        hl.dispatch(hl.dsp.layout(open and "overview" or "overview-exit"))
    end
    write_overview_progress(open and 1 or 0, false)
end

_G.__omalattice_gestures = {
    pan_begin = pan_begin,
    pan_update = pan_update,
    pan_end = pan_end,
    drag_begin = drag_begin,
    drag_update = drag_update,
    drag_end = drag_end,
    overview_begin = overview_begin,
    overview_update = overview_update,
    overview_end = overview_end,
    active = function() return gesture ~= nil end,
}

local function window_layout_name(window)
    local layout = safe_field(window, "layout")
    return safe_field(layout, "name")
end

if not rawget(_G, "__omalattice_focus_subscription") then
    local ok, subscription = pcall(function()
        return hl.on("window.active", function(window)
            if window_layout_name(window) == "lua:omalattice" then
                local workspace = safe_field(window, "workspace")
                local id = safe_field(workspace, "id")
                local name = safe_field(workspace, "name")
                local state = id and workspaces["workspace:" .. tostring(id)]
                    or name and workspaces["workspace-name:" .. tostring(name)]
                    or workspaces.global
                if not (state and state.overview) then
                    local result = hl.dispatch(hl.dsp.layout("follow"))
                    if result.ok and window.mapped and window.active then
                        local at, size = window.at, window.size
                        if at and size and size.x > 0 and size.y > 0 then
                            -- Leave the peek after scrolling so it cannot focus the next window.
                            hl.dispatch(hl.dsp.cursor.move({
                                x = at.x + size.x / 2,
                                y = at.y + size.y / 2,
                            }))
                        end
                    end
                end
            end
        end)
    end)
    if ok then _G.__omalattice_focus_subscription = subscription or true end
end

if not rawget(_G, "__omalattice_hover") then
    local ok, hover = pcall(function()
        -- Hover focus waits while the overview is open or a swipe moves the windows.
        return load_relative("hover.lua").start(config, function()
            return _G.__omalattice_is_overview_active() or gesture ~= nil
        end)
    end)
    if ok then
        _G.__omalattice_hover = hover or true
    else
        io.stderr:write("omalattice: unable to start hover focus: " .. tostring(hover) .. "\n")
    end
end

-- Takes new settings without re-registering the layout. The shared config
-- table is updated in place because the layout and hover code hold on to it.
_G.__omalattice_reload_config = function(fresh)
    if type(fresh) ~= "table" then return false end
    for key in pairs(config) do config[key] = nil end
    for key, value in pairs(fresh) do config[key] = value end
    local hover = rawget(_G, "__omalattice_hover")
    if type(hover) == "table" and hover.set_settings then
        hover.set_settings(config.hover_focus_delay, config.hover_focus_peeks)
    end
    pcall(hl.dispatch, hl.dsp.layout("refresh"))
    return true
end

hl.layout.register("omalattice", {
    recalculate = recalculate,
    layout_msg = layout_msg,
})

_G.__omalattice_layout_registered = true
return true
