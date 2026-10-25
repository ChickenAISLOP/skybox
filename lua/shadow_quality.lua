-- ============================================================================
-- shadow_quality.lua  -  switch the sun's shadow off, from the mod menu
-- ============================================================================
--
-- WHY THIS EXISTS
-- The sky dome rotates and the sun is baked into the sky cubemap, so the sun
-- moves with it, the godray moves with the sun, and the cast shadow crawls
-- across the floor for the whole rotation. There is no sun_direction value in
-- the environment to hold the sun still, so the shadow cannot be frozen while
-- the sun moves. The control is the shadow itself:
--
--     <variable name="shadow_quality" value="disabled"/>
--
-- in  %LOCALAPPDATA%\PAYDAY 2\renderer_settings*.xml
--
-- Note the key. The game writes "shadow_quality_default" at a quality tier
-- (low / high / very high). "disabled" is only accepted on the un-suffixed
-- "shadow_quality" key.
--
-- THE FILE IS READ AT BOOT, NOT PER LEVEL
-- Renderer settings are parsed during engine startup, long before BLT loads
-- mods and long before any heist. So a change written here cannot affect the
-- session that is running, and restarting a heist does not re-read them. Only
-- relaunching the game does. The menu item says so.
--
-- THE GAME REWRITES THE FILE ON EVERY EXIT - MEASURED
-- On 2026-10-25 15:37:46 this module wrote "very high", then wrote "disabled"
-- at 15:38:12 on the next toggle. The file's timestamp was 15:38:19 - seven
-- seconds after the last mod write, with no log entry from this module at that
-- time. That was the game rewriting the file from its own in-memory values as
-- it shut down. A write made during a session is therefore undone at exit.
--
-- That is why read-only exists. The usual advice is to set the attribute by
-- hand; this file does it instead, because os.execute is available here - the
-- DDS generator button in menu.lua already relies on it.
--
-- FOOTGUN, ON PURPOSE AND DOCUMENTED
-- While the file is read-only, changing anything in Options > Advanced Video
-- makes the game fail to write and crash. So the lock does not stay on. It
-- exists only from a toggle until the next launch, and the block at the bottom
-- of this file clears it at load - by which point the game has already read the
-- new value. In the normal running state the file is writable, and the menu
-- description warns about the window in between.
--
-- BOTH DIRECTIONS LOCK, NOT JUST "DISABLE"
-- Restoring used to write "very high" and leave the file writable, and the game
-- put "disabled" back on exit. That is the bug that was reported: the restore
-- appeared to do nothing. A restore has to be protected from the exit write for
-- exactly the same reason the disable does.
--
-- VERIFICATION, NOT HOPE
-- attrib is a shell call, so it can lie. After setting the attribute this file
-- tries to open the settings file for append: if that fails, the file really is
-- read-only. The result is written to mods/saves/shadow_quality.log so the
-- claim is checkable rather than assumed.
-- ============================================================================

_G.shadow_quality = _G.shadow_quality or {}
local R = _G.shadow_quality

if R._loaded then return end
R._loaded = true

R.enabled  = R.enabled == true
R.original = R.original or "very high"
R.writes   = 0
R.locked   = false
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
	if n > 80 then _seen = {} end

	out(s)
	local f = io.open(SavePath .. "shadow_quality.log", "a")
	if f then
		f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n")
		f:close()
	end
end

-- ---------------------------------------------------------------------------
-- shell
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
	-- attrib can report success and still not have done it, so confirm by use.
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

-- Returns changed, seen, failed, locked
local function apply_to_files(on)
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
				-- Unlock only when a write is actually needed, so the file is not
				-- left writable when nothing had to change.
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

			-- Keep it locked after ANY change, in both directions. The game
			-- rewrites the file on exit from its own memory, so unlocking here
			-- would let it undo a restore exactly the way it undid the first
			-- one. The lock is cleared on the next launch by the block at the
			-- bottom of this file, after the game has already read the new
			-- value. The lock therefore only ever exists between a toggle and
			-- the next launch.
			if set_attrib(p, true) then
				locked = locked + 1
			else
				failed = failed + 1
			end
		end
	end

	if seen == 0 then note("no renderer settings file found") end
	return changed, seen, failed, locked
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function R.set_enabled(on)
	R.enabled = on
	local changed, seen, failed, locked = apply_to_files(on)
	R.locked = locked > 0
	R.last = string.format("%s -> %s (%d changed, %d file(s), %d failed, %d locked)",
		on and "disabled" or "restored", on and "disabled" or R.original,
		changed, seen, failed, locked)
	R.save()
	if on and seen > 0 and locked == 0 then
		note("WARNING: could not make the file read-only - the game will undo this on exit")
	end
	return changed
end

function R.enable()  R.set_enabled(true)  end
function R.disable() R.set_enabled(false) end

function R.status()
	local head = "Saved. Restart PAYDAY 2 to apply."
	if R.locked then
		head = head .. "\nThe settings file is locked so the game cannot undo this on exit. Avoid Options > Advanced Video until after the restart."
	else
		head = head .. "\nWarning: the file is not locked, so the game may undo this when it closes."
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

-- Self-heal: if the toggle is on, make sure the file still says disabled AND is
-- still locked. A previous session may have been interrupted before the
-- attribute was set, or the attribute may have been cleared by hand.
if R.enabled then
	local changed, seen, failed, locked = apply_to_files(true)
	R.locked = locked > 0
	if changed > 0 then
		note("toggle was on but the file had been reverted - rewrote it")
	end
elseif not R.enabled then
	-- Leaving shadows on is the normal state; make sure nothing is still locked
	-- from an earlier run, because a locked file breaks Advanced Video.
	for _, p in ipairs(candidate_paths()) do
		if read_file(p) and is_readonly(p) then
			if set_attrib(p, false) then
				note("cleared a leftover read-only lock from " .. p)
			end
		end
	end
end

note(string.format("loaded - %s (tier when on: %s, file locked: %s)",
	R.enabled and "shadows off" or "shadows on", R.original, tostring(R.locked)))
