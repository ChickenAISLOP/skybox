-- ============================================================================
-- sky_rotation.lua  -  drive sky_orientation/rotation continuously
-- ============================================================================
--
-- WHAT THIS IS
-- The feature the investigation was for. sky_orientation/rotation is a live,
-- writable environment value present in all 225 environments:
--
--   local key = Idstring("sky_orientation/rotation"):key()   -- 3c084f67b1da34be
--   local h = managers.viewport:first_active_viewport()._env_handler
--   h:editor_set_value(key, degrees)
--
-- Verified in-game: read 338 -> write 68 -> read back 68 -> restore 338, with the
-- dome visibly rotating and returning.
--
-- CALLS USED, AND WHY THEY ARE SAFE
--   managers.viewport:first_active_viewport()   proven by sky_rot_probe
--   viewport._env_handler                        proven by sky_rot_probe
--   handler:get_value(key)                      proven by sky_rot_probe
--   handler:editor_set_value(key, number)       proven by sky_rot_probe
--   Hooks:Add("GameSetupUpdate", ...)           already used by environment_hook.lua
-- Nothing here is a guessed signature. The two-value editor_set_value call and
-- the single-key get_value call are the exact shapes that were measured.
--
-- FAILURE HANDLING
-- A Lua error inside a GameSetupUpdate hook terminates the game, so the per-frame
-- body runs under pcall exactly like Env.update in environment_hook.lua. On top of
-- that, native calls can fault where pcall cannot help, so a call that raises
-- repeatedly disables the driver instead of hammering it - one bad frame should
-- not cost 3600 more.
-- ============================================================================

_G.sky_rotation = _G.sky_rotation or {}
local R = _G.sky_rotation

if R._loaded then return end
R._loaded = true

R.KEY = Idstring("sky_orientation/rotation"):key()

-- settings, own namespace so it cannot collide with the texture settings
R.enabled    = R.enabled == true
R.speed      = R.speed or 4.0      -- degrees per second, any value, negative reverses

-- runtime state
R.angle      = nil        -- our own angle, so we never read every frame
R.original   = nil        -- what the level had, for restore
R.running    = false
R.writes     = 0
R.errors     = 0
R.disabled_by_error = false

local function out(s)
	if log then log("[skyrot] " .. s) end
end

-- Throttled.
--
-- step_impl now retries start() every frame while the viewport is missing,
-- which is the whole time during a loading screen. Without this, each retry
-- would write a log line and append to sky_rotation.log - hundreds of file
-- writes per level load. Identical messages collapse together; numbers are
-- generalised so genuine changes still get through, and the seen-set is
-- bounded so it cannot grow without limit.
local _seen = {}
local function note(s)
	local key = s:gsub("%.%d+", "N")
	if _seen[key] then return end
	_seen[key] = true
	local n = 0
	for _ in pairs(_seen) do n = n + 1 end
	if n > 40 then _seen = {} end

	out(s)
	local f = io.open(SavePath .. "sky_rotation.log", "a")
	if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n"); f:close() end
end

-- ---------------------------------------------------------------------------
-- handler
-- ---------------------------------------------------------------------------

local function handler()
	if not (managers and managers.viewport) then return nil end
	local ok, vp = pcall(function() return managers.viewport:first_active_viewport() end)
	if not ok or not vp then return nil end
	local g, h = pcall(function() return vp._env_handler end)
	if not g or not h then return nil end
	if type(h.editor_set_value) ~= "function" then return nil end
	return h
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function R.start()
	if R.running then return true end

	local h = handler()
	if not h then
		note("start refused: no viewport _env_handler")
		return false
	end

	-- Only start if we can actually read the current angle. Starting blind would
	-- mean snapping the sky to an arbitrary value on the first frame.
	local ok, cur = pcall(function() return h:get_value(R.KEY) end)
	if not ok or type(cur) ~= "number" then
		note("start refused: could not read the current rotation (" .. tostring(cur) .. ")")
		return false
	end

	R.original = cur
	R.angle    = cur
	R.running  = true
	R.errors   = 0
	R.disabled_by_error = false
	note(string.format("started at %.2f deg, speed %.3f deg/s", cur, R.speed))
	return true
end

function R.stop(restore)
	local h = handler()
	R.running = false
	if not h then return end

	local target = (restore ~= false) and R.original or R.angle
	if target == nil then return end

	local ok, err = pcall(function() return h:editor_set_value(R.KEY, target) end)
	if ok then
		note(string.format("stopped, rotation left at %.2f", target))
	else
		note("stop: editor_set_value raised (" .. tostring(err) .. ")")
	end
	R.angle = nil
	R.original = nil
end

function R.set_enabled(on)
	R.enabled = on == true
	if R.enabled then
		R.start()
	else
		R.stop(true)
	end
	R.save()
end

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------
--
-- enabled and speed used to be plain module variables, so they reset to false /
-- 4.0 on every game launch and the driver had to be switched on by hand each
-- session. Saved next to the other mod state instead.

R.SETTINGS_FILE = "sky_rotation_settings.json"

function R.save()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "w")
	if not f then return end
	f:write(string.format('{"enabled":%s,"speed":%.3f}\n',
		R.enabled and "true" or "false", R.speed))
	f:close()
end

function R.load()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "r")
	if not f then return end
	local body = f:read("*all")
	f:close()
	if not body then return end
	local on = body:match('"enabled"%s*:%s*(true)')
	if on then R.enabled = true end
	local sp = body:match('"speed"%s*:%s*([%d%.%-]+)')
	if sp then R.speed = tonumber(sp) or R.speed end
end

function R.set_speed(v)
	R.speed = tonumber(v) or R.speed
	if R.speed > 360 then R.speed = 360 end
	if R.speed < -360 then R.speed = -360 end
	R.save()
	-- Nudging the slider used to be the only way to revive a stopped driver.
	-- Now the self-heal in step_impl does that, but start here too so the
	-- slider feels immediate even before the next tick.
	if R.enabled and not R.running then R.start() end
end

function R.status()
	return string.format(
		"enabled=%s running=%s angle=%s speed=%.3f deg/s writes=%d errors=%d%s",
		tostring(R.enabled), tostring(R.running),
		R.angle and string.format("%.2f", R.angle) or "n/a",
		R.speed, R.writes, R.errors,
		R.disabled_by_error and " AUTO-DISABLED" or "")
end

-- ---------------------------------------------------------------------------
-- per frame
-- ---------------------------------------------------------------------------

-- One smooth step. The angle advances by speed * dt every frame and wraps at 360,
-- so motion is identical at 30fps, 60fps or 144fps - only the number of writes
-- changes, never the rate. There is no mode switch and no discontinuity: the
-- only place the angle can jump is a level load, and that is intentional.
local function step_impl(t, dt)
	if not R.enabled then return end

	-- SELF-HEAL. The driver used to stop for good at three separate points:
	-- LevelLoaded cleared R.running, losing the viewport cleared it, and
	-- nothing ever set it back. The only way to recover was to touch the menu,
	-- which is what "it stops until I move the slider" was. If we are enabled
	-- but not running, try to start again rather than waiting to be told.
	if not R.running then
		R.start()
		if not R.running then return end
	end

	if type(dt) ~= "number" then return end
	-- A lag spike hands us a huge dt, which would teleport the sky. Clamping
	-- trades a brief slowdown for no visible jump, which is the right call for
	-- something meant to be smooth.
	if dt > 0.1 then dt = 0.1 end
	if dt < 0 then dt = 0 end

	local speed = tonumber(R.speed) or 0
	if speed == 0 then return end

	R.angle = (R.angle + speed * dt) % 360
	if R.angle < 0 then R.angle = R.angle + 360 end

	local h = handler()
	if not h then
		-- Do not clear R.running here. The viewport is briefly absent during
		-- loads; stopping permanently on a transient miss is what this fix is
		-- about. The self-heal above will pick it back up.
		return
	end

	local ok, err = pcall(function() return h:editor_set_value(R.KEY, R.angle) end)
	if not ok then
		R.errors = R.errors + 1
		if R.errors == 1 or R.errors % 120 == 0 then
			note("editor_set_value error #" .. tostring(R.errors) .. ": " .. tostring(err))
		end
		-- Stop hammering a call that just faulted. One failure is noise; a
		-- hundred is a crash loop.
		if R.errors >= 10 then
			R.running = false
			R.disabled_by_error = true
			note("disabled after " .. tostring(R.errors) .. " errors; re-enable from the menu")
		end
		return
	end

	R.writes = R.writes + 1
end

function R.step(t, dt)
	local ok, err = pcall(step_impl, t, dt)
	if not ok then
		R.errors = R.errors + 1
		if R.errors <= 3 or R.errors % 300 == 0 then
			note("update error #" .. tostring(R.errors) .. ": " .. tostring(err))
		end
	end
	return ok
end

Hooks:Add("GameSetupUpdate", "skybox_animated_sky_rotation", function(t, dt)
	R.step(t, dt)
end)

-- A level load rebuilds the environment, so the captured angle is stale. Clear
-- the volatile state and let step_impl's self-heal restart us - the viewport
-- may not exist yet at this point, so starting here would just fail again.
Hooks:Add("LevelLoaded", "skybox_animated_sky_rotation_level", function()
	R.angle = nil
	R.original = nil
	R.writes = 0
	R.errors = 0
	R.running = false
	R.disabled_by_error = false
end)

R.load()
if R.enabled then
	-- Do not start here either; no viewport exists yet during a load. The first
	-- GameSetupUpdate tick will pick it up.
	note(string.format("restored settings: enabled, speed %.2f deg/s", R.speed))
else
	note(string.format("loaded - idle. speed %.2f deg/s. Enable from Options > skybox > Sky Animation", R.speed))
end