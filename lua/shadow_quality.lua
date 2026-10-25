-- ============================================================================
-- shadow_quality.lua  -  switch the sun's shadow off, from the mod menu
-- ============================================================================
--
-- WHY THIS EXISTS
-- The sky dome rotates and the sun is baked into the sky cubemap, so the sun
-- moves with it, the godray moves with the sun, and the cast shadow crawls
-- across the floor for the whole rotation. There is no sun_direction value in
-- the environment to hold the sun still, so the shadow cannot be frozen while
-- the sun moves. The control is the shadow itself.
--
-- HOW THE GAME ACTUALLY EXPOSES THIS  (from decompiled lib/managers/menumanager.lua)
--
--   function MenuCallbackHandler:choice_choose_shadow_quality(item)
--       RenderSettings.shadow_quality_default = item:value()
--       MenuCallbackHandler:apply_and_save_render_settings()
--   end
--
--   function MenuCallbackHandler:apply_and_save_render_settings()
--       Application:apply_render_settings()
--       Application:save_render_settings()
--   end
--
-- and the engine's own "restore defaults" path names the un-suffixed key:
--
--   Application:reset_render_settings({
--       "anti_aliasing", "max_anisotropy",
--       "shadow_quality", "shadow_quality_default", "texture_quality_default"
--   })
--
--   * "shadow_quality_default" is the quality tier the Options menu writes.
--     It takes tiers only (low / high / very high), not "disabled".
--   * "shadow_quality" is the un-suffixed override, and it accepts "disabled".
--
-- So the live switch is:
--
--   on  : RenderSettings.shadow_quality = "disabled"; Application:apply_render_settings()
--   off : Application:reset_render_settings({"shadow_quality"}); then apply
--
-- No restart, no read-only attribute, and no Advanced Video crash.
--
-- WHY THE FILE ROUTE IS STILL HERE
-- The engine API is not guaranteed to exist at the instant a menu callback
-- runs, and it may not exist on other builds. If the live call is unavailable
-- this falls back to editing
--
--   %LOCALAPPDATA%\PAYDAY 2\renderer_settings*.xml
--
-- which only takes effect at the NEXT game launch, because renderer settings
-- are parsed during engine boot and a heist restart does not re-read them. The
-- fallback is the old behaviour, and it needs the file locked read-only
-- because the game rewrites the file from memory on exit - measured on
-- 2026-10-25: this module wrote "very high" at 15:37:46, "disabled" at
-- 15:38:12, and the file's timestamp still ended at 15:38:19 with no module
-- entry at that time. That was the engine's own save_render_settings() on
-- shutdown. Changing memory instead of the file is what makes the live path
-- immune to it: the engine then saves the value we set, rather than undoing it.
-- ============================================================================

_G.shadow_quality = _G.shadow_quality or {}
local R = _G.shadow_quality

if R._loaded then return end
R._loaded = true

R.enabled  = R.enabled == true
R.original = R.original or "very high"
R.writes   = 0
R.locked   = false
R.mode     = R.mode or "unknown"    -- "live" or "file"
R.last     = R.last or "never"

local function out(s)
	if log then log("[shadowquality] " .. s) end
end

local function note(s)
	out(s)
	local f = io.open(SavePath .. "shadow_quality.log", "a")
	if f then
		f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n")
		f:close()
	end
end

-- ---------------------------------------------------------------------------
-- shell  (fallback path only)
-- ---------------------------------------------------------------------------

-- Returns success, detail. Handles both os.execute conventions: LuaJIT returns
-- a status number, Lua 5.2+ returns true/nil, "exit", code.
local function run(cmd)
	if type(os.execute) ~= "function" then
		return false, "os.execute unavailable"
	end
	local ok, why, code = os.execute(cmd)
	local success = (ok == true) or (ok == 0) or (why == "exit" and code == 0)
	return success == true, string.format("%s %s %s", tostring(ok), tostring(why), tostring(code))
end

-- A real test, not a guess: a read-only file cannot be opened for append.
local function is_readonly(path)
	local f = io.open(path, "ab")
	if f then
		f:close()
		return false
	end
	return true
end

local function set_attrib(path, on)
	local flag = on and "+R" or "-R"
	local ok, detail = run(string.format('attrib %s "%s" >nul 2>&1', flag, path))
	if not ok then
		note("attrib " .. flag .. " failed for " .. path .. " (" .. detail .. ")")
		return false
	end
	local actual = is_readonly(path)
	if actual ~= on then
		note("attrib " .. flag .. " ran but the file is " ..
			(actual and "still read-only" or "still writable") .. ": " .. path)
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- files
-- ---------------------------------------------------------------------------

local function candidate_paths()
	local list = {}
	local la = nil
	if type(os.getenv) == "function" then
		local ok, v = pcall(os.getenv, "LOCALAPPDATA")
		if ok then la = v end
	end
	if type(la) ~= "string" or la == "" then
		note("LOCALAPPDATA unavailable - cannot locate renderer settings")
		return list
	end
	list[1] = la .. "\\PAYDAY 2\\renderer_settings_dx11.xml"
	list[2] = la .. "\\PAYDAY 2\\renderer_settings.xml"
	return list
end

local function read_file(p)
	local f = io.open(p, "rb")
	if not f then return nil end
	local body = f:read("*a")
	f:close()
	return body
end

local function write_file(p, body)
	local f = io.open(p, "wb")
	if not f then return false end
	local ok = f:write(body)
	f:close()
	return ok ~= nil
end

-- The file used to be written by RENAMING shadow_quality_default to the
-- un-suffixed shadow_quality. That loses the tier, which the Options menu reads
-- as RenderSettings.shadow_quality_default. The file now carries both: the tier
-- stays, and the override is an extra line that can be added and removed.
local TIER     = '(<variable%s+name="shadow_quality_default"%s+value=")[^"]*("/>)'
local OVERRIDE = '\r?\n?[ \t]*<variable%s+name="shadow_quality"%s+value="[^"]*"%s*/>'

local function patch(body, on)
	-- Normalise a legacy file whose tier key was renamed to the override key.
	if not body:find('<variable%s+name="shadow_quality_default"') then
		if body:find('<variable%s+name="shadow_quality"%s+value=') then
			body = body:gsub('<variable(%s+)name="shadow_quality"',
				'<variable%1name="shadow_quality_default"', 1)
		end
	end

	local hit = body:find('<variable%s+name="shadow_quality') ~= nil

	-- The tier is always present and always the remembered value.
	body = body:gsub(TIER, function(a, b) return a .. R.original .. b end)

	-- Drop any existing override, then re-add it when switching on, so the
	-- operation is idempotent instead of accumulating duplicate lines.
	body = body:gsub(OVERRIDE, "")

	if on then
		body = body:gsub('([ \t]*)(<variable%s+name="shadow_quality_default"%s+value="[^"]*"%s*/>)',
			function(indent, line)
				return indent .. line .. "\n" .. indent .. '<variable name="shadow_quality" value="disabled"/>'
			end, 1)
	end

	return body, hit
end

local function remember_original(body)
	if R.original_known then return end
	local v = body:match('<variable%s+name="shadow_quality_default"%s+value="([^"]*)"')
	if v and v ~= "" then
		R.original = v
		R.original_known = true
		note("original shadow tier recorded: " .. v)
	end
end

-- The old fallback leaves the file read-only so the engine's exit save cannot
-- undo it. That lock is a crash footgun in Options > Advanced Video, and the
-- live path makes it unnecessary, so it is cleared on every load.
local function unlock_all()
	for _, p in ipairs(candidate_paths()) do
		if read_file(p) and is_readonly(p) then
			if set_attrib(p, false) then
				note("cleared the leftover read-only lock from " .. p)
			end
		end
	end
end

-- Returns changed, seen, failed, locked.
local function apply_to_files(on, lock)
	local changed, seen, failed, locked = 0, 0, 0, 0

	for _, p in ipairs(candidate_paths()) do
		local body = read_file(p)
		if body then
			seen = seen + 1

			if on then remember_original(body) end

			local new, hit = patch(body, on)
			if not hit then
				note("no shadow_quality variable in " .. p)
				failed = failed + 1
			elseif new == body then
				note("already correct: " .. p)
			else
				-- Unlock only when a write is actually needed.
				if is_readonly(p) and not set_attrib(p, false) then
					failed = failed + 1
				end
				if write_file(p, new) then
					changed = changed + 1
					R.writes = R.writes + 1
					note("wrote " .. (on and "disabled" or R.original) .. " -> " .. p)
				else
					failed = failed + 1
					note("could not write " .. p)
				end
			end

			if lock then
				if set_attrib(p, true) then
					locked = locked + 1
				else
					failed = failed + 1
				end
			end
		end
	end

	if seen == 0 then note("no renderer settings file found") end
	return changed, seen, failed, locked
end

-- ---------------------------------------------------------------------------
-- live engine API
-- ---------------------------------------------------------------------------

local function safe(f)
	local ok, v = pcall(f)
	if ok then return v end
	return nil
end

-- Resolves RenderSettings / Application once per call. Everything is probed
-- with pcall because indexing a half-initialised engine object raises, and a
-- raised error in a menu callback is a broken menu.
local function api()
	local rs  = safe(function() return RenderSettings end)
	local app = safe(function() return Application end)
	if type(rs) ~= "table" then return nil end
	if type(app) ~= "table" and type(app) ~= "userdata" then return nil end

	local apply = safe(function() return app.apply_render_settings end)
	if type(apply) ~= "function" then return nil end

	return {
		rs    = rs,
		app   = app,
		apply = apply,
		reset = safe(function() return app.reset_render_settings end),
		save  = safe(function() return app.save_render_settings end),
	}
end

local function read_field(a)
	local ok, v = pcall(function() return a.rs.shadow_quality end)
	if ok then return v end
	return nil
end

-- Returns ok, detail.
local function live_apply(on)
	local a = api()
	if not a then
		return false, "RenderSettings/Application not available"
	end

	local ok, err
	if on then
		ok, err = pcall(function() a.rs.shadow_quality = "disabled" end)
		if not ok then return false, "assign: " .. tostring(err) end
	else
		if type(a.reset) == "function" then
			ok, err = pcall(function() a.app:reset_render_settings({ "shadow_quality" }) end)
			if not ok then return false, "reset: " .. tostring(err) end
		else
			ok, err = pcall(function() a.rs.shadow_quality = nil end)
			if not ok then return false, "clear: " .. tostring(err) end
		end
	end

	ok, err = pcall(function() a.app:apply_render_settings() end)
	if not ok then return false, "apply: " .. tostring(err) end

	local saved = false
	if type(a.save) == "function" then
		saved = pcall(function() a.app:save_render_settings() end) == true
	end

	return true, string.format("field=%s saved=%s", tostring(read_field(a)), tostring(saved))
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function R.set_enabled(on)
	R.enabled = on

	-- A lock from the fallback path would stop the engine writing its own save.
	unlock_all()

	local ok, detail = live_apply(on)
	if ok then
		R.mode = "live"
		R.locked = false
		R.last = string.format("%s (live, %s)", on and "shadows off" or "shadows on", detail)
		note(R.last)
		R.save()
		return 0
	end

	note("live switch unavailable (" .. tostring(detail) .. ") - using the settings file instead")
	local changed, seen, failed, locked = apply_to_files(on, true)
	R.mode = "file"
	R.locked = locked > 0
	R.last = string.format("%s (file: %d changed, %d file(s), %d failed, %d locked)",
		on and "disabled" or "restored", changed, seen, failed, locked)
	note(R.last)
	R.save()
	return changed
end

function R.enable()  R.set_enabled(true)  end
function R.disable() R.set_enabled(false) end

function R.status()
	local head
	if R.mode == "live" then
		head = "Applied immediately."
	elseif R.mode == "file" then
		head = "Saved to the settings file. Restart PAYDAY 2 to apply."
		if R.locked then
			head = head .. " The file is locked until then - avoid Options > Advanced Video."
		end
	else
		head = "Saved."
	end
	return head .. "\n" .. R.last
end

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

R.SETTINGS_FILE = "shadow_quality_settings.json"

function R.save()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "w")
	if not f then return end
	f:write(string.format('{"enabled":%s,"original":"%s"}\n',
		R.enabled and "true" or "false", R.original))
	f:close()
end

function R.load()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "r")
	if not f then return end
	local body = f:read("*all")
	f:close()
	if not body then return end
	if body:match('"enabled"%s*:%s*true') then R.enabled = true end
	local v = body:match('"original"%s*:%s*"([^"]*)"')
	if v and v ~= "" then
		R.original = v
		R.original_known = true
	end
end

R.load()

-- ---------------------------------------------------------------------------
-- load
-- ---------------------------------------------------------------------------

-- Never keep the old lock around: the live path replaces it, and a read-only
-- renderer file crashes Options > Advanced Video.
unlock_all()

-- Keep the file in step with the toggle so the next boot starts in the right
-- state. This does not lock anything and does not call into the engine - at
-- this point the engine has already read the file for this session.
if R.enabled then
	local changed, seen = apply_to_files(true, false)
	if changed > 0 then
		note("toggle was on but the file had been reverted - rewrote it for the next launch")
	end
else
	local changed = apply_to_files(false, false)
	if changed > 0 then
		note("toggle was off but the file still forced shadows off - restored it for the next launch")
	end
end

local a = api()
note(string.format("loaded - toggle=%s tier=%s engine_api=%s live_field=%s",
	R.enabled and "on" or "off",
	R.original,
	a and "yes" or "no",
	a and tostring(read_field(a)) or "n/a"))
