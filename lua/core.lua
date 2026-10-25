_G.skybox_animated = _G.skybox_animated or {}
local SA = _G.skybox_animated

if SA._core_loaded then
	return
end
SA._core_loaded = true

-- loader.lua already loaded
SA.path = ModPath
SA.enabled = SA.enabled ~= false
SA.heist_skyboxes = SA.heist_skyboxes or {}
SA.global_enabled = SA.global_enabled ~= false

-- Heist to environment mapping (vanilla)
SA.heist_environments = {
	-- Vanilla heists mapped to their default skyboxes
	arm_cro = "sky_city_clear",
	arm_fac = "sky_city_clear",
	arm_hcm = "sky_city_clear",
	arm_par = "sky_city_clear",
	arm_und = "sky_1930_sunset_heavy_clouds",
	alex_1 = "sky_1345_clear_sky",
	alex_2 = "sky_1345_clear_sky",
	alex_3 = "sky_1345_clear_sky",
	arena = "sky_city_clear_high",
	big = "sky_1930_twillight",
	branchbank = "sky_city_clear",
	branchbank_deposit = "sky_city_clear",
	branchbank_cash = "sky_city_clear",
	branchbank_gold = "sky_city_clear",
	branchbank_random = "sky_city_clear",
	cage = "sky_1846_low_sun_nice_clouds",
	cane = "sky_1931_low_sun",
	cas = "sky_1224_clear_sky",
	crojob1 = "sky_1830_low_sun_clouds",
	crojob2 = "sky_1830_low_sun_clouds",
	crojob3 = "sky_1830_low_sun_clouds",
	crojob3_night = "sky_0200_night_moon_stars",
	crojob4 = "sky_1930_sunset_heavy_clouds",
	dark = "sky_2335_night_moon",
	election_day_1 = "sky_1345_clear_sky",
	election_day_2 = "sky_1345_clear_sky",
	election_day_3 = "sky_1345_clear_sky",
	firestarter_1 = "sky_1345_clear_sky",
	firestarter_2 = "sky_1345_clear_sky",
	firestarter_3 = "sky_1345_clear_sky",
	four_stores = "sky_1345_clear_sky",
	framing_frame_1 = "sky_1345_clear_sky",
	framing_frame_2 = "sky_1345_clear_sky",
	framing_frame_3 = "sky_1345_clear_sky",
	hox_1 = "sky_1930_twillight",
	hox_2 = "sky_1930_twillight",
	hox_3 = "sky_1930_twillight",
	hvh = "sky_city_clear",
	jewelry_store = "sky_1345_clear_sky",
	kenaz = "sky_1930_twillight",
	kosugi = "sky_1930_sunset_heavy_clouds",
	mad = "sky_1345_clear_sky",
	man = "sky_1345_clear_sky",
	mia_1 = "sky_1846_low_sun_nice_clouds",
	mia_2 = "sky_1846_low_sun_nice_clouds",
	mus = "sky_1345_clear_sky",
	nightclub = "sky_1345_clear_sky",
	pal = "sky_1345_clear_sky",
	pbr = "sky_1345_clear_sky",
	pbr2 = "sky_1345_clear_sky",
	peta = "sky_1345_clear_sky",
	pines = "sky_1345_clear_sky",
	rabbit = "sky_1345_clear_sky",
	rat = "sky_1345_clear_sky",
	red2 = "sky_1930_sunset_heavy_clouds",
	roberts = "sky_1345_clear_sky",
	safehouse = "sky_1345_clear_sky",
	shoutout_raid = "sky_1345_clear_sky",
	spa = "sky_1345_clear_sky",
	spac = "sky_1345_clear_sky",
	ukrainian_job = "sky_1345_clear_sky",
	watchdogs_1 = "sky_1930_sunset_heavy_clouds",
	watchdogs_2 = "sky_1930_sunset_heavy_clouds",
	watchdogs_2_day = "sky_1830_low_sun_clouds",
	welcome_to_the_jungle_1 = "sky_1345_clear_sky",
	welcome_to_the_jungle_2 = "sky_1345_clear_sky",
	white_xmas = "sky_0902_overcast_dark",
	wwh = "sky_1345_clear_sky",
	born = "sky_1345_clear_sky",
	chew = "sky_1345_clear_sky",
	short1_stage1 = "sky_1345_clear_sky",
	short1_stage2 = "sky_1345_clear_sky",
	short2_stage1 = "sky_1345_clear_sky",
	short2_stage2b = "sky_1345_clear_sky",
	chill = "sky_1345_clear_sky",
	friend = "sky_1345_clear_sky",
	flat = "sky_1345_clear_sky",
	help = "sky_1345_clear_sky",
	haunted = "sky_1930_sunset_heavy_clouds",
	chill_combat = "sky_1345_clear_sky",
	pex = "sky_1345_clear_sky",
	sah = "sky_1345_clear_sky",
	pent = "sky_1345_clear_sky",
	ranc = "sky_1345_clear_sky",
	brb = "sky_1345_clear_sky",
	tag = "sky_1345_clear_sky",
	des = "sky_1345_clear_sky",
	nmh = "sky_1345_clear_sky",
	sand = "sky_1345_clear_sky",
	are = "sky_1345_clear_sky",
	pbm = "sky_1345_clear_sky",
	corp = "sky_1345_clear_sky",
	deep = "sky_1345_clear_sky",
	fish = "sky_1345_clear_sky",
	mdm = "sky_1345_clear_sky",
	bph = "sky_1345_clear_sky",
	chca = "sky_1345_clear_sky",
	crime_spree = "sky_1345_clear_sky",
}

-- Load per-heist skybox config from save file
function SA:load_heist_config()
	local save_path = SavePath .. "skybox_animated_heists.json"
	local data = _G.skybox_animated_util.read_json(save_path)
	if data and data.heists then
		self.heist_skyboxes = data.heists
	end
	-- Per-heist overrides are no longer selectable; keep the legacy save data
	-- readable, but always use the global skybox.
	self.global_enabled = true
	if data and data.default_skybox then
		self.default_skybox = data.default_skybox
	end
end

function SA:save_heist_config()
	local save_path = SavePath .. "skybox_animated_heists.json"
	local data = {
		heists = self.heist_skyboxes,
		global_enabled = self.global_enabled,
		default_skybox = self.default_skybox,
	}
	_G.skybox_animated_util.write_json(save_path, data)
end

-- Get skybox config for current heist
function SA:get_current_heist_config(heist)
	heist = heist or (Global.level_data and Global.level_data.level_id)
	if not heist then return nil end

	-- Check if heist has custom config
	if self.heist_skyboxes[heist] then
		return self.heist_skyboxes[heist]
	end

	-- Return default for this heist
	local env_name = self.heist_environments[heist] or "sky_1345_clear_sky"
	return {
		skybox = env_name,
		rotation = { x = 0, y = 0, z = 0 },
		uv_scroll = { u = 0, v = 0 },
		enabled = true,
	}
end

-- Set skybox for a heist
function SA:set_heist_skybox(heist, config)
	self.heist_skyboxes[heist] = config
	self:save_heist_config()
end

-- Reset heist to default
function SA:reset_heist_skybox(heist)
	self.heist_skyboxes[heist] = nil
	self:save_heist_config()
end

-- Get all available skybox names
function SA:get_available_skyboxes()
	local loader = _G.skybox_animated_loader
	if not loader then return {} end
	local list = loader.skyboxes()
	local names = {}
	for _, s in ipairs(list) do
		table.insert(names, s.name .. " (" .. s.id .. ")")
	end
	return names
end

-- Get skybox IDs
function SA:get_skybox_ids()
	local loader = _G.skybox_animated_loader
	if not loader then return {} end
	local list = loader.skyboxes()
	local ids = {}
	for _, s in ipairs(list) do
		table.insert(ids, s.id)
	end
	return ids
end

SA:load_heist_config()
