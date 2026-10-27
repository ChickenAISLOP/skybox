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
-- So rotating the dome rotates the light, and the shadow crawls with it.
-- Light:rotation() is not reliable here: on a linked light it reports the
-- local rotation (the feeder sets it to zero). The live log recorded local yaw
-- 0.00 against parent yaw 63.89. Work from the parent link instead:
--
--   world = parent:rotation() * light:local_rotation()
--   local = parent:rotation():inverse() * captured_world
--
-- Re-applying that local rotation every frame holds the light's world
-- direction at the angle it had when the dome started turning, so the shadow
-- stays put while the visible sun moves. The parent's world rotation is what
-- actually changes; the light's local rotation is the lever.
--
-- The light is deleted and recreated by UnderlayPathFeeder:apply on every
-- underlay load, so the capture is repeated whenever the object changes.
--
-- This module is always on. It has no menu tab or toggle: while the sky
-- rotation driver is running, the shadow direction is held automatically.
-- ============================================================================

_G.shadow_freeze = _G.shadow_freeze or {}
local F = _G.shadow_freeze

if F._loaded then return end
F._loaded = true

F.enabled = true
F.light   = nil
F.parent  = nil
F.fixed   = nil
F.original_local = nil
F.has_parent_api = false
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

	local parent = nil
	local okp, p = pcall(function() return l:parent() end)
	if okp and p then parent = p end
	F.has_parent_api = okp

	local local_rot = nil
	local okl, lr = pcall(function() return l:local_rotation() end)
	if okl and lr then local_rot = lr end

	local world = nil
	local parent_rot = nil
	if parent then
		local okr, pr = pcall(function() return parent:rotation() end)
		if okr and pr then
			parent_rot = pr
			if local_rot then
				local okm, m = pcall(function() return pr * local_rot end)
				world = okm and m or pr
			else
				world = pr
			end
		end
	end
	if not world then
		local okr, r = pcall(function() return l:rotation() end)
		if okr and r then world = r end
	end
	if not world then
		note("capture failed: no usable rotation")
		return false
	end

	F.light = l
	F.parent = parent
	F.original_local = local_rot and copy_rotation(local_rot) or nil
	F.fixed = copy_rotation(world)

	if parent then
		note(string.format(
			"captured shadow direction at yaw %.2f (parent yaw %.2f, local yaw %.2f)",
			F.fixed:yaw(),
			parent_rot and parent_rot:yaw() or 0,
			local_rot and local_rot:yaw() or 0))
	else
		note(string.format("captured shadow direction at yaw %.2f (no parent)", F.fixed:yaw()))
	end
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

	local ok, err
	if F.parent then
		-- Keep the world direction, not the local one. The parent is the dome
		-- child that is actually turning; counter-rotate the light's local
		-- rotation so parent * local stays at the captured world angle.
		ok, err = pcall(function()
			local pr = F.parent:rotation()
			l:set_local_rotation(pr:inverse() * F.fixed)
		end)
	elseif F.has_parent_api then
		-- The engine has parent(), but the light is unlinked. Light:rotation()
		-- can report local space, so forcing it into world space is exactly the
		-- bug that pointed the sun away. Leave the light alone.
		return
	else
		-- Unknown light object with no parent() method: old fallback.
		ok, err = pcall(function() l:set_rotation(F.fixed) end)
	end

	if ok then
		F.pins = F.pins + 1
		F.errors = 0
		return
	end

	F.errors = F.errors + 1
	if F.errors == 1 or F.errors % 120 == 0 then
		note("pin error #" .. tostring(F.errors) .. ": " .. tostring(err))
	end
	if F.errors >= 10 then
		F.disabled_by_error = true
		F.restore_light()
		note("disabled after " .. tostring(F.errors) .. " errors; reload the level")
	end
end

-- Put the light's own local rotation back so it follows the dome again when
-- the freeze is off. A level load replaces the light, so there is nothing to
-- restore then.
function F.restore_light()
	local l = F.light
	if l and F.parent and F.original_local and alive(l) then
		pcall(function() l:set_local_rotation(F.original_local) end)
	end
	F.light = nil
	F.parent = nil
	F.fixed = nil
	F.original_local = nil
	F.has_parent_api = false
end

-- Kept as a small diagnostic API. No menu exposes it; the module starts on.
function F.set_enabled(on)
	F.enabled = on == true
	F.errors = 0
	F.disabled_by_error = false
	if F.enabled then
		F.capture()
	else
		F.restore_light()
	end
end

function F.status()
	return string.format(
		"enabled=%s light=%s parent=%s captured=%s pins=%d errors=%d%s",
		tostring(F.enabled),
		F.light and "yes" or "no",
		F.parent and "yes" or "no",
		F.fixed and "yes" or "no",
		F.pins, F.errors,
		F.disabled_by_error and " AUTO-DISABLED" or "")
end

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
	F.parent = nil
	F.fixed = nil
	F.original_local = nil
	F.has_parent_api = false
	F.pins = 0
	F.errors = 0
	F.disabled_by_error = false
end)

note("loaded - always on")
