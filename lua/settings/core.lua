_G.skybox_animated_settings = _G.skybox_animated_settings or {}
local S = _G.skybox_animated_settings

if S._core_loaded then
	return
end
S._core_loaded = true

local U = _G.skybox_animated_util
if not U then
	dofile(ModPath .. "lua/util.lua")
	U = _G.skybox_animated_util
end

S._path = ModPath
S._save = SavePath .. "skybox_animated_settings.json"

S.defaults = {
	enabled = true,
	global_enabled = true,
	default_skybox = "sky_1345_clear_sky",
	developer_logs = true,
}

S.settings = {}
for k, v in pairs(S.defaults) do
	S.settings[k] = v
end

S.current_heist = nil
S.current_config = {}

function S:load()
	local data = U.read_json(self._save)
	for k, v in pairs(data) do
		if self.defaults[k] ~= nil and type(v) == type(self.defaults[k]) then
			self.settings[k] = v
		end
	end
	-- The per-heist UI is gone, so the global skybox is always active. Ignore
	-- stale "global_enabled = false" values in old settings files.
	self.settings.global_enabled = true
	local loader = _G.skybox_animated_loader
	local skyboxes = loader and type(loader.skyboxes) == "function" and loader.skyboxes() or {}
	local valid_default = false
	for _, skybox in ipairs(skyboxes) do
		if skybox.id == self.settings.default_skybox then valid_default = true; break end
	end
	if not valid_default and skyboxes[1] then
		self.settings.default_skybox = skyboxes[1].id
	end

	local SA = _G.skybox_animated
	if SA then
		SA.enabled = self.settings.enabled
		SA.global_enabled = self.settings.global_enabled
	end
end

function S:save()
	local f = io.open(self._save, "w+")
	if f then
		f:write(json.encode(self.settings))
		f:close()
	end
end

function S:sync()
	local SA = _G.skybox_animated
	if SA then
		SA.enabled = self.settings.enabled
		SA.global_enabled = true
	end
end

function S:get_heist_list()
	local SA = _G.skybox_animated
	if not SA or not SA.heist_environments then return {} end
	local heists = {}
	for heist, _ in pairs(SA.heist_environments) do
		table.insert(heists, heist)
	end
	table.sort(heists)
	return heists
end

function S:get_heist_display_name(heist)
	local loc = managers.localization
	if loc then
		local job_data = tweak_data.narrative and tweak_data.narrative.jobs and tweak_data.narrative.jobs[heist]
		if job_data and job_data.name_id then
			return loc:text(job_data.name_id)
		end
	end
	return heist
end

function S:load_heist_config(heist)
	self.current_heist = heist
	local SA = _G.skybox_animated
	local config = SA and SA:get_current_heist_config(heist)
	self.current_config = config and U.copy(config) or {}
end

function S:save_heist_config()
	if not self.current_heist then return end
	local SA = _G.skybox_animated
	if SA then
		SA:set_heist_skybox(self.current_heist, self.current_config)
	end
end

function S:reset_heist_config()
	if not self.current_heist then return end
	local SA = _G.skybox_animated
	if SA then
		SA:reset_heist_skybox(self.current_heist)
		self.current_config = SA:get_current_heist_config(self.current_heist) or {}
	end
end

S:load()
