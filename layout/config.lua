return {
    -- Optionally pin Omalattice to one workspace at startup. Leave unset to
    -- enable it per workspace by rotating the layout with Super+L.
    -- workspace = 9,

    -- Keep a visible strip of neighboring cells around the focused window. A
    -- full-size window fills the screen minus these strips, so the defaults
    -- leave it about 90% of the screen. With both at 0 it fills the whole area.
    peek_x = 96,
    peek_y = 32,
    gap_x = 12,
    gap_y = 12,

    -- Milliseconds the mouse must rest on another window before it takes focus
    -- on an Omalattice workspace. This stops the edge peeks from scrolling the
    -- grid while the pointer only passes over them. Set to 0 to keep Hyprland's
    -- immediate follow_mouse behaviour.
    hover_focus_delay = 150,

    -- Focus neighboring windows when the pointer rests on their visible peeks.
    -- Disable to require a click to focus windows on peeks.
    hover_focus_peeks = true,

    -- Number of fingers for the touchpad focus swipes: up/down always move
    -- focus, and left/right do too while an Omalattice workspace is active.
    gesture_fingers = 3,

    -- Touchpad travel, in Hyprland's swipe units, that slides the grid by one
    -- window or fully opens the overview. Swipes follow the fingers; lower is
    -- faster. Hyprland's own workspace swipe uses 300.
    swipe_distance = 300,

    -- Pan the grid and overview freely instead of using axis-based snap gestures.
    three_finger_pan = true,

    -- Number of fingers for the touchpad swipe that opens the overview (up)
    -- and closes it (down) on an Omalattice workspace. Set to 0 to disable.
    -- It must differ from `gesture_fingers`.
    overview_gesture_fingers = 4,

    -- Set to true if you configured a horizontal workspace swipe with
    -- `gesture_fingers` fingers (the Omarchy example enables one). It then
    -- gives way to the left/right focus swipes on Omalattice workspaces. Set to
    -- false if you have none, and the focus swipes are always active.
    workspace_swipe = true,

    -- Draw live scaled thumbnails of each window in the overview (needs the
    -- Omarchy shell service). Set to false to resize the real windows instead.
    overview_thumbnails = true,

    -- Speed in pixels per second at which a scrollable overview pans when the
    -- mouse is at the edge of the viewport; it slows toward the middle. Set to
    -- 0 to scroll only with the wheel and keys.
    overview_autoscroll_speed = 900,

    -- Smallest a window cell may shrink to in the overview, as a fraction of
    -- the viewport. Larger workspaces scroll instead of shrinking further.
    overview_min_width = 0.25,
    overview_min_height = 0.25,

    -- Window dimensions are fractions of one grid cell, which is the area left
    -- after the edge peeks. The largest preset fills it.
    width_steps = { 0.50, 0.67, 0.85, 1.00 },
    height_steps = { 0.50, 0.67, 0.85, 1.00 },
    default_width_step = 4,
    default_height_step = 4,
}
