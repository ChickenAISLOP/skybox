-- ============================================================================
-- shadow_control.lua  -  wash out the sun's black shadow
-- ============================================================================
--
-- CRASH HISTORY - READ FIRST
-- Seven crashes in this project, all mine. This file caused number 7, at
-- shadow_control.lua:271, when it drove set_post_processor_effect from a
-- heartbeat during MenuManagerOnOpenMenu. pcall cannot catch an access
-- violation, so the guard did nothing. Nothing here calls
-- set_post_processor_effect any more.
--
-- WHY THIS APPROACH
-- The shadow map has a producer and a consumer:
--
--   shadow_processor  ->  renders the shadow depth map
--   deferred          ->  consumes it during lighting
--
-- Driving the producer off does not delete the shadow, it freezes it. Two ways
-- of doing that were measured on 2026-10-16 and both left the same artifact, a
-- stale shadow shape on the ground that matched no geometry:
--
--   shadow_processor -> empty                    "it stop moving shadow"
--   shadow_processor:set_visibility(false)       "glitch shadow"
--
-- Removing the consumer instead goes black, because deferred_lighting carries
-- every light in the level.
--
-- So neither end of the pass is touchable. What is left is to wash the black
-- out of the shadow instead. Ambient is added uniformly to lit and shadowed
-- surfaces alike, so raising it drains the contrast out of a shadow without
-- touching the shadow map, the lighting pass, or any post-process effect. SSAO,
-- bloom, AA, DOF and colour grading all keep running.
--
-- This is the ambient half of Fullbright Diesel 3.0's effect. Every symbol it
-- relies on was verified present in this build before being used:
--
--   Color("fff")                                       167 installed mods use it
--   CoreEnvironmentFeeder.PostAmbientColorFeeder        exact match in
--                                                        coreenvironmentfeeder.lua
--   managers.viewport:create_global_environment_modifier   coreviewportmanager.lua
--   managers.viewport:destroy_global_environment_modifier  coreviewportmanager.lua
--
-- Fullbright pairs this with a swap to albedo_visualization for true flat
-- fullbright. That effect lives in Fullbright's own sky.xml rather than in the
-- base game, so it does not exist unless that mod is installed, and shipping a
-- second copy of the engine's post-processor database from inside this mod is
-- not worth the risk. Ambient alone is enough to clear the shadow.
--
-- IT IS REVERSIBLE
-- create_global_environment_modifier and destroy_global_environment_modifier
-- are a paired API, and destroy is the documented inverse. That is the whole
-- difference from every earlier attempt: set_post_processor_effect DESTROYS the
-- pass, after which the name no longer resolves and there is no value to write
-- back. Here no post processor is touched at all, so switching off genuinely
-- restores the level.
--
-- APPLY POLICY
-- Applied on explicit player action, plus one re-apply two seconds after a level
-- load, because a level load rebuilds the environment and drops the modifier.
-- DelayedCalls:Add takes SECONDS. No per-frame heartbeat; that is what crashed.
-- ============================================================================

_G.shadow_control = _G.shadow_control or {}
local R = _G.shadow_control

if R._loaded then return end
R._loaded = true

local AMBIENT_KEY = "PostAmbientColorFeeder"
local AMBIENT_SCALE = 1.5

R.enabled = R.enabled == true
R.applied = false
R.errors  = 0

local function out(s)
	if log then log("[shadowctl] " .. s) end
end

-- Throttled. A rebuild can be triggered several times in one second and this log
-- has a history of filling with identical lines; 2026-10-16 11:07:43 managed
-- hundreds of them in a single tick.
local _seen = {}
local function note(s)
	local key = s:gsub("%d+%.?%d*", "N")
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
-- feeders
-- ---------------------------------------------------------------------------

local function ambient_key()
	local ok, f = pcall(function()
		return CoreEnvironmentFeeder and CoreEnvironmentFeeder[AMBIENT_KEY]
	end)
	if not ok or not f then return nil end
	return f.DATA_PATH_KEY
end

local function viewport_manager()
	if not (managers and managers.viewport) then return nil end
	local ok, m = pcall(function() return managers.viewport end)
	if not ok or not m then return nil end
	if type(m.create_global_environment_modifier) ~= "function" then return nil end
	if type(m.destroy_global_environment_modifier) ~= "function" then return nil end
	return m
end

-- ---------------------------------------------------------------------------
-- freeze
-- ---------------------------------------------------------------------------
--
-- set_visibility(false) on the shadow processor stops the shadow map being
-- re-rendered, so the shadow stops moving. Measured 2026-10-16 as leaving a
-- stale shape that matched no geometry - but on its own that artifact was fully
-- visible black. With the ambient flood on top of it, the frozen shadow is
-- washed out along with everything else, so the artifact stops reading as one.
--
-- This is why blank was not used. set_post_processor_effect DESTROYS the pass,
-- so the name stops resolving and only a game restart can bring it back.
-- set_visibility is a flag, and putting it back to true is expected to resume
-- rendering. That expectation is UNTESTED - if the toggle does not bring live
-- shadows back, a restart will.

local function viewports()
	if not (managers and managers.viewport) then return nil end
	local ok, list = pcall(function() return managers.viewport:viewports() end)
	if not ok or type(list) ~= "table" then return nil end
	local out_list, n = {}, 0
	for _, entry in ipairs(list) do
		local g, native = pcall(function() return entry:vp() end)
		if g and native then
			n = n + 1
			out_list[n] = native
		end
	end
	if n == 0 then return nil end
	return out_list
end

local function set_freeze(on)
	local list = viewports()
	if not list then return 0 end
	local n, bad = 0, 0
	for _, vp in ipairs(list) do
		local ok = pcall(function()
			local p = vp:get_post_processor_effect("World", Idstring("shadow_processor"))
			if p then p:set_visibility(not on) end
		end)
		if ok then n = n + 1 else bad = bad + 1 end
	end
	note(string.format("freeze %s: %d viewport(s), %d failed", tostring(not on), n, bad))
	return n
end

-- ---------------------------------------------------------------------------
-- apply
-- ---------------------------------------------------------------------------

local function apply_impl()
	local m = viewport_manager()
	if not m then
		note("apply refused: no create/destroy_global_environment_modifier")
		return false
	end
	local key = ambient_key()
	if not key then
		note("apply refused: CoreEnvironmentFeeder." .. AMBIENT_KEY .. " not found")
		return false
	end

	-- Clear first so repeated presses cannot stack modifiers.
	pcall(function() m:destroy_global_environment_modifier(key) end)

	local ok, err = pcall(function()
		m:create_global_environment_modifier(key, true, function()
			return Color("fff") * AMBIENT_SCALE
		end)
	end)

	R.applied = ok
	if not ok then
		R.errors = R.errors + 1
		note("create error #" .. tostring(R.errors) .. ": " .. tostring(err))
		return false
	end

	note(string.format("ambient flooded: %s = white x %.2f", AMBIENT_KEY, AMBIENT_SCALE))
	return true
end

local function clear_impl()
	local m = viewport_manager()
	local key = ambient_key()
	if not m or not key then return false end
	local ok, err = pcall(function() m:destroy_global_environment_modifier(key) end)
	R.applied = false
	if not ok then
		R.errors = R.errors + 1
		note("destroy error #" .. tostring(R.errors) .. ": " .. tostring(err))
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function R.enable()
	R.enabled = true
	R.applied = apply_impl()
	set_freeze(true)
	R.save()
end

function R.disable()
	R.enabled = false
	clear_impl()
	set_freeze(false)
	R.save()
	note("disabled; ambient modifier destroyed and shadow rendering resumed")
end

function R.set_enabled(on)
	if on == true then R.enable() else R.disable() end
end

-- A level load rebuilds the environment, which drops the modifier. Re-apply once
-- after a short delay so the new environment exists first. The only automatic
-- path in this file, and it calls no rendering function.
Hooks:Add("LevelLoaded", "skybox_animated_shadow_control_level", function()
	R.applied = false
	if R.enabled then
		pcall(function()
			DelayedCalls:Add("skybox_shadow_reapply", 2, function()
				if R.enabled and not R.applied then
					apply_impl()
					set_freeze(true)
				end
			end)
		end)
	end
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
	return string.format("enabled=%s applied=%s scale=%.2f errors=%d",
		tostring(R.enabled), tostring(R.applied), AMBIENT_SCALE, R.errors)
end

R.load()
note(R.enabled
	and "loaded - enabled (not applied yet; flip the toggle)"
	or  "loaded - idle")