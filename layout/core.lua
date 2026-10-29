local M = {}

local DIRECTIONS = {
    left = { dc = -1, dr = 0 },
    right = { dc = 1, dr = 0 },
    up = { dc = 0, dr = -1 },
    down = { dc = 0, dr = 1 },
}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then
            return true
        end
    end
    return false
end

local function position_key(col, row)
    return tostring(col) .. ":" .. tostring(row)
end

local function occupied_positions(state, except_id)
    local occupied = {}
    for id, position in pairs(state.positions) do
        if id ~= except_id then
            occupied[position_key(position.col, position.row)] = id
        end
    end
    return occupied
end

local function place_near(state, anchor)
    local occupied = occupied_positions(state)
    for _, direction in ipairs({ "right", "down", "left", "up" }) do
        local vector = DIRECTIONS[direction]
        local col, row = anchor.col + vector.dc, anchor.row + vector.dr
        if not occupied[position_key(col, row)] then
            return { col = col, row = row }
        end
    end

    local col = anchor.col + 1
    for _, position in pairs(state.positions) do
        if position.row == anchor.row and position.col >= col then
            position.col = position.col + 1
        end
    end
    return { col = col, row = anchor.row }
end

local function first_id(state)
    return state.ids[1]
end

-- Closes up empty columns or rows so the grid never has a blank band between
-- windows. The camera keeps pointing at the same place: an occupied line keeps
-- its window, an empty one inside the grid moves to the next window, and one
-- beyond the edge keeps its distance from the edge.
local function compact_axis(state, axis, camera_axis)
    local used, seen = {}, {}
    for _, position in pairs(state.positions) do
        local value = position[axis]
        if not seen[value] then
            seen[value] = true
            table.insert(used, value)
        end
    end
    if #used == 0 then return end

    table.sort(used)
    local index = {}
    local changed = false
    for i, value in ipairs(used) do
        index[value] = i - 1
        if value ~= i - 1 then changed = true end
    end
    if not changed then return end

    local camera = state.camera[camera_axis]
    if index[camera] ~= nil then
        camera = index[camera]
    elseif camera < used[1] then
        camera = camera - used[1]
    elseif camera > used[#used] then
        camera = (#used - 1) + (camera - used[#used])
    else
        local before = 0
        for _, value in ipairs(used) do
            if value < camera then before = before + 1 end
        end
        camera = before
    end
    state.camera[camera_axis] = camera

    for _, position in pairs(state.positions) do position[axis] = index[position[axis]] end
end

local function compact(state)
    compact_axis(state, "col", "col")
    compact_axis(state, "row", "row")
end

function M.new_state()
    return {
        ids = {},
        positions = {},
        width_step_by_id = {},
        height_step_by_id = {},
        focused_id = nil,
        observed_active_id = nil,
        camera = { col = 0, row = 0, offset_x = 0, offset_y = 0 },
        overview = false,
        overview_scroll = { x = 0, y = 0 },
        overview_follow = false,
    }
end

function M.sync(state, ids, active_id, config)
    local present = {}
    local unique_ids = {}

    for _, id in ipairs(ids or {}) do
        if not present[id] then
            present[id] = true
            table.insert(unique_ids, id)
        end
    end

    for id in pairs(state.positions) do
        if not present[id] then
            state.positions[id] = nil
            state.width_step_by_id[id] = nil
            state.height_step_by_id[id] = nil
        end
    end

    state.ids = unique_ids

    for _, id in ipairs(unique_ids) do
        if not state.positions[id] then
            local anchor_id = active_id and state.positions[active_id] and active_id
                or state.focused_id and state.positions[state.focused_id] and state.focused_id
                or first_id(state)
            local anchor = anchor_id and state.positions[anchor_id]

            if anchor then
                state.positions[id] = place_near(state, anchor)
            else
                state.positions[id] = { col = 0, row = 0 }
            end

            state.width_step_by_id[id] = config.default_width_step
            state.height_step_by_id[id] = config.default_height_step
        end
    end

    local focus_changed = false
    if active_id and present[active_id] then
        focus_changed = state.observed_active_id ~= active_id
        state.observed_active_id = active_id
        state.focused_id = active_id
    elseif not state.focused_id or not present[state.focused_id] then
        state.focused_id = unique_ids[1]
        state.observed_active_id = state.focused_id
        focus_changed = state.focused_id ~= nil
    end

    if focus_changed and state.focused_id and state.positions[state.focused_id] then
        local focused = state.positions[state.focused_id]
        state.camera.col = focused.col
        state.camera.row = focused.row
        state.camera.offset_x = 0
        state.camera.offset_y = 0
        if state.overview then state.overview_follow = true end
    end

    -- A restored grid keeps its gaps until the rest of its windows return.
    if not state.defer_compact then compact(state) end
end

local function directional_metrics(origin, candidate, direction)
    local dc = candidate.col - origin.col
    local dr = candidate.row - origin.row

    if direction == "left" and dc >= 0 then return nil end
    if direction == "right" and dc <= 0 then return nil end
    if direction == "up" and dr >= 0 then return nil end
    if direction == "down" and dr <= 0 then return nil end

    local along = (direction == "left" or direction == "right") and math.abs(dc) or math.abs(dr)
    local across = (direction == "left" or direction == "right") and math.abs(dr) or math.abs(dc)

    return {
        aligned = across == 0 and 0 or 1,
        across = across,
        along = along,
        distance = math.abs(dc) + math.abs(dr),
    }
end

local function metrics_less(a, b)
    if a.aligned ~= b.aligned then return a.aligned < b.aligned end
    if a.across ~= b.across then return a.across < b.across end
    if a.along ~= b.along then return a.along < b.along end
    if a.distance ~= b.distance then return a.distance < b.distance end
    return tostring(a.id) < tostring(b.id)
end

-- The window that focus would move to from `from_id` (default: the focused one).
function M.neighbor(state, direction, from_id)
    from_id = from_id or state.focused_id
    if not DIRECTIONS[direction] or not from_id then return nil end

    local origin = state.positions[from_id]
    if not origin then return nil end

    local candidates = {}
    for id, position in pairs(state.positions) do
        if id ~= from_id then
            local metrics = directional_metrics(origin, position, direction)
            if metrics then
                metrics.id = id
                table.insert(candidates, metrics)
            end
        end
    end

    table.sort(candidates, metrics_less)
    return candidates[1] and candidates[1].id or nil
end

function M.focus(state, direction)
    local target = M.neighbor(state, direction)
    if not target then return nil end

    state.focused_id = target
    if state.overview then
        state.overview_follow = true
    else
        M.follow(state)
    end
    return target
end

function M.move(state, direction)
    local vector = DIRECTIONS[direction]
    local focused_id = state.focused_id
    local focused = focused_id and state.positions[focused_id]
    if not vector or not focused then return false end

    return M.move_to(state, focused_id, focused.col + vector.dc, focused.row + vector.dr)
end

function M.move_to(state, id, col, row)
    local position = state.positions[id]
    if not position then return false, "window is no longer in this workspace" end
    if col == nil or row == nil then return false, "destination requires a column and row" end
    for _, value in ipairs({ col, row }) do
        if type(value) ~= "number" or value ~= value or value % 1 ~= 0
            or value <= -1000000 or value >= 1000000 then
            return false, "destination must be an integer cell within the grid limits"
        end
    end
    if position.col == col and position.row == row then return true end

    local destination_id = occupied_positions(state, id)[position_key(col, row)]

    if destination_id then
        local other = state.positions[destination_id]
        other.col, other.row = position.col, position.row
    end
    position.col, position.row = col, row

    compact(state)
    M.follow(state)
    return true
end

function M.follow(state)
    local focused = state.focused_id and state.positions[state.focused_id]
    if not focused then return false end
    state.camera.col = focused.col
    state.camera.row = focused.row
    state.camera.offset_x = 0
    state.camera.offset_y = 0
    return true
end

function M.set_overview(state, enabled)
    state.overview = not not enabled
    if state.overview then
        state.overview_follow = true
    else
        M.follow(state)
    end
    return state.overview
end

function M.pan(state, direction)
    local vector = DIRECTIONS[direction]
    if not vector then return false end
    state.camera.col = state.camera.col + vector.dc
    state.camera.row = state.camera.row + vector.dr
    return true
end

local function is_finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

function M.pan_by(state, dx, dy)
    if not is_finite(dx) or not is_finite(dy) then return false end
    state.camera.offset_x = state.camera.offset_x + dx
    state.camera.offset_y = state.camera.offset_y + dy
    return true
end

local function resize_step(state, map, steps, delta)
    local id = state.focused_id
    if not id or not state.positions[id] then return false end
    local current = map[id] or #steps
    local next_step = clamp(current + delta, 1, #steps)
    map[id] = next_step
    return next_step ~= current
end

function M.resize_width(state, config, delta)
    return resize_step(state, state.width_step_by_id, config.width_steps, delta)
end

function M.resize_height(state, config, delta)
    return resize_step(state, state.height_step_by_id, config.height_steps, delta)
end

function M.placements(state, area, config)
    local peek_x = clamp(config.peek_x or 0, 0, math.max(0, (area.w - 1) / 2))
    local peek_y = clamp(config.peek_y or 0, 0, math.max(0, (area.h - 1) / 2))
    local maximum_width = math.max(1, area.w - (peek_x * 2))
    local maximum_height = math.max(1, area.h - (peek_y * 2))
    local gap_x = math.max(0, config.gap_x or 0)
    local gap_y = math.max(0, config.gap_y or 0)
    local center_x = area.x + (area.w / 2)
    local center_y = area.y + (area.h / 2)
    local placements = {}
    local dimensions = {}
    local column_widths = {}
    local row_heights = {}
    local min_col, max_col = state.camera.col, state.camera.col
    local min_row, max_row = state.camera.row, state.camera.row

    for id, position in pairs(state.positions) do
        local width_step = clamp(state.width_step_by_id[id] or config.default_width_step, 1, #config.width_steps)
        local height_step = clamp(state.height_step_by_id[id] or config.default_height_step, 1, #config.height_steps)
        local width = maximum_width * config.width_steps[width_step]
        local height = maximum_height * config.height_steps[height_step]

        dimensions[id] = { w = width, h = height }
        column_widths[position.col] = math.max(column_widths[position.col] or 0, width)
        row_heights[position.row] = math.max(row_heights[position.row] or 0, height)
        min_col = math.min(min_col, position.col)
        max_col = math.max(max_col, position.col)
        min_row = math.min(min_row, position.row)
        max_row = math.max(max_row, position.row)
    end

    local default_width = maximum_width * config.width_steps[config.default_width_step]
    local default_height = maximum_height * config.height_steps[config.default_height_step]
    for col = min_col, max_col do
        column_widths[col] = column_widths[col] or default_width
    end
    for row = min_row, max_row do
        row_heights[row] = row_heights[row] or default_height
    end

    local column_centers = { [state.camera.col] = center_x }
    for col = state.camera.col + 1, max_col do
        column_centers[col] = column_centers[col - 1]
            + (column_widths[col - 1] / 2) + gap_x + (column_widths[col] / 2)
    end
    for col = state.camera.col - 1, min_col, -1 do
        column_centers[col] = column_centers[col + 1]
            - (column_widths[col + 1] / 2) - gap_x - (column_widths[col] / 2)
    end

    local row_centers = { [state.camera.row] = center_y }
    for row = state.camera.row + 1, max_row do
        row_centers[row] = row_centers[row - 1]
            + (row_heights[row - 1] / 2) + gap_y + (row_heights[row] / 2)
    end
    for row = state.camera.row - 1, min_row, -1 do
        row_centers[row] = row_centers[row + 1]
            - (row_heights[row + 1] / 2) - gap_y - (row_heights[row] / 2)
    end

    for id, position in pairs(state.positions) do
        local size = dimensions[id]

        placements[id] = {
            x = column_centers[position.col] - (size.w / 2) + (state.camera.offset_x or 0),
            y = row_centers[position.row] - (size.h / 2) + (state.camera.offset_y or 0),
            w = size.w,
            h = size.h,
        }
    end

    return placements
end

function M.nearest_window(state, area, config)
    local placements = state.overview
        and M.overview_placements(state, area, config)
        or M.placements(state, area, config)
    local center_x = area.x + area.w / 2
    local center_y = area.y + area.h / 2
    local nearest_id, nearest_distance

    for id, box in pairs(placements) do
        local drag = not state.overview and state.drag
        local dx = box.x - (drag and drag.x or 0) + box.w / 2 - center_x
        local dy = box.y - (drag and drag.y or 0) + box.h / 2 - center_y
        local distance = (dx * dx) + (dy * dy)
        if nearest_distance == nil or distance < nearest_distance
            or (distance == nearest_distance and tostring(id) < tostring(nearest_id)) then
            nearest_id, nearest_distance = id, distance
        end
    end

    return nearest_id
end

function M.visible_areas(state, area, config)
    local placements = state.overview
        and M.overview_placements(state, area, config)
        or M.placements(state, area, config)
    local drag = not state.overview and state.drag
    local visible = {}
    for id, box in pairs(placements) do
        local x = box.x - (drag and drag.x or 0)
        local y = box.y - (drag and drag.y or 0)
        local width = math.max(0, math.min(x + box.w, area.x + area.w) - math.max(x, area.x))
        local height = math.max(0, math.min(y + box.h, area.y + area.h) - math.max(y, area.y))
        visible[id] = width * height
    end
    return visible
end

function M.pan_at_start(dx, dy)
    return math.max(math.abs(dx), math.abs(dy)) < 8
end

-- Content moves opposite to the direction in which new windows are revealed.
function M.most_revealed_window(state, area, config, initial_visibility, dx, dy)
    local origin = state.positions[state.focused_id]
    if not origin or M.pan_at_start(dx, dy) then return state.focused_id end
    local horizontal = math.abs(dx) >= 2 * math.abs(dy)
    local vertical = math.abs(dy) >= 2 * math.abs(dx)
    local visible = M.visible_areas(state, area, config)
    local best, best_gain = state.focused_id, 0
    local nearest, nearest_distance
    for _, id in ipairs(state.ids) do
        local position = state.positions[id]
        if position and initial_visibility[id] ~= nil then
            local col, row = position.col - origin.col, position.row - origin.row
            local aligned
            if horizontal then
                aligned = col * dx < 0 and row == 0
            elseif vertical then
                aligned = row * dy < 0 and col == 0
            else
                aligned = col * dx < 0 and row * dy < 0
            end
            local gain = (visible[id] or 0) - initial_visibility[id]
            local distance = col * col + row * row
            if aligned and (nearest_distance == nil or distance < nearest_distance
                or distance == nearest_distance and tostring(id) < tostring(nearest)) then
                nearest, nearest_distance = id, distance
            end
            if aligned and (gain > best_gain
                or gain > 0 and gain == best_gain and tostring(id) < tostring(best)) then
                best, best_gain = id, gain
            end
        end
    end
    return best_gain > 0 and best or nearest or state.focused_id
end

-- Dense grid used by the overview: empty rows and columns are skipped, and a
-- cell never shrinks below the configured fraction of the viewport. When the
-- cells no longer fit, the content is larger than the viewport and scrolls.
local function overview_metrics(state, area, config)
    local columns, rows = {}, {}
    local column_index, row_index = {}, {}
    for _, position in pairs(state.positions) do
        if not column_index[position.col] then
            column_index[position.col] = true
            table.insert(columns, position.col)
        end
        if not row_index[position.row] then
            row_index[position.row] = true
            table.insert(rows, position.row)
        end
    end

    if #columns == 0 then return nil end

    table.sort(columns)
    table.sort(rows)
    for index, col in ipairs(columns) do column_index[col] = index end
    for index, row in ipairs(rows) do row_index[row] = index end

    local column_count = #columns
    local row_count = #rows
    local padding_x = math.min(area.w * 0.04, area.w / 2)
    local padding_y = math.min(area.h * 0.04, area.h / 2)
    local usable_width = area.w - (padding_x * 2)
    local usable_height = area.h - (padding_y * 2)
    local max_gap_x = column_count > 1 and math.max(0, (usable_width - column_count) / (column_count - 1)) or 0
    local max_gap_y = row_count > 1 and math.max(0, (usable_height - row_count) / (row_count - 1)) or 0
    local gap_x = column_count > 1 and math.max(0, math.min(config.gap_x or 0, max_gap_x)) or 0
    local gap_y = row_count > 1 and math.max(0, math.min(config.gap_y or 0, max_gap_y)) or 0
    local fit_width = (usable_width - (gap_x * (column_count - 1))) / column_count
    local fit_height = (usable_height - (gap_y * (row_count - 1))) / row_count
    local min_fraction_x = clamp(config.overview_min_width or 0.25, 0, 1)
    local min_fraction_y = clamp(config.overview_min_height or 0.25, 0, 1)
    local cell_width, cell_height
    if config.overview_thumbnails ~= false then
        -- Thumbnails scale every window by the same factor, so cells keep the
        -- proportions of the viewport and the windows keep their shapes.
        local scale = math.max(math.min(fit_width / area.w, fit_height / area.h), min_fraction_x, min_fraction_y)
        cell_width, cell_height = area.w * scale, area.h * scale
    else
        cell_width = math.max(fit_width, area.w * min_fraction_x)
        cell_height = math.max(fit_height, area.h * min_fraction_y)
    end

    return {
        columns = columns,
        rows = rows,
        column_index = column_index,
        row_index = row_index,
        padding_x = padding_x,
        padding_y = padding_y,
        gap_x = gap_x,
        gap_y = gap_y,
        cell_width = cell_width,
        cell_height = cell_height,
        content_width = (padding_x * 2) + (cell_width * column_count) + (gap_x * (column_count - 1)),
        content_height = (padding_y * 2) + (cell_height * row_count) + (gap_y * (row_count - 1)),
    }
end

-- Content smaller than the viewport is centered instead of hugging a corner.
local function centering(metrics, area)
    return math.max(0, (area.w - metrics.content_width) / 2), math.max(0, (area.h - metrics.content_height) / 2)
end

local function grid_geometry(metrics, state, area)
    local offset_x, offset_y = centering(metrics, area)
    return {
        x = offset_x + metrics.padding_x - state.overview_scroll.x,
        y = offset_y + metrics.padding_y - state.overview_scroll.y,
        w = metrics.cell_width, h = metrics.cell_height,
        gap_x = metrics.gap_x, gap_y = metrics.gap_y,
        columns = metrics.columns, rows = metrics.rows,
    }
end

function M.overview_grid(state, area, config)
    local metrics = overview_metrics(state, area, config)
    return metrics and grid_geometry(metrics, state, area) or nil
end

-- Keep one cell axis inside the viewport, preferring the leading edge.
local function reveal(scroll, start, size, padding, viewport)
    if start - padding < scroll then
        return start - padding
    elseif start + size + padding > scroll + viewport then
        return start + size + padding - viewport
    end
    return scroll
end

function M.overview_placements(state, area, config)
    local metrics = overview_metrics(state, area, config)
    if not metrics then return {} end

    local scroll = state.overview_scroll
    local focused = state.focused_id and state.positions[state.focused_id]
    if state.overview_follow and focused then
        local focused_col = metrics.column_index[focused.col] - 1
        local focused_row = metrics.row_index[focused.row] - 1
        scroll.x = reveal(scroll.x, metrics.padding_x + focused_col * (metrics.cell_width + metrics.gap_x),
            metrics.cell_width, metrics.padding_x, area.w)
        scroll.y = reveal(scroll.y, metrics.padding_y + focused_row * (metrics.cell_height + metrics.gap_y),
            metrics.cell_height, metrics.padding_y, area.h)
    end
    state.overview_follow = false
    scroll.x = clamp(scroll.x, 0, math.max(0, metrics.content_width - area.w))
    scroll.y = clamp(scroll.y, 0, math.max(0, metrics.content_height - area.h))

    local placements = {}
    local grid = grid_geometry(metrics, state, area)

    for id, position in pairs(state.positions) do
        local width_step = clamp(state.width_step_by_id[id] or config.default_width_step, 1, #config.width_steps)
        local height_step = clamp(state.height_step_by_id[id] or config.default_height_step, 1, #config.height_steps)
        local width = metrics.cell_width * config.width_steps[width_step]
        local height = metrics.cell_height * config.height_steps[height_step]
        local cell_x = area.x + grid.x
            + ((metrics.column_index[position.col] - 1) * (metrics.cell_width + metrics.gap_x))
        local cell_y = area.y + grid.y
            + ((metrics.row_index[position.row] - 1) * (metrics.cell_height + metrics.gap_y))

        placements[id] = {
            x = cell_x + ((metrics.cell_width - width) / 2),
            y = cell_y + ((metrics.cell_height - height) / 2),
            w = width,
            h = height,
        }
    end

    return placements
end

-- Scrolls the overview by a pixel distance, stopping at the content edges.
-- Returns whether the view actually moved.
function M.scroll_overview_by(state, dx, dy, area, config)
    local metrics = overview_metrics(state, area, config)
    if not metrics then return false end

    local scroll = state.overview_scroll
    local x = clamp(scroll.x + dx, 0, math.max(0, metrics.content_width - area.w))
    local y = clamp(scroll.y + dy, 0, math.max(0, metrics.content_height - area.h))
    local moved = x ~= scroll.x or y ~= scroll.y
    scroll.x, scroll.y = x, y
    return moved
end

-- Scrolls the overview by half a cell. Wheel input is independent of the
-- selection, so it does not ask the view to follow the focused window.
function M.scroll_overview(state, direction, area, config)
    local vector = DIRECTIONS[direction]
    local metrics = vector and overview_metrics(state, area, config)
    if not metrics then return false end

    M.scroll_overview_by(state,
        vector.dc * (metrics.cell_width + metrics.gap_x) / 2,
        vector.dr * (metrics.cell_height + metrics.gap_y) / 2, area, config)
    return true
end

-- Auto-scroll speed in pixels per second for a pointer at `point`: zero in the
-- middle of the viewport, rising to the configured speed at its edges.
function M.edge_scroll_velocity(point, area, config)
    local speed = config.overview_autoscroll_speed
    if type(speed) ~= "number" or speed <= 0 then return 0, 0 end
    if point.x < area.x or point.x > area.x + area.w or point.y < area.y or point.y > area.y + area.h then
        return 0, 0
    end

    local edge = math.min(area.w, area.h) * 0.12
    local function axis(position, start, length)
        local from_start = position - start
        local from_end = start + length - position
        if from_start < edge then return -speed * (1 - from_start / edge) end
        if from_end < edge then return speed * (1 - from_end / edge) end
        return 0
    end
    return axis(point.x, area.x, area.w), axis(point.y, area.y, area.h)
end

function M.pan_overview_by(state, dx, dy, area, config)
    if not is_finite(dx) or not is_finite(dy) then return false end
    return M.scroll_overview_by(state, -dx, -dy, area, config)
end

-- Thumb start and size, as fractions of the track, for each scrollable axis.
-- An axis that fits in the viewport reports a full-size thumb.
function M.overview_scrollbars(state, area, config)
    local metrics = overview_metrics(state, area, config)
    local bars = { x = { start = 0, size = 1 }, y = { start = 0, size = 1 } }
    if not metrics then return bars end

    local scroll = state.overview_scroll
    if metrics.content_width > area.w + 0.5 then
        bars.x = { start = scroll.x / metrics.content_width, size = area.w / metrics.content_width }
    end
    if metrics.content_height > area.h + 0.5 then
        bars.y = { start = scroll.y / metrics.content_height, size = area.h / metrics.content_height }
    end
    return bars
end

function M.position_of(state, id)
    return state.positions[id]
end

function M.size_steps_of(state, id)
    return state.width_step_by_id[id], state.height_step_by_id[id]
end

function M.has_id(state, id)
    return contains(state.ids, id)
end

return M
