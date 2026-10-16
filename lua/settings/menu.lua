if not core then
	dofile(ModPath .. "lua/settings/core.lua")
end
core:import("CoreMenuItemOption")
local S = _G.skybox_animated_settings

local MENU = "skybox_animated_options"
local MENU_SKYBOX = "skybox_animated_skybox"
local MENU_GENERATOR = "skybox_animated_generator"
local MENU_HEISTS = "skybox_animated_heists"
local MENU_HEIST = "skybox_animated_heist"
local MENU_ROTATION = "skybox_animated_rotation"
local MENU_SHADOW = "skybox_animated_shadow"
local refresh_heist_choices
local heist_tab_item

-- The multiple-choice item crashes if its option list is empty, so never hand it
-- an empty list and never clear options we cannot immediately refill.
local function skybox_choices(value)
	local SA = _G.skybox_animated
	local ids = SA and SA:get_skybox_ids() or {}
	if type(ids) ~= "table" or #ids == 0 then ids = { "default" } end
	if type(value) == "string" and value ~= "" then
		local found = false
		for _, id in ipairs(ids) do if id == value then found = true; break end end
		if not found then table.insert(ids, 1, value) end
	end
	return ids
end

Hooks:Add("LocalizationManagerPostInit", "skybox_animated_loc", function(loc)
	loc:load_localization_file(S._path .. "loc/english.txt")
end)

local function refresh_active_menu(menu_id)
	local menu = MenuHelper:GetMenu(menu_id)
	if not (menu and menu._items) then return end
	for _, item in pairs(menu._items) do
		local p = item._parameters
		if p and p.name then
			local key = p.name:match("^sa_(.+)$")
			if key and S.settings[key] ~= nil then
				local v = S.settings[key]
				if type(v) == "boolean" then v = v and "on" or "off" end
				item:set_value(v)
			end
		end
	end
end

Hooks:Add("MenuManagerInitialize", "skybox_animated_callbacks", function(menu_manager)
	local function set(key, value, repaint)
		S.settings[key] = value
		if repaint then S:sync() end
		S:save()
	end
	local function slider(key, repaint)
		return function(self, item) set(key, tonumber(item:value()) or S.defaults[key], repaint) end
	end
	local function toggle(key, repaint)
		return function(self, item) set(key, item:value() == "on", repaint) end
	end
	local function choice(key, repaint)
		return function(self, item) set(key, item:value(), repaint) end
	end

	-- Global settings
	MenuCallbackHandler.sa_set_enabled = function(self, item)
		set("enabled", item:value() == "on")
		S:sync()
		S:save()
	end
	MenuCallbackHandler.sa_set_global_enabled = function(self, item)
		local enabled = item:value() == "on"
		set("global_enabled", enabled)
		if heist_tab_item then heist_tab_item:set_enabled(not enabled) end
		S:sync()
		S:save()
	end
	MenuCallbackHandler.sa_set_default_skybox = choice("default_skybox", true)
	MenuCallbackHandler.sa_set_developer_logs = toggle("developer_logs", false)

	-- Heist-specific callbacks
	local function set_heist_config(path, value)
		local cfg = S.current_config
		if path == "skybox" or path == "enabled" then
			cfg[path] = value
		else
			local section, key = path:match("^([^.]+)%.(.+)$")
			cfg[section] = cfg[section] or {}
			cfg[section][key] = value
		end
	end
	MenuCallbackHandler.sa_set_heist_skybox = function(self, item) set_heist_config("skybox", item:value()) end
	MenuCallbackHandler.sa_set_heist_enabled = function(self, item) set_heist_config("enabled", item:value() == "on") end

	MenuCallbackHandler.sa_select_heist = function(self, item)
		local heist = item:value()
		S:load_heist_config(heist)
		menu_manager:open_node(MENU_HEIST, {})
	end

	MenuCallbackHandler.sa_save_heist = function()
		S:save_heist_config()
		S:save()
		QuickMenu:new(managers.localization:text("sa_save_heist_title"), managers.localization:text("sa_save_done"), {}, true)
	end

	MenuCallbackHandler.sa_reset_heist = function()
		S:reset_heist_config()
		refresh_active_menu(MENU_HEIST)
		QuickMenu:new(managers.localization:text("sa_reset_heist_title"), managers.localization:text("sa_reset_done"), {}, true)
	end

	MenuCallbackHandler.sa_rescan_skyboxes = function()
		local loader = _G.skybox_animated_loader
		if loader then loader.rescan() end
		refresh_heist_choices(MENU_HEIST)
		QuickMenu:new(managers.localization:text("sa_rescan_title"), managers.localization:text("sa_rescan_done"), {}, true)
	end
	MenuCallbackHandler.sa_dump_diagnostics = function()
		local env = _G.skybox_animated_env
		if env and env.dump_diagnostics then
			env.dump_diagnostics()
			QuickMenu:new(managers.localization:text("sa_logs_title"), managers.localization:text("sa_logs_done"), {}, true)
		else
			log("[SA] diagnostics unavailable: environment hook not loaded")
		end
	end

	-- Dump the sky internals probe. Read-only: it only reads values and writes
	-- sky_probe_report.txt to the BLT save folder.

	-- Read-only inspection of the environment swap API. No writes.

	-- =========================================================================
	-- Sky rotation driver: enable, and speed in degrees per second.
	-- =========================================================================

	MenuCallbackHandler.sa_rot_enabled = function(self, item)
		local m = _G.sky_rotation
		if not m then
		QuickMenu:new("Sky rotation", "sky_rotation.lua not loaded", {}, true)
		return
	end
	m.set_enabled(item:value() == "on")
	QuickMenu:new("Sky rotation", m.status(), {}, true)
end

-- Brightness removed. Two dead routes, both measured:
--   1. Underlay:material("sky"):set_variable() is a silent no-op - it returns
--      without raising and the value reads back unchanged.
--   2. The environment data path underlay_effect/sky_top/sky_intensity exists
--      only in Tier 2 and 3 environments, 51 of 225. The other 174 are Tier 1
--      legacy and have no sky intensity key under any path name.
-- A control that works on 23% of levels is worse than no control, because it
-- looks functional. See 10_provenance_ledger.md in the report repo.

MenuCallbackHandler.sa_rot_speed = function(self, item)
	local m = _G.sky_rotation
	if not m then return end
	m.set_speed(tonumber(item:value()))
end

-- One-shot toggle from the diagnostics side, so it is reachable even if the
-- player never opens the rotation tab.
MenuCallbackHandler.sa_rot_toggle = function()
	local m = _G.sky_rotation
	if not m then
		QuickMenu:new("Sky rotation", "sky_rotation.lua not loaded", {}, true)
		return
	end
	m.set_enabled(not m.enabled)
	QuickMenu:new("Sky rotation", m.status(), {}, true)
end

-- =========================================================================
-- Sun shadow: one post-processor effect, nothing else.
-- =========================================================================
-- shadow_control.lua swaps the single "shadow_rendering" slot for "empty".
-- SSAO, bloom, AA, DOF, colour grading and ambient are all left alone, which
-- is the whole point - ModWorkshop 20568 strips 18 effects at once and the
-- result looks flat because of the other 17.

MenuCallbackHandler.sa_shadow_enabled = function(self, item)
	local m = _G.shadow_control
	if not m then
		QuickMenu:new("Sun shadow", "shadow_control.lua not loaded", {}, true)
		return
	end
	m.set_enabled(item:value() == "on")
	QuickMenu:new("Sun shadow", m.status(), {}, true)
end

		-- Reads "DDS 123/847 done; 724 remaining" out of a generator status line.
	-- Returns a localized sentence, or "" when the line carries no counts.
	local function dds_progress_summary(result)
	result = tostring(result or "")
	local done, total, remaining = result:match("DDS (%d+)/(%d+) done; (%d+) remaining")
	if not done then return "" end
	local text = managers.localization:text("sa_dds_generator_progress")
	return string.format(text, done, total, remaining)
end

MenuCallbackHandler.sa_generate_dds_from_png = function()
		if S._dds_generator_running then
			QuickMenu:new(managers.localization:text("sa_dds_generator_title"), managers.localization:text("sa_dds_generator_running"), {}, true)
			return
		end
		if not os or not os.execute then
			QuickMenu:new(managers.localization:text("sa_dds_generator_title"), managers.localization:text("sa_dds_generator_unavailable"), {}, true)
			return
		end

		local launcher = S._path .. "tools\\run_generator_hidden.vbs"
		local status_path = S._path .. "tools\\generate_sky_dds.status"
		-- The VBS launcher checks for an existing run before clearing its status;
		-- don't truncate that shared status here if the button is pressed twice.
		local command = 'wscript.exe "' .. launcher .. '"'
		local launched, why, code = os.execute(command)
		local launch_ok = launched == true or launched == 0 or (why == "exit" and code == 0)
		if not launch_ok then
			log("[SA] DDS generator launch failed: " .. tostring(why) .. " " .. tostring(code))
			QuickMenu:new(managers.localization:text("sa_dds_generator_title"), managers.localization:text("sa_dds_generator_unavailable"), {}, true)
			return
		end

		S._dds_generator_running = true
		QuickMenu:new(managers.localization:text("sa_dds_generator_title"), managers.localization:text("sa_dds_generator_started"), {}, true)
		local poll_attempts = 0
		local function poll_generator()
			local status = io.open(status_path, "r")
			local result = status and status:read("*all") or nil
			if status then status:close() end
			if not result or result == "" then
				poll_attempts = poll_attempts + 1
				if poll_attempts >= 900 then
					S._dds_generator_running = false
					log("[SA] standalone DDS generator timed out; see tools/generate_sky_dds.log")
					QuickMenu:new(managers.localization:text("sa_dds_generator_title"), managers.localization:text("sa_dds_generator_failed"), {}, true)
					return
				end
				DelayedCalls:Add("skybox_animated_python_generator_poll", 2, poll_generator)
				return
			end
			if result:match("^RUNNING") or result:match("^WORKING") then
				S._dds_generator_running = true
				if S._dds_generator_progress ~= result then
					S._dds_generator_progress = result
					log("[SA] DDS generator: " .. result)
				end
				DelayedCalls:Add("skybox_animated_python_generator_poll", 2, poll_generator)
				return
			end

			S._dds_generator_running = false
			S._dds_generator_progress = nil
			if result:match("^DONE") then
				local loader = _G.skybox_animated_loader
				if loader then loader.rescan() end
				refresh_heist_choices(MENU_HEIST)
				QuickMenu:new(managers.localization:text("sa_dds_generator_title"), managers.localization:text("sa_dds_generator_done") .. " " .. result, {}, true)
			elseif result:match("^CANCELLED") then
				-- Report the exact done/remaining split instead of a bare
				-- "cancelled", so an early Alt+F4 is not mistaken for success.
				log("[SA] standalone DDS generator cancelled: " .. tostring(result))
				QuickMenu:new(managers.localization:text("sa_dds_generator_title"),
					managers.localization:text("sa_dds_generator_cancelled") .. " " .. dds_progress_summary(result) .. "\n\n" .. result, {}, true)
			else
				log("[SA] standalone DDS generator failed: " .. tostring(result))
				QuickMenu:new(managers.localization:text("sa_dds_generator_title"),
					managers.localization:text("sa_dds_generator_failed") .. "\n\n" .. dds_progress_summary(result) .. "\n\n" .. tostring(result), {}, true)
			end
		end
		DelayedCalls:Add("skybox_animated_python_generator_poll", 2, poll_generator)
	end

	MenuCallbackHandler.sa_dds_generator_status = function()
		local status = io.open(S._path .. "tools\\generate_sky_dds.last_result", "r")
		local last = status and status:read("*all") or nil
		if status then status:close() end
		local current = io.open(S._path .. "tools\\generate_sky_dds.status", "r")
		local live = current and current:read("*all") or nil
		if current then current:close() end
		local body = (live and live ~= "" and live) or (last and last ~= "" and last)
		if not body then
			body = managers.localization:text("sa_dds_generator_no_status")
		end
		QuickMenu:new(managers.localization:text("sa_dds_generator_title"), dds_progress_summary(body) .. "\n\n" .. body, {}, true)
	end

	MenuCallbackHandler.sa_save = function() S:save() end
end)

Hooks:Add("MenuManagerSetupCustomMenus", "skybox_animated_setup", function()
	MenuHelper:NewMenu(MENU)
	MenuHelper:NewMenu(MENU_SKYBOX)
	MenuHelper:NewMenu(MENU_GENERATOR)
	MenuHelper:NewMenu(MENU_HEISTS)
	MenuHelper:NewMenu(MENU_HEIST)
	MenuHelper:NewMenu(MENU_ROTATION)
	MenuHelper:NewMenu(MENU_SHADOW)
end)

local function add_to(menu_id, kind, id, data)
	data.id = "sa_" .. id
	data.title = "sa_" .. id .. "_title"
	data.desc = "sa_" .. id .. "_desc"
	if not data.callback then data.callback = "sa_set_" .. id end
	data.menu_id = menu_id
	data.priority = data.priority or 100
	if kind == "slider" then
		data.show_value = true
		MenuHelper:AddSlider(data)
	elseif kind == "toggle" then
		MenuHelper:AddToggle(data)
	else
		MenuHelper:AddMultipleChoice(data)
	end
end

Hooks:Add("MenuManagerPopulateCustomMenus", "skybox_animated_populate", function()
	local s = S.settings

	-- Skybox tab: global animation settings and per-heist selection.
	add_to(MENU_SKYBOX, "toggle", "enabled", { value = s.enabled, priority = 110 })
	add_to(MENU_SKYBOX, "toggle", "global_enabled", { value = s.global_enabled, priority = 109 })
	

	local skybox_ids = skybox_choices(s.default_skybox)
	add_to(MENU_SKYBOX, "choice", "default_skybox", { value = s.default_skybox or skybox_ids[1], items = skybox_ids, item_values = skybox_ids, localized_items = false, priority = 101 })
	add_to(MENU_SKYBOX, "toggle", "developer_logs", { value = s.developer_logs, priority = 100 })

	local heists = S:get_heist_list()
	local heist_items = {}
	for _, h in ipairs(heists) do
		table.insert(heist_items, h)
	end
	
	MenuHelper:AddMultipleChoice({
		id = "sa_heist_list",
		title = "sa_heist_list_title",
		desc = "sa_heist_list_desc",
		callback = "sa_select_heist",
		items = heist_items,
		item_values = heist_items,
		value = heist_items[1] or "branchbank",
		menu_id = MENU_HEISTS,
		priority = 100,
		localized_items = false,
	})

	-- Generator tab contains resource scanning/generation actions.
	MenuHelper:AddButton({ id = "sa_generate_dds_from_png", title = "sa_generate_dds_title", desc = "sa_generate_dds_desc", callback = "sa_generate_dds_from_png", menu_id = MENU_GENERATOR, priority = 110 })
	MenuHelper:AddButton({ id = "sa_dds_generator_status", title = "sa_dds_generator_status_title", desc = "sa_dds_generator_status_desc", callback = "sa_dds_generator_status", menu_id = MENU_GENERATOR, priority = 105 })
	MenuHelper:AddButton({ id = "sa_rescan_skyboxes", title = "sa_rescan_skyboxes_title", desc = "sa_rescan_skyboxes_desc", callback = "sa_rescan_skyboxes", menu_id = MENU_GENERATOR, priority = 100 })
	MenuHelper:AddButton({ id = "sa_dump_diagnostics", title = "sa_logs_title", desc = "sa_logs_desc", callback = "sa_dump_diagnostics", menu_id = MENU_GENERATOR, priority = 90 })

	-- Rotation tab: the per-frame sky scroll driver.
	local rot = _G.sky_rotation or {}
	MenuHelper:AddToggle({
		id = "sa_rot_enabled",
		title = "sa_rot_enabled_title",
		desc = "sa_rot_enabled_desc",
		callback = "sa_rot_enabled",
		menu_id = MENU_ROTATION,
		value = rot.enabled == true and "on" or "off",
		priority = 110,
	})
	MenuHelper:AddSlider({
		id = "sa_rot_speed",
		title = "sa_rot_speed_title",
		desc = "sa_rot_speed_desc",
		callback = "sa_rot_speed",
		menu_id = MENU_ROTATION,
		value = rot.speed or 4.0,
		min = -360,
		max = 360,
		step = 0.5,
		show_value = true,
		priority = 100,
	})
	MenuHelper:AddButton({ id = "sa_rot_toggle", title = "sa_rot_toggle_title", desc = "sa_rot_toggle_desc", callback = "sa_rot_toggle", menu_id = MENU_ROTATION, priority = 90 })

	-- Shadows tab: drops the sun's cast shadow only.
	local sh = _G.shadow_control or {}
	MenuHelper:AddToggle({
		id = "sa_shadow_enabled",
		title = "sa_shadow_enabled_title",
		desc = "sa_shadow_enabled_desc",
		callback = "sa_shadow_enabled",
		menu_id = MENU_SHADOW,
		value = sh.enabled == true and "on" or "off",
		priority = 110,
	})

	local config = S.current_config or {}
	local heist_skybox_choices = skybox_choices(config.skybox)
	add_to(MENU_HEIST, "choice", "heist_skybox", { value = config.skybox or heist_skybox_choices[1], items = heist_skybox_choices, item_values = heist_skybox_choices, localized_items = false, priority = 100 })
	add_to(MENU_HEIST, "toggle", "heist_enabled", { value = config.enabled ~= false, priority = 99 })
	MenuHelper:AddButton({ id = "sa_save_heist", title = "sa_save_heist_title", desc = "sa_save_done", callback = "sa_save_heist", menu_id = MENU_HEIST, priority = 10 })
end)

Hooks:Add("MenuManagerBuildCustomMenus", "skybox_animated_build", function(menu_manager, nodes)
	nodes[MENU] = MenuHelper:BuildMenu(MENU)
	nodes[MENU_SKYBOX] = MenuHelper:BuildMenu(MENU_SKYBOX)
	nodes[MENU_GENERATOR] = MenuHelper:BuildMenu(MENU_GENERATOR)
	nodes[MENU_HEISTS] = MenuHelper:BuildMenu(MENU_HEISTS)
	nodes[MENU_HEIST] = MenuHelper:BuildMenu(MENU_HEIST)
		nodes[MENU_ROTATION] = MenuHelper:BuildMenu(MENU_ROTATION)
	nodes[MENU_SHADOW] = MenuHelper:BuildMenu(MENU_SHADOW)

	MenuHelper:AddMenuItem(nodes[MENU], MENU_SKYBOX, "sa_skybox_tab_title", "sa_skybox_tab_desc")
		MenuHelper:AddMenuItem(nodes[MENU_SKYBOX], MENU_ROTATION, "sa_rotation_tab_title", "sa_rotation_tab_desc")
	MenuHelper:AddMenuItem(nodes[MENU], MENU_SHADOW, "sa_shadow_tab_title", "sa_shadow_tab_desc")
	heist_tab_item = MenuHelper:AddMenuItem(nodes[MENU], MENU_HEISTS, "sa_heist_tab_title", "sa_heist_tab_desc")
	if heist_tab_item then heist_tab_item:set_enabled(not S.settings.global_enabled) end
	MenuHelper:AddMenuItem(nodes[MENU], MENU_GENERATOR, "sa_generator_tab_title", "sa_generator_tab_desc")
	MenuHelper:AddMenuItem(nodes.blt_options, MENU, "sa_menu_title", "sa_menu_desc")
	log("[skybox_animated] Mod Options menu registered")
end)

refresh_heist_choices = function(menu_id)
	local menu = MenuHelper:GetMenu(menu_id)
	if not (menu and menu._items) then return end
	if not S.current_heist then return end
	
	local config = S.current_config
	local skybox_ids = skybox_choices(config.skybox)
	-- With nothing to show, leave the existing options untouched. Clearing them
	-- and adding none makes reload_item() dereference nil and crash the game.
	if #skybox_ids == 0 then return end
	local names = _G.skybox_animated and _G.skybox_animated:get_available_skyboxes() or {}

	for _, item in pairs(menu._items) do
		local p = item._parameters
		if p and p.name == "sa_heist_skybox" and item.clear_options then
			local current = item:value()
			item:clear_options()
			for i, id in ipairs(skybox_ids) do
				item:add_option(CoreMenuItemOption.ItemOption:new(nil, { text_id = names[i] or id, value = id, localize = false }))
			end
			if #skybox_ids > 0 then
				item:_show_options(item._callback_handler)
				item:set_value(config.skybox or current or skybox_ids[1])
			end
		end
		
		if p and p.name == "sa_heist_enabled" then item:set_value(config.enabled ~= false and "on" or "off") end
	end
end

Hooks:Add("MenuManagerOnOpenMenu", "skybox_animated_heist_menu_populate", function(menu_manager, menu_name)
	if menu_name == MENU_HEIST then
		refresh_heist_choices(MENU_HEIST)
	end
end)
