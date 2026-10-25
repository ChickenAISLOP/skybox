-- Replaces the game's Underlay sky material texture, using the same game API
-- used by BeardLib's SkyTexturePathFeeder. No sky-dome unit lookup is needed.
--
-- Runtime responsibilities are deliberately narrow: apply the selected texture
-- and expose a diagnostics dump. Sky rotation lives in sky_rotation.lua; holding
-- the sun's shadow still lives in shadow_freeze.lua.
_G.skybox_animated_env = _G.skybox_animated_env or {}
local Env = _G.skybox_animated_env

if Env._loaded then return end
Env._loaded = true

Env.applied_texture = nil
Env.applied_level = nil
Env.last_log_state = {}

local TEXTURE_LOAD_RETRY_INTERVAL = 1.0

-- Count native calls so a framerate problem can be attributed instead of
-- guessed at. Reported by the diagnostics dump, and read on the first line of
-- update(), so these must exist before anything else.
Env.work_count = Env.work_count or 0
Env.work_per_sec = Env.work_per_sec or 0
Env.work_window_start = Env.work_window_start
Env.work_window_count = Env.work_window_count or 0

function Env.count_work()
	Env.work_count = (Env.work_count or 0) + 1
end

-- os.clock() reports CPU time, which is near zero at startup and diverges from
-- wall time whenever the process idles. Timing follows game time instead, so
-- update() accumulates its own monotonic clock from dt.
local function now_seconds()
	return Env.now or 0
end

local function work_per_second()
	local now = now_seconds()
	if Env.work_window_start == nil then
		Env.work_window_start = now
		Env.work_window_count = Env.work_count or 0
		return 0
	end
	local elapsed = now - Env.work_window_start
	if elapsed < 1 then return 0 end
	local total = Env.work_count or 0
	local previous = Env.work_window_count or 0
	Env.work_per_sec = (total - previous) / elapsed
	Env.work_window_count = total
	Env.work_window_start = now
	return Env.work_per_sec
end

local function sa_log(key, message, force)
	local settings = _G.skybox_animated_settings and _G.skybox_animated_settings.settings
	if not force and not (settings and settings.developer_logs) then return end
	if not force and Env.last_log_state[key] == message then return end
	Env.last_log_state[key] = message
	local line = "[SA] " .. tostring(message)
	if log then log(line) end
	local f = io.open(SavePath .. "skybox_animated.log", "a")
	if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. line .. "\n"); f:close() end
end

local IDS_TEXTURE = Idstring("texture")
local IDS_DIFFUSE = Idstring("diffuse_texture")
local IDS_NORMAL = Idstring("normal")

local function selected_skybox(SA, settings, heist)
	local id
	if settings.global_enabled then
		id = settings.default_skybox
	else
		local cfg = SA:get_current_heist_config(heist)
		if not cfg or cfg.enabled == false then return nil end
		id = cfg.skybox
	end
	local L = _G.skybox_animated_loader
	if L and L.get then
		local found = L.get(id)
		if found then return found end
	end
	for _, skybox in ipairs((L and L.skyboxes()) or {}) do
		if skybox.id == id then return skybox end
	end
	return nil
end

local function apply_texture(skybox)
	if not skybox then sa_log("no_sky", "apply skipped: no skybox selected"); return false end
	if not skybox.base then
		sa_log("no_base", "apply skipped: selected skybox has no registered base texture: " .. tostring(skybox.id))
		return false
	end
	if not (Underlay and type(Underlay.loaded) == "function" and Underlay:loaded()) then
		sa_log("underlay_unloaded", "apply waiting: Underlay is not loaded")
		return false
	end
	local material = Underlay:material(Idstring("sky"))
	if not material then sa_log("no_material", "apply waiting: Underlay material 'sky' is missing"); return false end

	local dyn = managers and managers.dyn_resource
	local package = DynamicResourceManager and DynamicResourceManager.DYN_RESOURCES_PACKAGE
	local texture_ids = Idstring(skybox.base)
	if not dyn then sa_log("no_dyn", "apply failed: dynamic resource manager is unavailable"); return false end
	if not package then sa_log("no_package", "apply failed: dynamic resource package is unavailable"); return false end
	if not dyn:is_resource_ready(IDS_TEXTURE, texture_ids, package) then
		-- apply_texture is re-entered on every frame until it succeeds, so this
		-- retry must be rate limited. Requesting the same texture every frame
		-- keeps the resource manager busy permanently. The loader loads only this
		-- one texture, only while a heist is running, and only once.
		local now = now_seconds()
		if (now - (Env.last_texture_load_attempt or 0)) >= TEXTURE_LOAD_RETRY_INTERVAL then
			Env.last_texture_load_attempt = now
			Env.texture_load_attempts = (Env.texture_load_attempts or 0) + 1
			sa_log("texture_loading", "loading texture " .. tostring(skybox.base))
			local loader = _G.skybox_animated_loader
			if loader and loader.ensure_texture_ready then
				loader.ensure_texture_ready(skybox.base)
			else
				dyn:load(IDS_TEXTURE, texture_ids, package)
			end
		end
		Env.count_work()
		return false
	end

	local ok, result = pcall(Application.set_material_texture, Application, material, IDS_DIFFUSE, texture_ids, IDS_NORMAL)
	if not ok then
		-- Match BeardLib's call convention exactly (Application:set_material_texture).
		ok, result = pcall(function()
			return Application:set_material_texture(material, IDS_DIFFUSE, texture_ids, IDS_NORMAL)
		end)
	end
	if ok then
		Env.applied_texture = skybox.id
		sa_log("applied", "applied skybox '" .. tostring(skybox.id) .. "' using texture " .. tostring(skybox.base), true)
		return true
	end
	sa_log("setter_failed", "Application:set_material_texture failed for " .. tostring(skybox.id) .. ": " .. tostring(result), true)
	return false
end

local function update_impl(t, dt)
	local SA = _G.skybox_animated
	local S = _G.skybox_animated_settings
	if not (SA and SA.enabled and S and S.settings and S.settings.enabled) then return end

	-- Monotonic game-time clock. A single huge dt (load hitch) must not make
	-- every timer fire at once, so clamp it.
	local step = tonumber(dt) or 0
	if step < 0 then step = 0 end
	if step > 0.25 then step = 0.25 end
	Env.now = (Env.now or 0) + step
	work_per_second()

	if not (Underlay and type(Underlay.loaded) == "function" and Underlay:loaded()) then
		sa_log("underlay_unloaded", "waiting: Underlay is not loaded")
		return
	end
	local heist = Global and Global.level_data and Global.level_data.level_id
	if not heist then sa_log("no_heist", "waiting: Global.level_data.level_id is unavailable"); return end

	local settings = S.settings
	local skybox = selected_skybox(SA, settings, heist)
	if not skybox then
		sa_log("not_selected", "no registered skybox matches selected id '" .. tostring(settings.default_skybox) .. "' (global=" .. tostring(settings.global_enabled) .. ")")
		return
	end
	if settings.developer_logs then
		sa_log("selection", "heist=" .. tostring(heist) .. ", global=" .. tostring(settings.global_enabled) .. ", selected=" .. tostring(skybox.id) .. ", texture=" .. tostring(skybox.base))
	end

	if Env.applied_texture ~= skybox.id or Env.applied_level ~= heist then
		if apply_texture(skybox) then Env.applied_level = heist end
	end
end

-- A Lua error inside a GameSetupUpdate hook terminates PAYDAY 2 outright, so the
-- per-frame body runs guarded. Errors are surfaced in the log, rate limited so a
-- persistent fault cannot itself become a performance problem.
Env.update_errors = 0

function Env.update(t, dt)
	local ok, err = pcall(update_impl, t, dt)
	if not ok then
		Env.update_errors = (Env.update_errors or 0) + 1
		if Env.update_errors <= 3 or Env.update_errors % 300 == 0 then
			local line = "[skybox_animated] update error #" .. tostring(Env.update_errors) .. ": " .. tostring(err)
			if log then log(line) end
			local f = io.open(SavePath .. "skybox_animated.log", "a")
			if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. line .. "\n"); f:close() end
		end
	end
	return ok
end

function Env.dump_diagnostics()
	local SA = _G.skybox_animated
	local S = _G.skybox_animated_settings
	local L = _G.skybox_animated_loader
	local selected = SA and S and S.settings and selected_skybox(SA, S.settings, Global and Global.level_data and Global.level_data.level_id)
	local ids = {}
	for _, skybox in ipairs((L and L.skyboxes()) or {}) do
		ids[#ids + 1] = tostring(skybox.id) .. "=" .. tostring(skybox.base)
	end
	local rows = {
		"diagnostic report",
		"mod_enabled=" .. tostring(SA and SA.enabled),
		"global_enabled=" .. tostring(S and S.settings and S.settings.global_enabled),
		"current_heist=" .. tostring(Global and Global.level_data and Global.level_data.level_id),
		"selected_skybox=" .. tostring(selected and selected.id),
		"selected_texture=" .. tostring(selected and selected.base),
		"underlay_loaded=" .. tostring(Underlay and type(Underlay.loaded) == "function" and Underlay:loaded()),
		"underlay_sky_material=" .. tostring(Underlay and type(Underlay.loaded) == "function" and Underlay:loaded() and Underlay:material(Idstring("sky")) ~= nil),
		"texture_count=" .. tostring(L and #L.skyboxes() or 0),
		"registered_skyboxes=" .. table.concat(ids, "; "),
		"applied_texture=" .. tostring(Env.applied_texture),
		"native_calls_per_second=" .. ("%.1f"):format(Env.work_per_sec or 0),
		"texture_load_attempts=" .. tostring(Env.texture_load_attempts or 0),
		"update_errors=" .. tostring(Env.update_errors or 0),
		"dyn_resource_manager=" .. tostring(managers and managers.dyn_resource ~= nil),
	}
	for _, row in ipairs(rows) do sa_log("diagnostic_" .. row, row, true) end
	return table.concat(rows, "\n")
end

Hooks:Add("GameSetupUpdate", "skybox_animated_env_update", function(t, dt)
	Env.update(t, dt)
end)

Hooks:Add("LevelLoaded", "skybox_animated_level_loaded", function()
	Env.applied_texture = nil
	Env.applied_level = nil
	Env.last_texture_load_attempt = nil
	Env.work_count = 0
	Env.work_window_start = nil
	Env.work_window_count = 0
	Env.now = 0
end)

log("[skybox_animated] Underlay sky texture override loaded")