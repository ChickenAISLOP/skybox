-- ============================================================================
-- render_probe.lua  -  TEMPORARY, read-only. Delete once answered.
-- ============================================================================
--
-- WHY
-- The sun shadow is controlled by a graphics setting, not by the post-processor
-- interface. lib/managers/menumanager.lua contains:
--     shadow_quality, shadow_quality_default,
--     choice_choose_shadow_quality, choose_shadow_quality,
--     set_setting, get_setting, save_setting,
--     apply_render_settings, reset_render_settings, RenderSettings
-- so the setting exists and something can set it. What is NOT known is which
-- object owns those methods, or what value shadow_quality wants.
--
-- Everything below only reads. No set_setting, no render call, no hook that
-- touches a viewport. It logs once at load and then sits there doing nothing.
-- ============================================================================

local P = {}
_G.render_probe = P

local function out(s)
	if log then log("[renderprobe] " .. s) end
	local f = io.open(SavePath .. "render_probe.log", "a")
	if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n"); f:close() end
end
P.out = out

local function run()
	local L = {}

	-- 1. What is under managers at all?
	L[#L+1] = "--- managers with a set_setting / get_setting ---"
	local names = {}
	if type(managers) == "table" then
		for k in pairs(managers) do
			if type(k) == "string" then names[#names+1] = k end
		end
	end
	table.sort(names)
	L[#L+1] = "  manager names: " .. table.concat(names, ", ")

	for _, n in ipairs(names) do
		local ok, m = pcall(function() return managers[n] end)
		if ok and type(m) == "table" then
			local has = {}
			for _, meth in ipairs({ "set_setting", "get_setting", "save_setting",
			                        "apply_render_settings", "reset_render_settings",
			                        "save_render_settings", "set_quality" }) do
				if type(m[meth]) == "function" then has[#has+1] = meth end
			end
			if #has > 0 then
				L[#L+1] = string.format("  managers.%-22s has: %s", n, table.concat(has, ", "))
			end
		end
	end

	-- 2. Globals that look like the render settings holder.
	L[#L+1] = "--- candidate globals ---"
	for _, n in ipairs({ "RenderSettings", "render_settings", "VideoSettings",
	                     "GameSettings", "CoreEnvironmentControllerManager" }) do
		local ok, v = pcall(function() return _G[n] end)
		if ok and v ~= nil then
			L[#L+1] = string.format("  _G.%-30s = %s", n, tostring(v))
		else
			L[#L+1] = string.format("  _G.%-30s = nil", n)
		end
	end

	-- 3. Read the current shadow_quality through whatever exposes get_setting.
	--    Read-only. If several objects answer, all are reported.
	L[#L+1] = "--- get_setting(\"shadow_quality\") ---"
	local probed = 0
	local function try_get(holder, label)
		if type(holder) ~= "table" then return end
		if type(holder.get_setting) ~= "function" then return end
		local ok, v = pcall(function() return holder:get_setting("shadow_quality") end)
		if ok then
			L[#L+1] = string.format("  %-28s = %s (%s)", label, tostring(v), type(v))
			probed = probed + 1
		else
			L[#L+1] = string.format("  %-28s ERROR %s", label, tostring(v))
		end
	end

	for _, n in ipairs(names) do
		local ok, m = pcall(function() return managers[n] end)
		if ok then try_get(m, "managers." .. n) end
	end
	local okr, r = pcall(function() return _G.RenderSettings end)
	if okr then try_get(r, "_G.RenderSettings") end
	if probed == 0 then
		L[#L+1] = "  no object answered get_setting; the setting is reached another way"
	end

	-- 4. Does anything expose the limits, which would reveal the valid range?
	L[#L+1] = "--- setting limits ---"
	for _, n in ipairs(names) do
		local ok, m = pcall(function() return managers[n] end)
		if ok and type(m) == "table" then
			local ok2, lim = pcall(function() return m.setting_limits end)
			if ok2 and lim ~= nil then
				L[#L+1] = string.format("  managers.%s.setting_limits = %s", n, tostring(lim))
			end
		end
	end

	L[#L+1] = "--- end ---"
	for _, l in ipairs(L) do out(l) end
end

Hooks:Add("GameSetupUpdate", "skybox_animated_render_probe", function()
	-- Run once, on the first tick, so every manager has finished registering.
	if P.done then return end
	P.done = true
	local ok, err = pcall(run)
	if not ok then out("probe itself raised: " .. tostring(err)) end
end)