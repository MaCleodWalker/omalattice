-- Debounced focus-follows-mouse for Omalattice workspaces.
--
-- Hyprland's own follow_mouse focuses a window the instant the pointer enters
-- it, which makes the edge peeks scroll the grid while the mouse only passes
-- over them. While an Omalattice workspace is active this switches follow_mouse
-- to click-to-focus and focuses the hovered window itself once the pointer has
-- rested on it for config.hover_focus_delay milliseconds.
local LAYOUT = "lua:omalattice"
local POLL_MS = 20
local FOLLOW_MOUSE_ALWAYS = 1
local FOLLOW_MOUSE_CLICK = 2
local KEYBOARD_EXCLUSIVE = 1

local M = {}

local function safe_field(value, field)
    if value == nil then return nil end
    local ok, result = pcall(function() return value[field] end)
    if ok then return result end
end

local function contains(box_at, box_size, point)
    local x, y = safe_field(box_at, "x"), safe_field(box_at, "y")
    local w, h = safe_field(box_size, "x"), safe_field(box_size, "y")
    if not (x and y and w and h) then return false end
    return point.x >= x and point.x < x + w and point.y >= y and point.y < y + h
end

local function window_at(workspace, point)
    local ok, windows = pcall(hl.get_workspace_windows, workspace)
    if not ok or type(windows) ~= "table" then return nil end

    local found = nil
    for _, window in ipairs(windows) do
        if window.mapped and not window.hidden and contains(window.at, window.size, point) then
            -- Floating windows are drawn above tiled ones.
            if not found or window.floating then found = window end
        end
    end
    return found
end

-- A launcher that grabs the keyboard must not lose focus to the window under the
-- pointer. Click-through overlays, such as full-screen shell layers, do not.
local function keyboard_grabbed()
    local ok, layers = pcall(hl.get_layers)
    if not ok or type(layers) ~= "table" then return false end

    for _, layer in ipairs(layers) do
        if layer.mapped and layer.interactivity == KEYBOARD_EXCLUSIVE then return true end
    end
    return false
end

function M.start(config, is_overview_active)
    local delay = tonumber(config.hover_focus_delay) or 0
    local focus_peeks = config.hover_focus_peeks ~= false
    local timer = nil
    local original_follow_mouse = nil
    local candidate, candidate_ticks, last_point = nil, 0, nil

    local function reset()
        candidate, candidate_ticks = nil, 0
    end

    local function poll()
        if not focus_peeks or delay <= 0 then return reset() end
        local ok, point = pcall(hl.get_cursor_pos)
        if not ok or not point then return reset() end
        local moved = not last_point or last_point.x ~= point.x or last_point.y ~= point.y
        last_point = { x = point.x, y = point.y }

        -- The pointer was already in place when the overview closed, so it has
        -- to move again before it can change focus.
        if is_overview_active() then return reset() end
        if not moved and not candidate then return end

        local active_ok, workspace = pcall(hl.get_active_workspace)
        if not active_ok or not workspace or safe_field(workspace, "tiled_layout") ~= LAYOUT
            or safe_field(workspace, "has_fullscreen") then
            return reset()
        end

        local window = window_at(workspace, point)
        if not window or window.active or keyboard_grabbed() then
            return reset()
        end

        if candidate ~= window.address then
            candidate, candidate_ticks = window.address, 0
            return
        end

        candidate_ticks = candidate_ticks + 1
        if candidate_ticks * POLL_MS >= delay then
            reset()
            hl.dispatch(hl.dsp.focus({ window = "address:" .. window.address }))
        end
    end

    local function set_polling(enabled)
        if not timer then
            if not enabled then return end
            timer = hl.timer(poll, { timeout = POLL_MS, type = "repeat" })
        end
        timer:set_enabled(enabled)
        if not enabled then
            reset()
            last_point = nil
        end
    end

    -- Hyprland's own hover focus is replaced only when the user left it at the
    -- default, so a deliberate follow_mouse setting is respected.
    local function set_native_follow(enabled, force)
        if enabled and not original_follow_mouse then
            local ok, value = pcall(hl.get_config, "input.follow_mouse")
            if ok and (value == FOLLOW_MOUSE_ALWAYS or force and value ~= FOLLOW_MOUSE_CLICK) then
                original_follow_mouse = value
                hl.config({ input = { follow_mouse = FOLLOW_MOUSE_CLICK } })
            end
        elseif not enabled and original_follow_mouse then
            hl.config({ input = { follow_mouse = original_follow_mouse } })
            original_follow_mouse = nil
        end
    end

    local function sync()
        local ok, workspace = pcall(hl.get_active_workspace)
        local active = ok and safe_field(workspace, "tiled_layout") == LAYOUT
            and not safe_field(workspace, "special")
        set_native_follow(active and (delay > 0 or not focus_peeks), not focus_peeks)
        -- Without the native override the pointer cannot be debounced.
        set_polling(active and focus_peeks and delay > 0 and original_follow_mouse ~= nil)
    end

    local function set_settings(value, allow_peek_focus)
        delay = tonumber(value) or 0
        focus_peeks = allow_peek_focus ~= false
        reset()
        sync()
    end

    pcall(hl.on, "workspace.active", sync)
    pcall(hl.on, "monitor.focused", sync)
    pcall(hl.on, "window.active", sync)
    pcall(hl.on, "config.reloaded", function()
        original_follow_mouse = nil
        sync()
    end)
    sync()

    return { sync = sync, poll = poll, set_settings = set_settings }
end

return M
