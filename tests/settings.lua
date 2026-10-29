local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)/[^/]+$") or "tests"
local root = tests_dir:match("^(.*)/tests$") or "."

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "'"))

local env = {
    OMALATTICE_CONFIG = dir .. "/config.lua",
    XDG_RUNTIME_DIR = dir,
}
local original_getenv = os.getenv
os.getenv = function(name) return env[name] end

local settings = assert(loadfile(root .. "/layout/settings.lua"))()
local function defaults() return assert(loadfile(root .. "/layout/config.lua"))() end
local function write_overrides(text)
    local file = assert(io.open(env.OMALATTICE_CONFIG, "w"))
    file:write(text)
    file:close()
end

-- A missing file changes nothing.
local config, base = settings.apply(defaults())
assert(config.gap_x == 12 and base.gap_x == 12, "defaults changed without an override file")

-- Valid values apply, and the defaults are kept for comparison.
write_overrides([[return {
    gap_x = 20, peek_y = 9999, overview_thumbnails = false,
    width_steps = { 0.5, 1 }, default_width_step = 4, overview_min_width = 1, unknown = 1,
}]])
config, base = settings.apply(defaults())
assert(config.gap_x == 20 and base.gap_x == 12, "override was not applied")
assert(config.peek_y == 500, "out-of-range values should be clamped")
assert(config.overview_min_width == 0.5, "the overview minimum must leave room to scroll")
assert(config.overview_thumbnails == false, "boolean override was not applied")
assert(#config.width_steps == 2 and config.default_width_step == 2,
    "the default step should stay within the presets")
assert(config.unknown == nil, "unknown keys must be ignored")

-- Wrong types and broken files fall back to the defaults.
local stderr = io.stderr
io.stderr = { write = function() end }
write_overrides('return { gap_x = "wide", gap_y = 0/0, width_steps = {} }')
config = settings.apply(defaults())
assert(config.gap_x == 12 and config.gap_y == 12 and #config.width_steps == 4, "invalid values were applied")
write_overrides("this is not lua")
config = settings.apply(defaults())
assert(config.gap_x == 12, "a broken file should be ignored")
write_overrides('os.execute("touch ' .. dir .. '/pwned") return {}')
settings.apply(defaults())
local pwned = io.open(dir .. "/pwned", "r")
assert(not pwned, "the override file must not run code")
io.stderr = stderr

-- The effective and default values are published for the shell menu.
write_overrides("return { gap_x = 20, workspace_swipe = false }")
config, base = settings.apply(defaults())
assert(settings.publish(config, base))
local file = assert(io.open(dir .. "/omalattice-config", "r"))
local status = file:read("a")
file:close()
assert(status:find('"values":{', 1, true) and status:find('"gap_x":20', 1, true), "status misses the override")
assert(status:find('"defaults":{', 1, true) and status:find('"gap_x":12', 1, true), "status misses the defaults")
assert(status:find('"workspace_swipe":false', 1, true), "status misses a boolean")
assert(status:find('"hover_focus_peeks":true', 1, true), "status misses the peek-hover setting")
assert(status:find('"width_steps":[0.5,0.67,0.85,1]', 1, true), "status misses a list")

os.getenv = original_getenv
os.execute("rm -rf '" .. dir .. "'")
print("ok - user settings")
