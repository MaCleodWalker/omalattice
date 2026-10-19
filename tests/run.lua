local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)/[^/]+$") or "tests"
local root = tests_dir:match("^(.*)/tests$") or "."
local core = assert(loadfile(root .. "/layout/core.lua"))()
local config = assert(loadfile(root .. "/layout/config.lua"))()
local passed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        io.stderr:write("FAIL: " .. name .. "\n" .. tostring(err) .. "\n")
        os.exit(1)
    end
    passed = passed + 1
    print("ok - " .. name)
end

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

local function fresh(ids, active)
    local state = core.new_state()
    local opened = {}
    for _, id in ipairs(ids) do
        table.insert(opened, id)
        core.sync(state, opened, id, config)
    end
    core.sync(state, ids, active, config)
    return state
end

test("first window starts at origin", function()
    local state = fresh({ "A" }, "A")
    equal(core.position_of(state, "A").col, 0)
    equal(core.position_of(state, "A").row, 0)
end)

test("new windows extend right when opened from the last window", function()
    local state = fresh({ "A", "B", "C" }, "A")
    equal(core.position_of(state, "B").col, 1)
    equal(core.position_of(state, "C").col, 2)
end)

test("new windows fill adjacent holes in right down left up order", function()
    local neighbors = {
        { col = 2, row = 1 },
        { col = 1, row = 2 },
        { col = 0, row = 1 },
        { col = 1, row = 0 },
    }
    for next_hole = 1, #neighbors do
        local state = fresh({ "A", "B", "C", "D", "E", "F" }, "A")
        state.positions.A = { col = 1, row = 1 }
        state.positions.B = { col = 0, row = 0 }
        state.positions.C = { col = 2, row = 2 }
        local ids = { "A", "B", "C" }
        for index = 1, next_hole - 1 do
            local id = ({ "D", "E", "F" })[index]
            state.positions[id] = { col = neighbors[index].col, row = neighbors[index].row }
            table.insert(ids, id)
        end
        table.insert(ids, "new")
        core.sync(state, ids, "new", config)
        equal(state.positions.new.col, neighbors[next_hole].col)
        equal(state.positions.new.row, neighbors[next_hole].row)
        equal(state.positions.A.col, 1)
        equal(state.positions.C.col, 2, "other windows must not shift when filling a hole")
        equal(state.focused_id, "new")
        equal(state.camera.col, neighbors[next_hole].col)
        equal(state.camera.row, neighbors[next_hole].row)
        equal(state.width_step_by_id.new, config.default_width_step)
        equal(state.height_step_by_id.new, config.default_height_step)
    end
end)

test("no adjacent hole inserts right and shifts only the focused row", function()
    local state = fresh({ "A", "B", "C", "D", "E", "F" }, "B")
    state.positions.A = { col = 0, row = 1 }
    state.positions.B = { col = 1, row = 1 }
    state.positions.C = { col = 2, row = 1 }
    state.positions.D = { col = 1, row = 2 }
    state.positions.E = { col = 2, row = 2 }
    state.positions.F = { col = 1, row = 0 }
    state.width_step_by_id.C = 1
    state.height_step_by_id.C = 2
    core.sync(state, { "A", "B", "C", "D", "E", "F", "new" }, "new", config)
    equal(state.positions.new.col, 2)
    equal(state.positions.new.row, 1)
    equal(state.positions.A.col, 0)
    equal(state.positions.B.col, 1)
    equal(state.positions.C.col, 3)
    equal(state.positions.D.col, 1)
    equal(state.positions.E.col, 2)
    equal(state.positions.F.col, 1)
    equal(state.positions.F.row, 0)
    equal(state.width_step_by_id.C, 1)
    equal(state.height_step_by_id.C, 2)
    equal(state.camera.col, 2)
end)

test("empty neighbors outside the grid are used before shifting", function()
    for _, direction in ipairs({ "right", "down", "left", "up" }) do
        local state = fresh({ "A", "B", "C", "D" }, "A")
        state.positions.A = { col = 0, row = 0 }
        local ids = { "A" }
        local vectors = {
            right = { col = 1, row = 0 },
            down = { col = 0, row = 1 },
            left = { col = -1, row = 0 },
            up = { col = 0, row = -1 },
        }
        local expected = vectors[direction]
        for _, candidate in ipairs({ "right", "down", "left", "up" }) do
            if candidate == direction then break end
            local id = ({ "B", "C", "D" })[#ids]
            state.positions[id] = { col = vectors[candidate].col, row = vectors[candidate].row }
            table.insert(ids, id)
        end
        table.insert(ids, "new")
        core.sync(state, ids, "new", config)
        equal(state.positions.new.col - state.positions.A.col, expected.col, direction)
        equal(state.positions.new.row - state.positions.A.row, expected.row, direction)
        for _, id in ipairs(ids) do
            if id ~= "A" and id ~= "new" then
                local original = id == "B" and vectors.right
                    or id == "C" and vectors.down or vectors.left
                equal(state.positions[id].col - state.positions.A.col, original.col)
                equal(state.positions[id].row - state.positions.A.row, original.row)
            end
        end
    end
end)

test("multiple new windows insert without collisions and repeated sync is stable", function()
    local state = fresh({ "A", "B", "C" }, "B")
    local ids = { "A", "B", "C", "D", "E" }
    core.sync(state, ids, "B", config)
    equal(state.positions.A.col, 0)
    equal(state.positions.B.col, 1)
    equal(state.positions.D.col, 1)
    equal(state.positions.D.row, 2)
    equal(state.positions.E.col, 1)
    equal(state.positions.E.row, 0)
    equal(state.positions.B.row, 1)
    equal(state.positions.C.col, 2)
    core.sync(state, ids, "B", config)
    equal(state.positions.E.col, 1)
    equal(state.positions.E.row, 0)
    equal(state.positions.D.col, 1)
    equal(state.positions.D.row, 2)
    equal(state.positions.C.col, 2)
end)

test("moving down creates a second row", function()
    local state = fresh({ "A", "B" }, "B")
    assert(core.move(state, "down"))
    equal(core.position_of(state, "B").col, 1)
    equal(core.position_of(state, "B").row, 1)
    equal(state.camera.row, 1)
end)

test("moving into an occupied cell swaps windows", function()
    local state = fresh({ "A", "B" }, "B")
    assert(core.move(state, "left"))
    equal(core.position_of(state, "B").col, 0)
    equal(core.position_of(state, "A").col, 1)
end)

test("absolute moves swap nonfocused windows without changing selection or presets", function()
    local state = fresh({ "A", "B", "C" }, "A")
    state.width_step_by_id.B = 1
    state.height_step_by_id.C = 2
    core.set_overview(state, true)
    assert(core.move_to(state, "B", 2, 0))
    equal(state.positions.B.col, 2)
    equal(state.positions.C.col, 1)
    equal(state.focused_id, "A")
    equal(state.camera.col, 0)
    equal(state.width_step_by_id.B, 1)
    equal(state.height_step_by_id.C, 2)
    equal(state.overview, true)
end)

test("absolute moves create rows and compact empty columns", function()
    local state = fresh({ "A", "B", "C" }, "A")
    assert(core.move_to(state, "B", 0, 1))
    equal(state.positions.B.col, 0)
    equal(state.positions.B.row, 1)
    equal(state.positions.C.col, 1)
    assert(core.move_to(state, "C", -1, -1))
    equal(state.positions.C.col, 0)
    equal(state.positions.C.row, 0)
    equal(state.positions.A.col, 1)
    equal(state.positions.A.row, 1)
    equal(state.camera.col, 1)
    equal(state.camera.row, 1)
end)

test("absolute moves reject invalid destinations and missing windows without mutations", function()
    local state = fresh({ "A", "B" }, "A")
    for _, value in ipairs({ 0.5, "1", false, math.huge, -math.huge, 0/0, 1000000, -1000000 }) do
        local ok, err = core.move_to(state, "A", value, 0)
        equal(ok, false)
        assert(type(err) == "string")
        equal(core.move_to(state, "A", 0, value), false)
    end
    equal(core.move_to(state, "A", nil, 0), false)
    equal(core.move_to(state, "A", 0, nil), false)
    equal(core.move_to(state, "missing", 0, 0), false)
    equal(state.positions.A.col, 0)
    equal(state.positions.A.row, 0)
    equal(state.positions.B.col, 1)
    equal(state.positions.B.row, 0)
    equal(state.camera.col, 0)
    assert(core.move_to(state, "A", 0, 0))
end)

test("focus prefers a window aligned on the requested axis", function()
    local state = fresh({ "A", "B", "C" }, "A")
    core.move(state, "down")
    state.focused_id = "A"
    core.follow(state)
    equal(core.focus(state, "right"), "B")
end)

test("focus moves vertically", function()
    local state = fresh({ "A", "B" }, "B")
    core.move(state, "down")
    state.focused_id = "A"
    core.follow(state)
    equal(core.focus(state, "down"), "B")
end)

test("overview fits every window and preserves arrow selection until exit", function()
    local state = fresh({ "A", "B", "C" }, "B")
    core.move(state, "down")
    core.set_overview(state, true)
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    local placements = core.overview_placements(state, area, config)

    for _, placement in pairs(placements) do
        assert(placement.x >= area.x and placement.y >= area.y)
        assert(placement.x + placement.w <= area.x + area.w)
        assert(placement.y + placement.h <= area.y + area.h)
    end

    local camera_col, camera_row = state.camera.col, state.camera.row
    equal(core.focus(state, "left"), "A")
    equal(state.camera.col, camera_col, "overview camera column")
    equal(state.camera.row, camera_row, "overview camera row")
    core.set_overview(state, false)
    equal(state.camera.col, core.position_of(state, "A").col, "camera follows selected window")
    equal(state.camera.row, core.position_of(state, "A").row, "camera follows selected window")
end)

test("overview packs sparse positions into dense rows and columns", function()
    local state = fresh({ "A", "B", "C" }, "A")
    state.positions.A = { col = -1000, row = 50 }
    state.positions.B = { col = 1000, row = -90 }
    state.positions.C = { col = 1000000, row = 10000 }
    local placements = core.overview_placements(state, { x = 0, y = 0, w = 300, h = 200 }, config)

    for _, placement in pairs(placements) do
        assert(placement.x >= 0 and placement.y >= 0)
        assert(placement.x + placement.w <= 300)
        assert(placement.y + placement.h <= 200)
    end
end)

test("overview drop grid matches thumbnail cells with sparse coordinates and scrolling", function()
    local state = fresh({ "A", "B", "C" }, "A")
    state.positions.A = { col = -10, row = 50 }
    state.positions.B = { col = 30, row = -20 }
    state.positions.C = { col = 70, row = 50 }
    state.overview_scroll = { x = 20, y = 10 }
    local area = { x = -1000, y = 200, w = 1000, h = 800 }
    local placements = core.overview_placements(state, area, config)
    local grid = core.overview_grid(state, area, config)
    equal(grid.columns[1], -10)
    equal(grid.columns[2], 30)
    equal(grid.columns[3], 70)
    equal(grid.rows[1], -20)
    equal(grid.rows[2], 50)
    for id, position in pairs(state.positions) do
        local c, r
        for index, col in ipairs(grid.columns) do if col == position.col then c = index - 1 end end
        for index, row in ipairs(grid.rows) do if row == position.row then r = index - 1 end end
        local box = placements[id]
        local expected_x = area.x + grid.x + c * (grid.w + grid.gap_x) + (grid.w - box.w) / 2
        local expected_y = area.y + grid.y + r * (grid.h + grid.gap_y) + (grid.h - box.h) / 2
        assert(math.abs(box.x - expected_x) < 0.001)
        assert(math.abs(box.y - expected_y) < 0.001)
    end
    equal(core.overview_grid(core.new_state(), area, config), nil)
end)

test("overview caps gaps when the viewport is too small for all cells", function()
    local state = fresh({ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" }, "A")
    for index, id in ipairs(state.ids) do
        state.positions[id] = { col = index * 1000, row = index * -1000 }
    end
    local overview_config = {
        width_steps = { 1 },
        height_steps = { 1 },
        default_width_step = 1,
        default_height_step = 1,
        gap_x = 1000,
        gap_y = 1000,
        overview_min_width = 0,
        overview_min_height = 0,
    }
    local area = { x = 0, y = 0, w = 50, h = 40 }
    local placements = core.overview_placements(state, area, overview_config)

    for _, placement in pairs(placements) do
        assert(placement.x >= area.x and placement.y >= area.y)
        assert(placement.x + placement.w <= area.x + area.w)
        assert(placement.y + placement.h <= area.y + area.h)
    end
end)

local function spread(count)
    local ids = {}
    for index = 1, count do ids[index] = "W" .. index end
    local state = fresh(ids, "W1")
    for index, id in ipairs(ids) do state.positions[id] = { col = index - 1, row = 0 } end
    return state, ids
end

test("overview never shrinks a cell below the minimum and scrolls instead", function()
    local state = spread(8)
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    core.set_overview(state, true)
    local placements = core.overview_placements(state, area, config)

    for _, placement in pairs(placements) do
        assert(placement.w >= 250 * config.width_steps[config.default_width_step] - 0.01,
            "overview window shrank below the minimum width")
    end

    local bars = core.overview_scrollbars(state, area, config)
    assert(bars.x.size < 1, "horizontal scroll bar should appear")
    equal(bars.y.size, 1, "vertical axis fits")
end)

test("overview thumbnails keep the window proportions and center small workspaces", function()
    local state = spread(2)
    local area = { x = 100, y = 50, w = 1000, h = 800 }
    core.set_overview(state, true)
    local placements = core.overview_placements(state, area, config)

    local width_step, height_step = core.size_steps_of(state, "W1")
    local expected = (config.height_steps[height_step] * area.h) / (config.width_steps[width_step] * area.w)
    for _, placement in pairs(placements) do
        assert(math.abs(placement.h / placement.w - expected) < 1e-6, "tile proportions drifted")
    end

    local left, right = placements.W1, placements.W2
    local gap_left = left.x - area.x
    local gap_right = (area.x + area.w) - (right.x + right.w)
    assert(math.abs(gap_left - gap_right) < 1e-6, "tiles should be centered horizontally")
    local top = math.min(left.y, right.y) - area.y
    local bottom = (area.y + area.h) - math.max(left.y + left.h, right.y + right.h)
    assert(math.abs(top - bottom) < 1e-6, "tiles should be centered vertically")
end)

test("overview scrolls by wheel and clamps at the content edges", function()
    local state = spread(8)
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    core.set_overview(state, true)
    core.overview_placements(state, area, config)

    local before = core.overview_placements(state, area, config).W1.x
    assert(core.scroll_overview(state, "right", area, config))
    local after = core.overview_placements(state, area, config).W1.x
    assert(after < before, "scrolling right should move the content left")

    for _ = 1, 100 do core.scroll_overview(state, "right", area, config) end
    local bars = core.overview_scrollbars(state, area, config)
    assert(math.abs((bars.x.start + bars.x.size) - 1) < 1e-6, "scroll should clamp at the end")

    for _ = 1, 100 do core.scroll_overview(state, "left", area, config) end
    equal(core.overview_scrollbars(state, area, config).x.start, 0, "scroll should clamp at the start")
    assert(not core.scroll_overview(state, "sideways", area, config), "unknown direction was accepted")
end)

test("overview scrolls by a distance and reports whether it moved", function()
    local state = spread(8)
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    core.set_overview(state, true)
    core.overview_placements(state, area, config)

    assert(core.scroll_overview_by(state, 40, 0, area, config), "scrolling by a distance did not move")
    equal(state.overview_scroll.x, 40, "scroll distance")
    assert(core.scroll_overview_by(state, -500, 0, area, config), "scrolling back should move")
    equal(state.overview_scroll.x, 0, "scroll should clamp at the start")
    assert(not core.scroll_overview_by(state, -10, 0, area, config), "scrolling past the start should not move")
end)

test("overview auto-scroll speeds up toward the viewport edges", function()
    local area = { x = 100, y = 50, w = 1000, h = 800 }
    local function velocity(x, y, speed)
        return core.edge_scroll_velocity({ x = x, y = y }, area, { overview_autoscroll_speed = speed or 900 })
    end

    local vx, vy = velocity(600, 450)
    equal(vx, 0, "centre x") equal(vy, 0, "centre y")
    vx = velocity(100, 450)
    equal(vx, -900, "left edge")
    vx = velocity(1100, 450)
    equal(vx, 900, "right edge")
    local _, top = velocity(600, 50)
    equal(top, -900, "top edge")
    local _, bottom = velocity(600, 850)
    equal(bottom, 900, "bottom edge")
    local near = velocity(100 + 48, 450)
    assert(near < 0 and near > -900, "speed should ease toward the middle")
    vx, vy = velocity(1105, 450)
    equal(vx, 0, "outside the viewport") equal(vy, 0, "outside the viewport y")
    vx = velocity(100, 450, 0)
    equal(vx, 0, "disabled")
    vx = core.edge_scroll_velocity({ x = 100, y = 450 }, area, {})
    equal(vx, 0, "unset")
end)

test("overview scrolls the selected window into view", function()
    local state = spread(8)
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    core.set_overview(state, true)
    core.overview_placements(state, area, config)

    for _ = 1, 7 do core.focus(state, "right") end
    equal(state.focused_id, "W8")
    local placement = core.overview_placements(state, area, config).W8
    assert(placement.x >= area.x and placement.x + placement.w <= area.x + area.w,
        "selected window should be fully visible")

    for _ = 1, 7 do core.focus(state, "left") end
    placement = core.overview_placements(state, area, config).W1
    assert(placement.x >= area.x, "first window should scroll back into view")
end)

test("overview does not scroll when every cell fits", function()
    local state = spread(3)
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    core.set_overview(state, true)
    core.overview_placements(state, area, config)
    local bars = core.overview_scrollbars(state, area, config)
    equal(bars.x.size, 1)
    equal(bars.y.size, 1)
end)

test("width and height presets are independent", function()
    local state = fresh({ "A" }, "A")
    core.resize_width(state, config, -1)
    core.resize_height(state, config, -1)
    core.resize_height(state, config, -1)
    local width_step, height_step = core.size_steps_of(state, "A")
    equal(width_step, config.default_width_step - 1)
    equal(height_step, config.default_height_step - 2)
end)

test("resize clamps at preset boundaries", function()
    local state = fresh({ "A" }, "A")
    for _ = 1, 10 do core.resize_width(state, config, -1) end
    local width_step = core.size_steps_of(state, "A")
    equal(width_step, 1)
    for _ = 1, 10 do core.resize_width(state, config, 1) end
    width_step = core.size_steps_of(state, "A")
    equal(width_step, #config.width_steps)
end)

test("without peeks the largest preset fills the whole area", function()
    local state = fresh({ "A" }, "A")
    local flat = {}
    for key, value in pairs(config) do flat[key] = value end
    flat.peek_x, flat.peek_y = 0, 0
    local placements = core.placements(state, { x = 10, y = 20, w = 1000, h = 800 }, flat)
    equal(placements.A.x, 10)
    equal(placements.A.y, 20)
    equal(placements.A.w, 1000)
    equal(placements.A.h, 800)
end)

test("maximum cell leaves horizontal and vertical peeks", function()
    local state = fresh({ "A", "B" }, "A")
    state.width_step_by_id.A = #config.width_steps
    state.height_step_by_id.A = #config.height_steps
    state.width_step_by_id.B = #config.width_steps
    state.height_step_by_id.B = #config.height_steps
    state.focused_id = "B"
    core.move(state, "down")
    state.focused_id = "A"
    core.follow(state)
    local peek_config = {}
    for key, value in pairs(config) do peek_config[key] = value end
    peek_config.peek_x, peek_config.peek_y, peek_config.gap_y = 48, 48, 12
    local placements = core.placements(state, { x = 0, y = 0, w = 1000, h = 800 }, peek_config)
    equal(placements.A.x, 48)
    equal(placements.A.y, 48)
    equal(placements.A.w, 904)
    equal(placements.A.h, 704)
    equal(placements.B.y, 764)
end)

test("smaller presets keep neighboring rows visible", function()
    local state = fresh({ "A", "B" }, "A")
    state.focused_id = "B"
    core.move(state, "down")
    state.focused_id = "A"
    core.follow(state)
    local placements = core.placements(state, { x = 0, y = 0, w = 1000, h = 800 }, config)
    assert(placements.B.y < 800, "the next row should peek into the viewport")
    assert(placements.B.y > placements.A.y, "the next row should remain below the focused row")
end)

test("camera follows focus in both dimensions", function()
    local state = fresh({ "A", "B" }, "B")
    core.move(state, "down")
    equal(state.camera.col, 1)
    equal(state.camera.row, 1)
end)

test("manual camera pan survives ordinary synchronization", function()
    local state = fresh({ "A" }, "A")
    core.pan(state, "down")
    core.sync(state, { "A" }, "A", config)
    equal(state.camera.row, 1)
end)

test("continuous pan moves placements by the exact delta on both axes", function()
    local state = fresh({ "A" }, "A")
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    local before = core.placements(state, area, config).A

    assert(core.pan_by(state, 23.5, -11.25))
    local after = core.placements(state, area, config).A
    assert(math.abs(after.x - before.x - 23.5) < 1e-6, "horizontal pan delta")
    assert(math.abs(after.y - before.y + 11.25) < 1e-6, "vertical pan delta")
end)

test("ordinary pan release snaps the nearest window to center", function()
    local state = fresh({ "A", "B" }, "A")
    local area = { x = 0, y = 0, w = 1000, h = 800 }
    core.pan_by(state, -700, 0)
    equal(core.nearest_window(state, area, config), "B")
    state.focused_id = core.nearest_window(state, area, config)
    assert(core.follow(state))
    equal(state.camera.offset_x, 0)
    equal(state.camera.col, core.position_of(state, "B").col)
end)

test("following focus resets the continuous pan offset", function()
    local state = fresh({ "A" }, "A")
    core.pan_by(state, 20, -9)
    assert(core.follow(state))
    equal(state.camera.offset_x, 0)
    equal(state.camera.offset_y, 0)
end)

test("overview gesture pan moves content 1:1 on both axes", function()
    local ids = {}
    local state = core.new_state()
    for i = 1, 25 do
        ids[i] = tostring(i)
    end
    core.sync(state, ids, "1", config)
    for i, id in ipairs(ids) do
        state.positions[id] = { col = (i - 1) % 5, row = math.floor((i - 1) / 5) }
    end

    local area = { x = 0, y = 0, w = 100, h = 100 }
    core.set_overview(state, true)
    state.overview_follow = false
    assert(core.pan_overview_by(state, -20, -30, area, config))
    local before = core.overview_placements(state, area, config)["1"]
    assert(core.pan_overview_by(state, 5, -7, area, config))
    local after = core.overview_placements(state, area, config)["1"]
    equal(state.overview_scroll.x, 15, "horizontal overview scroll")
    equal(state.overview_scroll.y, 37, "vertical overview scroll")
    assert(math.abs(after.x - before.x - 5) < 1e-6, "horizontal overview pan delta")
    assert(math.abs(after.y - before.y + 7) < 1e-6, "vertical overview pan delta")
end)

test("closing a window closes the gap it leaves", function()
    local state = fresh({ "A", "B", "C" }, "B")
    core.sync(state, { "A", "C" }, "C", config)
    assert(not core.has_id(state, "B"))
    equal(core.position_of(state, "A").col, 0)
    equal(core.position_of(state, "C").col, 1, "survivor should close up against its neighbor")

    local placements = core.placements(state, { x = 0, y = 0, w = 1000, h = 800 }, config)
    local blank = placements.C.x - (placements.A.x + placements.A.w)
    assert(math.abs(blank - config.gap_x) < 0.001, "blank space between windows: " .. blank)
end)

test("moving a window out of a column closes the empty column", function()
    local state = fresh({ "A", "B", "C" }, "B")
    assert(core.move(state, "down"))
    assert(core.move(state, "left"))
    equal(core.position_of(state, "B").col, 0)
    equal(core.position_of(state, "B").row, 1)
    equal(core.position_of(state, "C").col, 1, "column left empty by the move should close")
    equal(state.camera.col, 0, "camera follows the moved window")
    equal(state.camera.row, 1)
end)

test("closing the focused window keeps the camera on its neighbor", function()
    local state = fresh({ "A", "B", "C" }, "B")
    core.sync(state, { "A", "C" }, "C", config)
    equal(state.focused_id, "C")
    equal(state.camera.col, core.position_of(state, "C").col)
end)

test("a pan past the edge keeps its distance when the grid closes up", function()
    local state = fresh({ "A", "B", "C" }, "B")
    core.pan(state, "left")
    core.pan(state, "left")
    equal(state.camera.col, -1)
    core.sync(state, { "B", "C" }, "B", config)
    equal(core.position_of(state, "B").col, 0)
    assert(state.camera.col < 0, "camera should stay left of the grid")
end)

print(string.format("omalattice: %d tests passed", passed))
