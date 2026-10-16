-- ============================================================================
-- shadow_control.lua  -  turn the sun's cast shadow off, touch nothing else
-- ============================================================================
--
-- STATUS: under test. One configuration is known NOT to work; see MODES below.
--
-- WHAT THIS IS
-- A control that removes the hard black shadow the sun casts (the lamppost
-- stripe across the road, the block shadows on Chinatown) and leaves every
-- other part of the image alone.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH
-- ModWorkshop 20568 ("Remove Shadows FPS Boost") strips 18 things at once:
-- SSAO, bloom, AA, light adaptation, LEX composite, DOF, depth projection,
-- deferred lighting, ambient, colour grading and more. Everything except the
-- sky looks flat as a result. This only ever writes to the shadow branch of
-- the post-effect tree.
--
-- THE TREE
-- default.environment defines:
--
--   post_effect
--     |- deferred
--     |   |- deferred_lighting
--     |   `- apply_ambient
--     `- shadow_processor
--         `- shadow_rendering
--             `- shadow_modifier
--                 |- slice0 .. slice3
--                 |- shadow_slice_depths
--                 `- shadow_slice_overlap
--
-- MECHANISM
-- vp:vp():set_post_processor_effect(pass, name, implementation) swaps the
-- implementation at a slot. "empty" is a real null implementation defined in
-- core/shaders/post_processor.post_processor.
--
-- WHAT WE HAVE MEASURED SO FAR
-- 2026-10-16 10:15:05, mode "rendering":
--     [10:15:05] on shadow_rendering -> empty on 2 viewport(s)
-- No error, no crash, pcall succeeded on both viewports - and the shadow was
-- still on screen. So the call was ACCEPTED AND DID NOTHING. That is a silent
-- no-op, exactly like Underlay:material("sky"):set_variable() was for
-- brightness. A successful pcall proves the call did not fault; it does not
-- prove the engine honoured it.
--
-- The likely reason: "empty" is defined in post_processor.post_processor, not
-- in shadow_processor.post_processor, so it may not be a legal implementation
-- for that slot and is discarded without complaint. Unproven - which is why
-- this is a selector instead of one hardcoded call.
--
-- CALLS USED, AND THEIR EVIDENCE
--   managers.viewport:viewports()      ModWorkshop 20568, 25k downloads
--   vp:vp()                            Environment Editor mod (env.lua)
--   vp:vp():set_post_processor_effect  ModWorkshop 20568
--   vp:vp():get_post_processor_effect  Environment Editor mod (env.lua)
--   Hooks:Add("GameSetupUpdate", ...)   already used twice in this mod
--
-- RESTORE
-- Still unproven. Mod 20568 never restores anything. Restarting the game is
-- always a full restore: the tree is rebuilt from the environment on load.
-- ============================================================================

_G.shadow_control = _G.shadow_control or {}
local R = _G.shadow_control

if R._loaded then return end
R._loaded = true

-- ---------------------------------------------------------------------------
-- modes
-- ---------------------------------------------------------------------------
--
-- Each mode is a list of writes. "every" is what ModWorkshop 20568 does to the
-- shadow branch, and is included as the control case: if "every" does not kill
-- the shadow either, then the shadow is not coming from this tree at all and
-- the whole approach is wrong.

local I_EMPTY = "empty"

R.MODES = {
	rendering = { { name = "shadow_rendering",   value = I_EMPTY } },
	processor = { { name = "shadow_processor",   value = I_EMPTY } },
	modifier  = { { name = "shadow_modifier",    value = I_EMPTY } },
	ambient   = { { name = "apply_ambient",      value = I_EMPTY } },
	deferred  = { { name = "deferred_lighting",  value = I_EMPTY } },
	slices    = {
		{ name = "shadow_slice_depths",  value = Vector3(0, 0, 0) },
		{ name = "shadow_slice_overlap", value = Vector3(0, 0, 0) },
	},

	-- Shadows only. Everything in the shadow branch of the tree, nothing else.
	shadow_all = {
		{ name = "shadow_processor",     value = I_EMPTY },
		{ name = "shadow_rendering",     value = I_EMPTY },
		{ name = "shadow_modifier",      value = I_EMPTY },
		{ name = "shadow_slice_depths",  value = Vector3(0, 0, 0) },
		{ name = "shadow_slice_overlap", value = Vector3(0, 0, 0) },
	},

	-- CONTROL CASE. Verbatim from Seamlink's "No Shadows or Effects" and ModWorkshop
	-- 20568. Both are reported to work, so if this does NOT remove the shadow then
	-- the premise is wrong somewhere else and none of the others mean anything.
	-- It also strips every post-process effect, which is exactly what the user does
	-- not want - this mode exists to confirm the reference behaviour, not to ship.
	ref_full = {
		{ name = "hdr_post_processor",       value = I_EMPTY },
		{ name = "post_SSAO",                value = I_EMPTY },
		{ name = "bloom_combine_post_processor", value = Idstring("bloom_combine_empty") },
		{ name = "bloom_combine",            value = Idstring("bloom_combine_empty") },
		{ name = "shadow_processor",         value = I_EMPTY },
		{ name = "shadow_modifier",          value = I_EMPTY },
		{ name = "video_anti_alias",         value = Idstring("AA_off") },
		{ name = "shadow_rendering",         value = I_EMPTY },
		{ name = "light_adaption",           value = Idstring("no_light_adaption") },
		{ name = "post_LEX_composite",       value = I_EMPTY },
		{ name = "post_DOF",                 value = I_EMPTY },
		{ name = "depth_projection",         value = Idstring("depth_project_empty") },
		{ name = "shadow_slice_depths",      value = Vector3(0, 0, 0) },
		{ name = "shadow_slice_overlap",     value = Vector3(0, 0, 0) },
		{ name = "deferred_lighting",        value = I_EMPTY },
		{ name = "apply_ambient",            value = I_EMPTY },
		{ name = "color_grading_post",       value = I_EMPTY },
	},
}

R.MODE_ORDER = {
	"off", "rendering", "processor", "modifier",
	"ambient", "deferred", "slices", "shadow_all", "ref_full",
}

R.enabled = R.enabled == true
R.mode    = R.mode or "rendering"     -- where we last were: known not to work

-- runtime state
R.applied        = nil
R.errors         = 0
R.disabled_by_error = false
R.viewports      = 0
R.probed         = false

local function out(s)
	if log then log("[shadowctl] " .. s) end
end

local function dump(lines)
	for _, l in ipairs(lines) do out(l) end
	local f = io.open(SavePath .. "shadow_control.log", "a")
	if f then
		for _, l in ipairs(lines) do f:write(os.date("[%H:%M:%S] ") .. l .. "\n") end
		f:close()
	end
end

-- Throttled: the heartbeat retries while no viewport exists, which is every
-- loading screen. Same reasoning as sky_rotation.lua's note().
local _seen = {}
local function note(s)
	local key = s:gsub("%d+", "N")
	if _seen[key] then return end
	_seen[key] = true
	local n = 0
	for _ in pairs(_seen) do n = n + 1 end
	if n > 40 then _seen = {} end
	out(s)
	local f = io.open(SavePath .. "shadow_control.log", "a")
	if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. s .. "\n"); f:close() end
end

-- ---------------------------------------------------------------------------
-- viewports
-- ---------------------------------------------------------------------------

-- Mirrors ModWorkshop 20568: every viewport, not just the active one.
local function viewports()
	if not (managers and managers.viewport) then return nil end

	local ok, list = pcall(function() return managers.viewport:viewports() end)
	if not ok or type(list) ~= "table" then return nil end

	local out_list, n = {}, 0
	for _, entry in ipairs(list) do
		-- entry is the wrapper, :vp() is the native viewport. Two hops; getting
		-- this wrong is the same mistake that crashed six earlier probes.
		local g, native = pcall(function() return entry:vp() end)
		if g and native then
			n = n + 1
			out_list[n] = native
		end
	end
	if n == 0 then return nil end
	return out_list
end

-- ---------------------------------------------------------------------------
-- introspection - run once, read-only
-- ---------------------------------------------------------------------------
--
-- The problem with this feature is that a successful call is indistinguishable
-- from an ignored one. This dumps what the post-processor object actually is,
-- and which method names exist on it, so the next guess is informed instead of
-- guessed. Strictly reads; writes nothing.

local PROBE_NAMES = {
	"shadow_processor", "shadow_rendering", "shadow_modifier",
	"shadow_slice_depths", "shadow_slice_overlap",
	"deferred", "deferred_lighting", "apply_ambient",
}

-- Plausible method names on a post-processor object. Listed rather than called
-- blindly, so we learn the real surface instead of guessing.
local PROBE_METHODS = {
	"modifier", "material", "effects", "effect", "modifiers",
	"implementation", "name", "type", "enable", "set_visibility",
	"get_implementation", "current_implementation",
}

local function probe_once()
	if R.probed then return end
	local list = viewports()
	if not list then return end
	local vp = list[1]

	local lines = { "--- introspection ---" }

	for _, name in ipairs(PROBE_NAMES) do
		local ok, p = pcall(function()
			return vp:get_post_processor_effect("World", Idstring(name))
		end)
		if not ok then
			lines[#lines+1] = string.format("  %-22s ERROR %s", name, tostring(p))
		elseif p == nil then
			lines[#lines+1] = string.format("  %-22s nil", name)
		else
			lines[#lines+1] = string.format("  %-22s %s", name, tostring(p))
			-- Only introspect the first real object; they are all the same class.
			if not R._probed_methods then
				local found = {}
				for _, m in ipairs(PROBE_METHODS) do
					local g, v = pcall(function() return p[m] end)
					if g and type(v) == "function" then found[#found+1] = m end
				end
				R._probed_methods = true
				lines[#lines+1] = "    methods: " .. table.concat(found, ", ")
			end
		end
	end
	lines[#lines+1] = "--- end introspection ---"
	dump(lines)
	R.probed = true
end

-- ---------------------------------------------------------------------------
-- apply
-- ---------------------------------------------------------------------------

local function apply_impl()
	if not R.enabled then return end
	local mode = R.MODES[R.mode]
	if not mode then return end

	local list = viewports()
	if not list then return end

	if R.applied == R.mode then return end

	local ok_count, fail_count, last_err = 0, 0, nil
	for _, vp in ipairs(list) do
		for _, w in ipairs(mode) do
			local ok, err = pcall(function()
				vp:set_post_processor_effect("World", Idstring(w.name), w.value)
			end)
			if ok then ok_count = ok_count + 1 else
				fail_count = fail_count + 1
				last_err = tostring(err)
			end
		end
	end

	R.viewports = #list
	if ok_count > 0 then
		R.applied = R.mode
		local names = {}
		for _, w in ipairs(mode) do names[#names+1] = w.name end
		local line = string.format("mode %s: %d write(s) ok on %d viewport(s) [%s]",
			R.mode, ok_count, #list, table.concat(names, ", "))
		if fail_count > 0 then
			line = line .. string.format(" ; %d FAILED last=%s", fail_count, tostring(last_err))
		end
		note(line)
	end
end

function R.enable()
	R.enabled = true
	R.applied = nil
	R.disabled_by_error = false
	probe_once()
	apply_impl()
	R.save()
end

function R.disable()
	R.enabled = false
	-- Deliberately writes nothing. There is no confirmed inverse implementation,
	-- and a wrong one could make things worse than leaving it. Restarting the
	-- game rebuilds the tree from the environment, which is a guaranteed restore.
	R.applied = nil
	R.save()
	note("disabled; no inverse written (restart restores the tree)")
end

function R.set_enabled(on)
	if on == true then R.enable() else R.disable() end
end

function R.set_mode(mode)
	if R.mode == mode then return end
	R.mode = R.MODES[mode] and mode or R.mode
	R.applied = nil          -- force the writes even if the toggle did not move
	if R.enabled then apply_impl() end
	R.save()
end

-- ---------------------------------------------------------------------------
-- heartbeat
-- ---------------------------------------------------------------------------

-- The engine rebuilds the tree on a level load, a resolution change and a
-- graphics change, silently reverting every write. Re-assert on a slow
-- heartbeat rather than every frame; R.applied only advances after a
-- successful write, so a viewport coming and going cannot fake success.
local function heartbeat_impl()
	if not R.enabled then return end
	if R.disabled_by_error then return end

	local ok, err = pcall(apply_impl)
	if not ok then
		R.errors = R.errors + 1
		if R.errors <= 3 or R.errors % 300 == 0 then
			note("apply error #" .. tostring(R.errors) .. ": " .. tostring(err))
		end
		if R.errors >= 10 then
			R.disabled_by_error = true
			note("auto-disabled after " .. tostring(R.errors) .. " errors; re-enable from the menu")
		end
	end
end

local _tick = 0
function R.step(t, dt)
	_tick = _tick + 1
	if _tick < 120 then return end
	_tick = 0
	heartbeat_impl()
end

Hooks:Add("GameSetupUpdate", "skybox_animated_shadow_control", function(t, dt)
	R.step(t, dt)
end)

Hooks:Add("LevelLoaded", "skybox_animated_shadow_control_level", function()
	R.applied = nil
	R.errors = 0
	R.disabled_by_error = false
end)

-- If the player opens the menu while enabled and the engine dropped it in the
-- meantime, this is the moment to put it back - and to run introspection the
-- first time, so the log has the structure in it.
Hooks:Add("MenuManagerOnOpenMenu", "skybox_animated_shadow_control_menu", function()
	probe_once()
	R.applied = nil
	heartbeat_impl()
end)

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

R.SETTINGS_FILE = "shadow_control_settings.json"

function R.save()
	local f = io.open(SavePath .. R.SETTINGS_FILE, "w")
	if not f then return end
	f:write(string.format('{"enabled":%s,"mode":"%s"}\n',
		R.enabled and "true" or "false", R.mode))
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
end

function R.status()
	return string.format("enabled=%s mode=%s viewports=%d writes_ok errors=%d%s",
		tostring(R.enabled), R.mode, R.viewports, R.errors,
		R.disabled_by_error and " AUTO-DISABLED" or "")
end

R.load()
note(R.enabled
	and ("loaded - enabled, mode " .. R.mode)
	or  ("loaded - idle, mode " .. R.mode))