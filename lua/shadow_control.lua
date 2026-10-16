-- ============================================================================
-- shadow_control.lua  -  freeze the sun's shadow
-- ============================================================================
--
-- WHY THIS EXISTS
-- The sky dome rotates. The sun rides on the dome, so the godray sweeps around
-- and drags the cast shadow with it, and the shadow crawls across the floor the
-- whole time. Freezing the shadow keeps the sky moving and stops the crawling.
--
-- The goal is a STATIC shadow, not a removed one. An earlier version of this
-- file tried to delete shadows and that was the wrong brief; the player had
-- said "it stop moving shadow" and it had been read as a failure rather than as
-- the answer.
--
-- HOW
-- The shadow map has a producer and a consumer:
--
--   shadow_processor  ->  renders the shadow depth map
--   deferred          ->  consumes it during lighting
--
-- Stopping the producer freezes the map. The consumer keeps sampling it, so the
-- last frame of shadows stays exactly where it was. That is the intent.
--
-- Two routes were measured on 2026-10-16 and both freeze correctly:
--
--   shadow_processor:set_visibility(false)   used here
--   set_post_processor_effect(... "empty")   not used
--
-- The second is NOT used because set_post_processor_effect DESTROYS the pass.
-- After it, the name no longer resolves, there is nothing to write back, and
-- only a game restart brings the shadow back. set_visibility is a flag, so this
-- toggle can put it back to true.
--
-- THAT RESTORE IS UNTESTED. If switching off does not bring live shadows back,
-- a restart will. It is recorded here rather than assumed.
--
-- NO AMBIENT FLOOD
-- An earlier version also raised PostAmbientColorFeeder to wash the shadows
-- out. It worked and was genuinely reversible, but it lightened the entire
-- scene rather than freezing anything, and the player asked for it gone. Removed.
--
-- CRASH HISTORY
-- Seven crashes in this project, all mine. This file caused number 7, at line
-- 271, when it drove set_post_processor_effect from a heartbeat during
-- MenuManagerOnOpenMenu. pcall cannot catch an access violation, so the guard
-- did nothing and the game died. There is no per-frame heartbeat here. The only
-- rendering call is one set_visibility, reached from the menu callbacks and one
-- delayed re-apply after a level load.
-- ============================================================================

_G.shadow_control = _G.shadow_control or {}
local R = _G.shadow_control

if R._loaded then return end
R._loaded = true

local PASS = "World"
local NAME = "shadow_processor"

R.enabled = R.enabled == true
R.applied = false
R.errors  = 0
R.viewports = 0

local function out(s)
	if log then log("[shadowctl] " .. s) end
end

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

local function viewports()
	if not (managers and managers.viewport) then return nil end
	local ok, list = pcall(function() return managers.viewport:viewports() end)
	if not ok or type(list) ~= "table" then return nil end
	local result, n = {}, 0
	for _, entry in ipairs(list) do
		local g, native = pcall(function() return entry:vp() end)
		if g and native then
			n = n + 1
			result[n] = native
		end
	end
	if n == 0 then return nil end
	return result
end

-- freeze = true  hides the shadow processor, so the map stops being redrawn
-- freeze = false puts it back
local function set_freeze(freeze)
	local list = viewports()
	if not list then
		note("freeze refused: no viewport")
		return 0
	end

	local n, bad, missing = 0, 0, 0
	for _, vp in ipairs(list) do
		local found = false
		local ok, err = pcall(function()
			local p = vp:get_post_processor_effect(PASS, Idstring(NAME))
			if p then
				p:set_visibility(not freeze)
				found = true
			end
		end)
		if ok then
			if found then n = n + 1 else missing = missing + 1 end
		else
			bad = bad + 1
			R.errors = R.errors + 1
		end
	end

	R.viewports = #list
	note(string.format("freeze=%s : %d set, %d no shadow_processor, %d failed of %d viewport(s)",
		tostring(freeze), n, missing, bad, #list))
	return n
end

local function apply_impl()
	R.applied = set_freeze(true) > 0
	return R.applied
end

local function clear_impl()
	set_freeze(false)
	R.applied = false
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function R.enable()
	R.enabled = true
	apply_impl()
	R.save()
end

function R.disable()
	R.enabled = false
	clear_impl()
	R.save()
end

function R.set_enabled(on)
	if on == true then R.enable() else R.disable() end
end

-- A level load creates new viewports, which start unfrozen. Re-apply once after
-- a short delay so they exist. DelayedCalls:Add takes SECONDS. This is the only
-- automatic path and it is not per frame.
Hooks:Add("LevelLoaded", "skybox_animated_shadow_control_level", function()
	R.applied = false
	if R.enabled then
		pcall(function()
			DelayedCalls:Add("skybox_shadow_refreeze", 2, function()
				if R.enabled and not R.applied then apply_impl() end
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
	return string.format("frozen=%s on %d viewport(s), errors=%d",
		tostring(R.applied), R.viewports, R.errors)
end

R.load()
note(R.enabled and "loaded - enabled, will freeze on first toggle or level load" or "loaded - idle")