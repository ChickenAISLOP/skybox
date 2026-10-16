-- ============================================================================
-- shadow_control.lua  -  wash out the sun's black shadow
-- ============================================================================
--
-- CRASH HISTORY - READ FIRST
-- Seven crashes in this project, all mine. This file caused number 7, at
-- shadow_control.lua:271, when it drove set_post_processor_effect from a
-- heartbeat during MenuManagerOnOpenMenu. pcall cannot catch an access
-- violation, so the guard did nothing. Nothing in this file calls
-- set_post_processor_effect from a hook or a timer any more.
--
-- WHAT ACTUALLY WORKS, AND WHAT DOES NOT
-- The shadow is produced and consumed by two different passes:
--
--   shadow_processor  ->  renders the shadow depth map
--   deferred          ->  consumes it during lighting
--
-- Driving the producer off therefore does not delete the shadow, it freezes it.
-- Both of those were measured on 2026-10-16 and both leave the same artifact -
-- a stale shadow shape sitting on the ground that no longer matches the
-- geometry:
--
--   blank  shadow_processor -> empty                  "it stop moving shadow"
--   hide   shadow_processor:set_visibility(false)     "glitch shadow"
--
-- They are kept only for reference. Neither is a fix.
--
-- THE FIX
-- Flood the ambient term instead. Ambient is added uniformly to lit and
-- shadowed surfaces alike, so raising it washes the black out of the shadows
-- without touching the shadow map, the lighting pass, or any post-process
-- effect. SSAO, bloom, AA, DOF and colour grading are all left running.
--
-- This is the mechanism Fullbright Diesel 3.0 uses, and every symbol it relies
-- on was verified present in this build before being used:
--
--   Color("fff")                                       167 installed mods use it
--   CoreEnvironmentFeeder.PostAmbientColorFeeder        exact match in
--                                                        coreenvironmentfeeder.lua
--   managers.viewport:create_global_environment_modifier   coreviewportmanager.lua
--   managers.viewport:destroy_global_environment_modifier  coreviewportmanager.lua
--
-- IT IS FULLY REVERSIBLE
-- create/destroy_global_environment_modifier is a paired API and the destroy
-- call is the documented inverse. That is the difference between this and every
-- previous attempt: set_post_processor_effect DESTROYS the pass, after which the
-- name no longer resolves and there is no value to write back. Here the post
-- processor is never touched at all, so turning the toggle off genuinely
-- restores the level.
--
-- A mode "albedo" would swap deferred to albedo_visualization for true flat
-- fullbright, but albedo_visualization is defined in Fullbright's own sky.xml,
-- not in the base game, so it does not exist unless that mod is installed.
-- Not shipped.
--
-- APPLY POLICY
-- Applied on explicit player action, and re-applied once on LevelLoaded after a
-- short delay, because a level load rebuilds the environment and would
-- otherwise drop the modifier. No per-frame heartbeat: the crash came from one.
-- ============================================================================

_G.shadow_control = _G.shadow_control or {}
local R = _G.shadow_control

if R._loaded then return end
R._loaded = true

local AMBIENT_KEY = "PostAmbientColorFeeder"

-- modes ---------------------------------------------------------------------

R.MODES = {
	-- flood ambient. The fix. Shadows wash out, lighting and every
	-- post-process effect stay exactly as the level set them.
	ambient = { kind = "ambient" },
	-- kept for reference only; both leave a stale frozen shadow
	blank   = { kind = "impl", name = "shadow_processor", value = Idstring("empty") },
	hide    = { kind = "vis",  name = "shadow_processor", value = false },
}

R.MODE_ORDER = { "ambient", "blank", "hide" }

R.enabled = R.enabled == true
R.mode    = R.mode or "ambient"
R.scale   = tonumber(R.scale) or 1.5

R.applied   = false
R.errors    = 0
R.viewports = 0
R.probed    = false

-- logging -------------------------------------------------------------------

local function out(s)
	if log then log("[shadowctl] " .. s) end
end

local function write_log(lines)
	for _, l in ipairs(lines) do out(l) end
	local f = io.open(SavePath .. "shadow_control.log", "a")
	if f then
		for _, l in ipairs(lines) do f:write(os.date("[%H:%M:%S] ") .. l .. "\n") end
		f:close()
	end
end

local function note(s)
	out(s)
	local f = io.open(SavePath .. "shadow_control.log", "a")
	if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n"); f:close() end
end

-- feeders -------------------------------------------------------------------

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

-- apply ---------------------------------------------------------------------

local function clear_impl()
	local m = viewport_manager()
	local key = ambient_key()
	if not m or not key then
		note("clear: " .. (not m and "no viewport manager" or "no " .. AMBIENT_KEY))
		return false
	end
	local ok, err = pcall(function() m:destroy_global_environment_modifier(key) end)
	R.applied = false
	if not ok then
		R.errors = R.errors + 1
		note("destroy error #" .. tostring(R.errors) .. ": " .. tostring(err))
		return false
	end
	return true
end

local function apply_impl()
	local mode = R.MODES[R.mode]
	if not mode then return false end

	if mode.kind == "ambient" then
		local m = viewport_manager()
		local key = ambient_key()
		if not m then
			note("apply refused: no create/destroy_global_environment_modifier")
			return false
		end
		if not key then
			note("apply refused: CoreEnvironmentFeeder." .. AMBIENT_KEY .. " not found")
			return false
		end

		local scale = tonumber(R.scale) or 1.5

		-- Clear first so repeated presses do not stack modifiers.
		pcall(function() m:destroy_global_environment_modifier(key) end)

		local ok, err = pcall(function()
			m:create_global_environment_modifier(key, true, function()
				return Color("fff") * scale
			end)
		end)
		R.applied = ok
		if not ok then
			R.errors = R.errors + 1
			note("create error #" .. tostring(R.errors) .. ": " .. tostring(err))
			return false
		end
		note(string.format("ambient flooded: %s = white x %.2f", AMBIENT_KEY, scale))
		return true
	end

	-- blank / hide: reference only, they freeze the shadow rather than remove it
	local list
	local okl, l = pcall(function() return managers.viewport:viewports() end)
	if okl and type(l) == "table" then list = l end
	if not list then
		note("apply refused: no viewport")
		return false
	end

	local n, bad = 0, 0
	for _, entry in ipairs(list) do
		local g, vp = pcall(function() return entry:vp() end)
		if g and vp then
			local ok = pcall(function()
				if mode.kind == "impl" then
					vp:set_post_processor_effect("World", Idstring(mode.name), mode.value)
				else
					local p = vp:get_post_processor_effect("World", Idstring(mode.name))
					if p then p:set_visibility(mode.value) end
				end
			end)
			if ok then n = n + 1 else bad = bad + 1 end
		end
	end
	R.applied = n > 0
	note(string.format("mode %s: %d ok / %d failed (leaves a stale frozen shadow)",
		R.mode, n, bad))
	return n > 0
end

-- control -------------------------------------------------------------------

function R.enable()
	R.enabled = true
	R.applied = apply_impl()
	R.save()
end

function R.disable()
	R.enabled = false
	-- The ambient modifier is destroyed here, which is a real restore. The
	-- blank/hide modes deliberately write nothing back: set_post_processor_effect
	-- destroys the pass, so there is no inverse value to write. A restart is the
	-- only restore for those two.
	clear_impl()
	R.save()
	note("disabled")
end

function R.set_enabled(on)
	if on == true then R.enable() else R.disable() end
end

function R.set_mode(mode)
	if not R.MODES[mode] then return end
	if R.mode == mode then return end
	R.mode = mode
	if R.enabled then apply_impl() end
	R.save()
end

function R.set_scale(v)
	local s = tonumber(v)
	if s then
		R.scale = s
		if R.scale < 0 then R.scale = 0 end
		if R.scale > 5 then R.scale = 5 end
	end
	R.save()
	-- The modifier captures scale in its closure, so a change needs a rebuild.
	if R.enabled and R.mode == "ambient" then apply_impl() end
end

-- A level load rebuilds the environment, which drops the modifier. Re-apply once
-- after a short delay so the new environment exists first. DelayedCalls:Add
-- takes SECONDS. This is the only automatic path, and it calls no rendering
-- function.
Hooks:Add("LevelLoaded", "skybox_animated_shadow_control_level", function()
	R.applied = false
	if R.enabled and R.mode == "ambient" then
		pcall(function()
			DelayedCalls:Add("skybox_shadow_reapply", 2, function()
				if R.enabled and R.mode == "ambient" and not R.applied then
					apply_impl()
				end
			end)
		end)
	end
end)

-- persistence ---------------------------------------------------------------

R.SETTINGS_FILE = "shadow_control_settings.json"

function R.save()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "w")
	if not f then return end
	f:write(string.format('{"enabled":%s,"mode":"%s","scale":%.3f}\n',
		R.enabled and "true" or "false", R.mode, R.scale))
	f:close()
end

function R.load()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "r")
	if not f then return end
	local body = f:read("*all")
	f:close()
	if not body then return end
	if body:match('"enabled"%s*:%s*true') then R.enabled = true end
	local m = body:match('"mode"%s*:%s*"([%w_]+)"')
	if m and R.MODES[m] then R.mode = m end
	local s = body:match('"scale"%s*:%s*([%d%.%-]+)')
	if s then R.scale = tonumber(s) or R.scale end
end

function R.status()
	return string.format("enabled=%s mode=%s scale=%.2f applied=%s errors=%d",
		tostring(R.enabled), R.mode, R.scale, tostring(R.applied), R.errors)
end

R.load()
note(R.enabled
	and ("loaded - enabled, mode " .. R.mode .. " (not applied yet; flip the toggle)")
	or  ("loaded - idle, mode " .. R.mode))