-- ============================================================================
-- shadow_control.lua  -  turn the sun's cast shadow off, touch nothing else
-- ============================================================================
--
-- CRASH HISTORY - READ THIS FIRST
-- 2026-10-16 10:21:45, this file crashed PAYDAY 2 with an access violation.
-- The call was vp:set_post_processor_effect("World", Idstring("shadow_rendering"),
-- Idstring("empty")) fired from the MenuManagerOnOpenMenu hook. pcall cannot
-- catch an access violation, so the guard did nothing and the game died.
-- That is crash 7 of mine. The cause is recorded below under WHAT WENT WRONG;
-- the fix is that no code path writes to a post processor unless the player
-- explicitly asked for it.
--
-- WHAT WENT WRONG
-- The slot name was wrong, and runtime introspection proved it:
--
--   shadow_processor     [TextureEffectInstanceInterface 0000000078EF02D0]
--     methods: modifier, modifiers, set_visibility
--   shadow_rendering     nil
--   shadow_modifier      nil
--   shadow_slice_depths  nil
--   shadow_slice_overlap nil
--   deferred             [TextureEffectInstanceInterface 0000000078EF0240]
--   deferred_lighting    nil
--   apply_ambient        nil
--
-- get_post_processor_effect only resolves TOP-LEVEL post processors. Every
-- inner effect name in default.environment - shadow_rendering, shadow_modifier,
-- the slice parameters, deferred_lighting, apply_ambient - returns nil. So the
-- call I shipped was writing to a slot that does not exist.
--
-- That also explains the earlier false positive. At 10:15:05 the same call
-- "succeeded" on 2 viewports with no error, and the shadow stayed on screen:
--     [10:15:05] on shadow_rendering -> empty on 2 viewport(s)
-- A slot that resolves to nil is silently ignored. A successful pcall proves
-- the call did not fault; it does not prove the engine honoured it. Treating
-- it as proof is what produced the false "it works".
--
-- The real target is shadow_processor, which does resolve.
--
-- WHY THERE IS NO HEARTBEAT ANY MORE
-- The crash happened while a menu was opening, from a GameSetupUpdate-driven
-- re-assert. ModWorkshop 20568 and Seamlink's mod only ever write from a
-- persist_script bound to SetVideo - a player action - and neither of them
-- re-asserts on a timer. Auto-reapplying was my own addition and it is what
-- killed the game.
--
-- There is also no MenuManagerOnCloseMenu hook in this build to pair with
-- MenuManagerOnOpenMenu, so "is a menu open right now" cannot be answered
-- reliably, and guessing a managers.menu method is how six of the seven
-- crashes happened. So nothing is applied automatically. The engine rebuilds
-- the post-effect tree on a level load, a resolution change and a graphics
-- change; if the shadow comes back after one of those, flip the toggle off
-- and on again. That is a two-second fix and it cannot kill the game.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH
-- ModWorkshop 20568 and Seamlink's mod strip 18 things at once: SSAO, bloom,
-- AA, light adaptation, LEX composite, DOF, depth projection, deferred
-- lighting, ambient, colour grading. Everything except the sky looks flat as a
-- result. This writes to shadow_processor and nothing else, so deferred
-- lighting, ambient and every post-process effect are left alone.
--
-- THE TREE (default.environment)
--   post_effect
--     |- deferred                      <- lighting; never touched here
--     |   |- deferred_lighting
--     |   `- apply_ambient
--     `- shadow_processor              <- the sun's shadow; the only target
--         `- shadow_rendering
--             `- shadow_modifier
--                 |- slice0 .. slice3
--                 |- shadow_slice_depths
--                 `- shadow_slice_overlap
--
-- CALLS USED, AND THEIR EVIDENCE
--   managers.viewport:viewports()      ModWorkshop 20568, 25k downloads
--   vp:vp()                            Environment Editor mod (env.lua)
--   vp:vp():get_post_processor_effect  Environment Editor mod (env.lua)
--   vp:set_post_processor              Introspection found it on the object
--   method set_visibility              itself; nothing outside this mod calls it
--
-- RESTORE
-- Still unproven. Neither reference mod restores anything. A game restart is
-- always a full restore, because the tree is rebuilt from the environment on
-- load.
-- ============================================================================

_G.shadow_control = _G.shadow_control or {}
local R = _G.shadow_control

if R._loaded then return end
R._loaded = true

-- ---------------------------------------------------------------------------
-- modes
-- ---------------------------------------------------------------------------
--
-- MEASURED RESULTS, in the order they were tried
--   rendering  shadow_rendering -> empty       ACCEPTED, NO EFFECT (slot is nil)
--   hide       shadow_processor:set_visibility(false)
--                                            ACCEPTED, NO EFFECT  2026-10-16 10:34
--   blank      shadow_processor -> empty       RAN 2026-10-16 10:36:47, 2 viewports,
--                                            0 errors. Visual result NOT yet
--                                            reported - it was never looked at
--                                            before the mode was switched away.
--   ref_full   15 effects                     30 writes, 0 errors. SCENE WENT BLACK.
--
-- "blank" is the only remaining option and the only one whose visual result is
-- still unknown. It is verbatim the line ModWorkshop 20568 uses.

local I_EMPTY = Idstring("empty")

-- "deferred" and "ref_full" were shipped as diagnostics on 2026-10-16 and are
-- now REMOVED. ref_full blanked the entire scene to black: it removes the
-- deferred lighting pass, and with it every light in the level. Do not put
-- them back.
--
-- They did prove the one thing worth proving - the writes are real and
-- mutative, not silent no-ops:
--
--   before ref_full:  shadow_processor  [TextureEffectInstanceInterface ...]
--                     deferred          [TextureEffectInstanceInterface ...]
--   after  ref_full:  shadow_processor  nil
--                     deferred          nil
--
-- "empty" DESTROYS the pass rather than hiding it. That is a one-way door: once
-- removed the name no longer resolves, so there is nothing to write back to and
-- no inverse to compute. A game restart is the only restore, which is why
-- R.disable writes nothing.
--
-- So there is exactly one safe thing to try, and it is "blank".

R.MODES = {
	blank = { { kind = "impl", name = "shadow_processor", value = I_EMPTY } },
	hide  = { { kind = "vis",  name = "shadow_processor", value = false } },
}

R.MODE_ORDER = { "blank", "hide" }

R.enabled = R.enabled == true
R.mode    = R.mode or "blank"

R.applied        = nil
R.last_ok        = false
R.errors         = 0
R.viewports      = 0
R.probed         = false

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

-- ---------------------------------------------------------------------------
-- viewports
-- ---------------------------------------------------------------------------

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
-- introspection - read-only, once, on explicit user action only
-- ---------------------------------------------------------------------------
--
-- This is what found the nil-slot bug, so it stays. It only ever reads, and it
-- only indexes the object with method names that are already known to exist on
-- it, because indexing a native object with an unknown key is itself a way to
-- fault.

local function probe_once()
	if R.probed then return end
	local list = viewports()
	if not list then return end
	local vp = list[1]

	local lines = { "--- introspection (read-only) ---" }
	for _, name in ipairs({
		"shadow_processor", "deferred", "post_SSAO", "hdr_post_processor",
		"bloom_combine", "video_anti_alias", "light_adaption",
		"shadow_rendering", "shadow_modifier", "apply_ambient", "deferred_lighting",
	}) do
		local ok, p = pcall(function()
			return vp:get_post_processor_effect("World", Idstring(name))
		end)
		if not ok then
			lines[#lines+1] = string.format("  %-22s ERROR %s", name, tostring(p))
		elseif p == nil then
			lines[#lines+1] = string.format("  %-22s nil", name)
		else
			-- Only these three; they were observed to exist on this object type.
			local found = {}
			for _, m in ipairs({ "modifier", "modifiers", "set_visibility" }) do
				local g, v = pcall(function() return p[m] end)
				if g and type(v) == "function" then found[#found+1] = m end
			end
			lines[#lines+1] = string.format("  %-22s %s  [%s]", name, tostring(p), table.concat(found, ", "))
		end
	end
	lines[#lines+1] = "--- end introspection ---"
	write_log(lines)
	R.probed = true
end

-- ---------------------------------------------------------------------------
-- apply
-- ---------------------------------------------------------------------------
--
-- Only ever reached from a menu callback. There is no hook, no timer and no
-- heartbeat that can call this.

local function apply_impl()
	if not R.enabled then return end
	local mode = R.MODES[R.mode]
	if not mode then return end

	local list = viewports()
	if not list then
		note("apply refused: no viewport")
		return
	end

	-- One apply per explicit action, never a loop over time.
	local ok_count, fail_count, last_err = 0, 0, nil
	for _, vp in ipairs(list) do
		for _, w in ipairs(mode) do
			local ok, err = pcall(function()
				if w.kind == "impl" then
					vp:set_post_processor_effect("World", Idstring(w.name), w.value)
				else
					local p = vp:get_post_processor_effect("World", Idstring(w.name))
					if p then p:set_visibility(w.value) end
				end
			end)
			if ok then ok_count = ok_count + 1 else
				fail_count = fail_count + 1
				last_err = tostring(err)
			end
		end
	end

	R.viewports = #list
	R.last_ok = ok_count > 0
	R.applied = R.mode

	local line = string.format("mode %s: %d ok / %d failed on %d viewport(s)",
		R.mode, ok_count, fail_count, #list)
	if fail_count > 0 then line = line .. " last=" .. tostring(last_err) end
	if ok_count == 0 then
		line = line .. " -- nothing was written; the slot may not resolve"
	end
	note(line)
end

function R.enable()
	R.enabled = true
	probe_once()
	apply_impl()
	R.save()
end

function R.disable()
	R.enabled = false
	-- Deliberately writes nothing. There is no confirmed inverse, and a wrong
	-- one could be worse than leaving it. Restarting rebuilds the tree.
	R.applied = nil
	R.save()
	note("disabled; no inverse written (a restart restores the tree)")
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
	return string.format("enabled=%s mode=%s viewports=%d applied=%s",
		tostring(R.enabled), R.mode, R.viewports, tostring(R.applied))
end

R.load()
-- No apply on load, deliberately. Nothing is written until the player asks.
note(R.enabled
	and ("loaded - enabled, mode " .. R.mode .. " (not applied; flip the toggle to apply)")
	or  ("loaded - idle, mode " .. R.mode))