-- ============================================================================
-- shadow_freeze.lua  -  keep the sun's shadow still while the dome rotates
-- ============================================================================
--
-- WHY THIS EXISTS
-- SkyRotationFeeder:apply does not rotate the environment. It rotates one
-- object inside the underlay:
--
--   UnderlayPathFeeder.ref_cam_obj:set_rotation(temp_rotation)
--   ref_cam_obj = Underlay:get_object(Idstring("rp_skydome"))
--
-- rp_skydome is the sky dome root, and d_sun is a child of it. The directional
-- light that casts the global shadow is linked to d_sun:
--
--   Global._global_light = World:create_light("directional|specular")
--   Global._global_light:link(Underlay:get_object(Idstring("d_sun")))
--   World:set_global_shadow_caster(Global._global_light)
--
-- So rotating the dome rotates the light, and the shadow crawls with it. The
-- light is a normal object, though, and Light has world-space rotation:
--
--   Light:rotation()      -> world rotation
--   Light:set_rotation(r) -> set world rotation
--   (Extra Heist Info/pd2_docs/classes/light.lua)
--
-- Capturing the light's world rotation once and re-applying it every frame
-- freezes the shadow without touching the visible sky. The sun painted into
-- the cubemap still moves with the dome; only the shadow stays put.
--
-- The light is deleted and recreated by UnderlayPathFeeder:apply on every
-- underlay load, so the capture is repeated whenever the object changes.
-- ============================================================================

_G.shadow_freeze = _G.shadow_freeze or {}
local F = _G.shadow_freeze

if F._loaded then return end
F._loaded = true

-- On by default: if the sky rotates, a shadow that crawls is the bug.
F.enabled = F.enabled ~= false
F.light   = nil
F.fixed   = nil
F.pins    = 0
F.errors  = 0
F.disabled_by_error = false

local function out(s)
	if log then log("[shadowfreeze] " .. s) end
end

local function note(s)
	out(s)
	local f = io.open(SavePath .. "shadow_freeze.log", "a")
	if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n"); f:close() end
end

-- CoreCode.alive is the game's own liveness check. If CoreCode is not present
-- in this Lua state, fall back to the non-nil check rather than skipping the
-- feature entirely.
local function alive(obj)
	if not obj then return false end
	if CoreCode and CoreCode.alive then
		local ok, v = pcall(CoreCode.alive, obj)
		if ok then return v == true end
	end
	return true
end

local function current_light()
	if not Global then return nil end
	local ok, l = pcall(function() return Global._global_light end)
	if not ok or not l then return nil end
	if not alive(l) then return nil end
	return l
end

local function copy_rotation(r)
	local ok, v = pcall(function() return Rotation(r:yaw(), r:pitch(), r:roll()) end)
	if ok and v then return v end
	return r
end

-- Capture the shadow direction that is current right now. Called before the
-- first rotation write and again whenever the engine replaces the light.
function F.capture()
	local l = current_light()
	if not l then return false end

	local ok, r = pcall(function() return l:rotation() end)
	if not ok or not r then
		note("capture failed: " .. tostring(r))
		return false
	end

	F.light = l
	F.fixed = copy_rotation(r)
	note(string.format("captured shadow direction at yaw %.2f", F.fixed:yaw()))
	return true
end

function F.pin()
	if not F.enabled or F.disabled_by_error then return end

	local l = current_light()
	if not l then return end

	if l ~= F.light or not F.fixed then
		if not F.capture() then return end
		l = F.light
	end

	local ok, err = pcall(function() l:set_rotation(F.fixed) end)
	if ok then
		F.pins = F.pins + 1
		F.errors = 0
		return
	end

	F.errors = F.errors + 1
	if F.errors == 1 or F.errors % 120 == 0 then
		note("set_rotation error #" .. tostring(F.errors) .. ": " .. tostring(err))
	end
	if F.errors >= 10 then
		F.disabled_by_error = true
		note("disabled after " .. tostring(F.errors) .. " errors; re-enable from the menu")
	end
end

function F.set_enabled(on)
	F.enabled = on == true
	F.errors = 0
	F.disabled_by_error = false
	if F.enabled then
		F.capture()
	else
		F.light = nil
		F.fixed = nil
	end
	F.save()
end

function F.status()
	return string.format(
		"enabled=%s light=%s captured=%s pins=%d errors=%d%s",
		tostring(F.enabled),
		F.light and "yes" or "no",
		F.fixed and "yes" or "no",
		F.pins, F.errors,
		F.disabled_by_error and " AUTO-DISABLED" or "")
end

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

F.SETTINGS_FILE = "shadow_freeze_settings.json"

function F.save()
	local f = io.open(SavePath .. F.SETTINGS_FILE, "w")
	if not f then return end
	f:write(string.format('{"enabled":%s}\n', F.enabled and "true" or "false"))
	f:close()
end

function F.load()
	local f = io.open(SavePath .. F.SETTINGS_FILE, "r")
	if not f then return end
	local body = f:read("*all")
	f:close()
	if not body then return end
	if body:match('"enabled"%s*:%s*false') then
		F.enabled = false
	elseif body:match('"enabled"%s*:%s*true') then
		F.enabled = true
	end
end

F.load()

-- ---------------------------------------------------------------------------
-- per frame
-- ---------------------------------------------------------------------------
--
-- This hook is registered after sky_rotation.lua's hook (mod.txt lists this
-- file second), so the sky has already been moved by the time the light is put
-- back. That ordering is the whole trick.

Hooks:Add("GameSetupUpdate", "skybox_animated_shadow_freeze", function(t, dt)
	if not F.enabled or F.disabled_by_error then return end
	local rot = _G.sky_rotation
	if not (rot and rot.running) then return end

	local ok, err = pcall(F.pin)
	if not ok then
		F.errors = F.errors + 1
		if F.errors <= 3 or F.errors % 300 == 0 then
			note("update error #" .. tostring(F.errors) .. ": " .. tostring(err))
		end
	end
end)

-- A level load deletes and recreates the global light. Drop the captured
-- object so the next frame captures the new one, and recapture from the new
-- level's rest angle.
Hooks:Add("LevelLoaded", "skybox_animated_shadow_freeze_level", function()
	F.light = nil
	F.fixed = nil
	F.pins = 0
	F.errors = 0
	F.disabled_by_error = false
end)

note(string.format("loaded - toggle=%s", F.enabled and "on" or "off"))
