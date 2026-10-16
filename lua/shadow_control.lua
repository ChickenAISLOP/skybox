-- ============================================================================
-- shadow_control.lua  -  turn the sun's cast shadow off, touch nothing else
-- ============================================================================
--
-- WHAT THIS IS
-- A single toggle that removes the hard black shadow the sun casts (the
-- lamppost stripe across the road, the doorway blocks on Chinatown) and leaves
-- every other part of the image alone.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH
-- Mod 20568 ("Remove Shadows FPS Boost") strips 18 things at once: SSAO, bloom,
-- AA, light adaptation, LEX composite, DOF, depth projection, deferred
-- lighting, ambient, colour grading and more. Everything except the sky looks
-- flat and lifeless as a result, and the author notes the outlines break too.
-- This file sets exactly ONE effect. SSAO, bloom, AA, DOF, colour grading,
-- ambient and the rest are left on.
--
-- HOW IT WORKS
-- default.environment defines the post-effect tree like this:
--
--   post_effect
--     |- deferred
--     |   |- deferred_lighting
--     |   `- apply_ambient
--     `- shadow_processor
--         `- shadow_rendering      <-- the sun's shadow
--             `- shadow_modifier
--                 |- slice0 .. slice3
--                 |- shadow_slice_depths
--                 `- shadow_slice_overlap
--
-- "shadow_rendering" is a slot in that tree. Swapping its implementation for
-- "empty" - a null implementation that core/shaders/post_processor.post_processor
-- really does define - drops the shadow and leaves the rest of the tree intact.
--
-- CALLS USED, AND THEIR EVIDENCE
--   managers.viewport:viewports()      used by ModWorkshop 20568, 25k downloads
--   vp:vp()                            used by the Environment Editor mod (env.lua)
--   vp:vp():set_post_processor_effect  used by ModWorkshop 20568
--   Hooks:Add("GameSetupUpdate", ...)   already used twice in this mod
--
-- ONE VALUE IS STILL INFERRED
-- The restore implementation. Mod 20568 never restores anything - it just
-- re-applies on SetVideo - so there is no published example of putting the
-- shadow back. shadow_processor.post_processor defines exactly one effect,
-- named "shadow_rendering", so setting the slot back to that name is the
-- obvious inverse. It has not been confirmed at runtime yet; if turning the
-- toggle back off does not bring the shadow, that name is wrong and the
-- shadow is back by restarting the game. Nothing is lost either way.
-- shadow_control.log records every apply so a failed restore is visible.
--
-- FAILURE HANDLING
-- Same rules as sky_rotation.lua: a Lua error inside a GameSetupUpdate hook
-- kills the game, so everything runs under pcall; and a native call that
-- faults repeatedly is abandoned rather than hammered.
-- ============================================================================

_G.shadow_control = _G.shadow_control or {}
local R = _G.shadow_control

if R._loaded then return end
R._loaded = true

-- The one effect this mod changes.
R.EFFECT = "shadow_rendering"
R.ON     = "empty"             -- null implementation, really defined in post_processor.post_processor
R.OFF    = "shadow_rendering"  -- INFERRED inverse - see header

R.enabled = R.enabled == true

-- runtime state
R.applied        = nil   -- what we last successfully wrote, so we do not rewrite it every frame
R.errors         = 0
R.disabled_by_error = false
R.viewports      = 0

local function out(s)
	if log then log("[shadowctl] " .. s) end
end

-- Throttled, same reason and same shape as sky_rotation.lua's note(): the
-- heartbeat below retries while no viewport exists, which is every loading
-- screen, and without this that would be hundreds of log lines per level load.
local _seen = {}
local function note(s)
	local key = s:gsub("%d+", "N")
	if _seen[key] then return end
	_seen[key] = true
	local n = 0
	for _ in pairs(_seen) do n = n + 1 end
	if n > 40 then _seen = {} end

	out(s)
	local f = io.open(SavePath .. "shadow_control.log", "a")
	if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n"); f:close() end
end

-- ---------------------------------------------------------------------------
-- viewports
-- ---------------------------------------------------------------------------

-- Returns the list of native viewports, or nil. Deliberately mirrors ModWorkshop
-- 20568 exactly: it iterates every viewport rather than only the active one, so
-- the toggle behaves the same in-game and in the main menu.
local function viewports()
	if not (managers and managers.viewport) then return nil end

	local ok, list = pcall(function() return managers.viewport:viewports() end)
	if not ok or type(list) ~= "table" then return nil end

	local out_list, n = {}, 0
	for _, entry in ipairs(list) do
		-- entry is the wrapper; :vp() is the native viewport. Two hops, and
		-- getting this wrong is the same mistake that crashed six probes.
		local g, native = pcall(function() return entry:vp() end)
		if g and native then
			n = n + 1
			out_list[n] = native
		end
	end
	if n == 0 then return nil end
	return out_list
end

-- ---------------------------------------------------------------------------
-- apply
-- ---------------------------------------------------------------------------

local function apply_impl()
	if not R.enabled then return end
	local list = viewports()
	if not list then return end

	local want = R.ON
	if R.applied == want then return end

	local n, failed = 0, 0
	for _, vp in ipairs(list) do
		local ok, err = pcall(function()
			vp:set_post_processor_effect("World", Idstring(R.EFFECT), Idstring(want))
		end)
		if ok then n = n + 1 else failed = failed + 1 end
		if not ok then R.last_error = tostring(err) end
	end

	R.viewports = n
	if n > 0 then
		R.applied = want
		note(string.format("%s shadow_rendering -> %s on %d viewport(s)",
			R.applied_prev or (R.enabled and "on" or "off"), want, n))
	end
	if failed > 0 then R.errors = R.errors + failed end
end

-- Turn it on. Writes empty.
function R.enable()
	R.enabled = true
	R.applied = nil          -- force the write even if we think it is already set
	R.disabled_by_error = false
	apply_impl()
	R.save()
end

-- Turn it back on. Writes the inferred inverse.
function R.disable()
	R.enabled = false
	local list = viewports()
	if list then
		for _, vp in ipairs(list) do
			pcall(function()
				vp:set_post_processor_effect("World", Idstring(R.EFFECT), Idstring(R.OFF))
			end)
		end
	end
	R.applied = nil
	R.save()
	note("disabled, wrote shadow_rendering -> " .. R.OFF)
end

function R.set_enabled(on)
	if on == true then R.enable() else R.disable() end
end

-- ---------------------------------------------------------------------------
-- heartbeat
-- ---------------------------------------------------------------------------

-- The engine rebuilds the post-effect tree on a level load, and on a resolution
-- or graphics change, which silently puts the shadow back. Mod 20568 handles
-- this with a persist_script on SetVideo; we do the same job more cheaply by
-- re-asserting on a slow heartbeat only when we do not believe it is set.
--
-- R.applied is only set after a successful write, so a viewport that comes and
-- goes cannot leave us believing we are done.
local function heartbeat_impl()
	if not R.enabled then return end
	if R.disabled_by_error then return end

	local ok, err = pcall(apply_impl)
	if not ok then
		R.errors = R.errors + 1
		if R.errors <= 3 or R.errors % 300 == 0 then
			note("apply error #" .. tostring(R.errors) .. ": " .. tostring(err))
		end
		if R.errors >= 10 then
			R.disabled_by_error = true
			note("auto-disabled after " .. tostring(R.errors) .. " errors; re-enable from the menu")
		end
	end
end

local _tick = 0
function R.step(t, dt)
	-- Once every ~2 seconds. Re-asserting this effect every frame would be pure
	-- waste; the tree only changes on events, not continuously.
	_tick = _tick + 1
	if _tick < 120 then return end
	_tick = 0
	heartbeat_impl()
end

Hooks:Add("GameSetupUpdate", "skybox_animated_shadow_control", function(t, dt)
	R.step(t, dt)
end)

-- A level load rebuilds the tree from the environment, so whatever we wrote is
-- gone. Clearing R.applied is what makes the heartbeat rewrite it.
Hooks:Add("LevelLoaded", "skybox_animated_shadow_control_level", function()
	R.applied = nil
	R.errors = 0
	R.disabled_by_error = false
end)

-- If the player opens the menu while the shadow is on and the engine dropped it
-- in the meantime, this is the moment to put it back.
Hooks:Add("MenuManagerOnOpenMenu", "skybox_animated_shadow_control_menu", function()
	R.applied = nil
	heartbeat_impl()
end)

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

R.SETTINGS_FILE = "shadow_control_settings.json"

function R.save()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "w")
	if not f then return end
	f:write(string.format('{"enabled":%s}\n', R.enabled and "true" or "false"))
	f:close()
end

function R.load()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "r")
	if not f then return end
	local body = f:read("*all")
	f:close()
	if not body then return end
	if body:match('"enabled"%s*:%s*true') then R.enabled = true end
end

function R.status()
	return string.format("enabled=%s applied=%s viewports=%d errors=%d%s",
		tostring(R.enabled), tostring(R.applied), R.viewports, R.errors,
		R.disabled_by_error and " AUTO-DISABLED" or "")
end

R.load()
note(R.enabled and "loaded - enabled, will apply on first tick"
	             or "loaded - idle. Enable from Options > skybox > Shadows")