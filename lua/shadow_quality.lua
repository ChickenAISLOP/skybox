-- ============================================================================
-- shadow_quality.lua  -  switch the sun's shadow off, from the mod menu
-- ============================================================================
--
-- WHY THIS EXISTS
-- The sky dome rotates and the sun is baked into the sky cubemap, so the sun
-- moves with it, the godray moves with the sun, and the cast shadow crawls
-- across the floor for the whole rotation. There is no sun_direction value in
-- the environment to hold the sun still, so the shadow cannot be frozen while
-- the sun moves. The community answer is to switch shadows off outright:
--
--     <variable name="shadow_quality" value="disabled"/>
--
-- in  %LOCALAPPDATA%\PAYDAY 2\renderer_settings*.xml
--
-- Note the key. The game writes "shadow_quality_default" at a quality tier
-- (low / high / very high). "disabled" is only accepted on the un-suffixed
-- "shadow_quality" key. Using "disabled" on the _default key is reported not
-- to work, and this file follows that.
--
-- WHY THE FILE AND NOT A LIVE CALL
-- lib/managers/menumanager.lua contains shadow_quality, choose_shadow_quality,
-- set_setting and apply_render_settings, so a runtime route probably exists.
-- It is NOT used here. The object that owns set_setting was never identified,
-- and calling it with a wrong value type on an unknown object is how this
-- project produced its crashes. Writing the file is the route that is known to
-- work, so that is the route this ships.
--
-- THE COST: A RESTART
-- Renderer settings are read during boot, long before BLT loads mods. Writing
-- the file at load therefore cannot affect the session that is already running.
-- The change lands on the next launch. The menu says so.
--
-- THE READ-ONLY PROBLEM - HONEST LIMITATION
-- The usual advice is to mark the file read-only so the game cannot revert it.
-- Lua cannot do that: io.open writes bytes, and there is no chmod. So this file
-- does NOT set read-only, and does not pretend to. If the game turns out to
-- write its own value back over this one, that has to be fixed by hand:
--
--     right-click renderer_settings_dx11.xml -> Properties -> Read-only
--
-- which is also what makes Options > Advanced Video crash while it is set, so
-- it is not something to switch on blindly. mods/saves/shadow_quality.log
-- records what was written and when, so whether it survived is checkable.
--
-- WHAT IS RESTORED
-- The original value is read out of the file the first time the toggle is
-- switched on, and written back verbatim when it is switched off. If it cannot
-- be read, "very high" is used, which is what this install shipped with.
-- ============================================================================

_G.shadow_quality = _G.shadow_quality or {}
local R = _G.shadow_quality

if R._loaded then return end
R._loaded = true

R.enabled  = R.enabled == true
R.original = R.original or "very high"
R.writes   = 0
R.last     = "never"

local function out(s)
	if log then log("[shadowquality] " .. s) end
end

local _seen = {}
local function note(s)
	local key = tostring(s):gsub("%d+", "N")
	if _seen[key] then return end
	_seen[key] = true
	local n = 0
	for _ in pairs(_seen) do n = n + 1 end
	if n > 60 then _seen = {} end

	out(s)
	local f = io.open(SavePath .. "shadow_quality.log", "a")
	if f then
		f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n")
		f:close()
	end
end

-- ---------------------------------------------------------------------------
-- files
-- ---------------------------------------------------------------------------

-- DX11 installs use renderer_settings_dx11.xml; older ones use the plain name.
-- Both are checked so this works on either.
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

-- Matches the shadow variable whatever it is currently called, so the
-- _default / un-suffixed switch is a one-line change rather than a rewrite.
local PATTERN = '(<variable%s+name=")shadow_quality[^"]*("%s+value=")[^"]*("/>)'

local function patch(body, on)
	local hit = false
	local new = body:gsub(PATTERN, function(a, b, c)
		hit = true
		return a .. (on and "shadow_quality" or "shadow_quality_default")
			.. b .. (on and "disabled" or R.original) .. c
	end)
	return new, hit
end

-- Remembers the tier the game was using, so switching off puts back what was
-- there rather than a guess.
local function remember_original(body)
	if R.original_known then return end
	local v = body:match('<variable%s+name="shadow_quality_default"%s+value="([^"]*)"')
	if v and v ~= "" then
		R.original = v
		R.original_known = true
		note("original shadow tier recorded: " .. v)
	end
end

-- Returns changed, seen, failed
local function apply_to_files(on)
	local changed, seen, failed = 0, 0, 0
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
			elseif write_file(p, new) then
				changed = changed + 1
				R.writes = R.writes + 1
				note("wrote " .. (on and "disabled" or R.original) .. " -> " .. p)
			else
				failed = failed + 1
				note("could not write " .. p)
			end
		end
	end
	if seen == 0 then note("no renderer settings file found") end
	return changed, seen, failed
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function R.set_enabled(on)
	R.enabled = on
	local changed, seen, failed = apply_to_files(on)
	R.last = string.format("%s -> %s (%d changed, %d file(s), %d failed)",
		on and "disabled" or "restored", on and "disabled" or R.original,
		changed, seen, failed)
	R.save()
	if on and failed > 0 then
		note("some files could not be patched - see the lines above")
	end
	return changed
end

function R.enable()  R.set_enabled(true)  end
function R.disable() R.set_enabled(false) end

function R.status()
	return "Saved. Restart PAYDAY 2 to apply.\n" .. R.last
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

-- Self-heal: if the toggle is on but the file no longer says disabled, the game
-- put its own value back. Re-assert it. This cannot rescue the current session
-- (settings were read at boot) but it means the next launch is correct.
if R.enabled then
	local changed = apply_to_files(true)
	if changed > 0 then
		note("toggle was on but the file had been reverted - rewrote it")
	end
end

note(R.enabled and "loaded - shadows off (" .. R.original .. " when on)" or "loaded - shadows on (" .. R.original .. ")")
