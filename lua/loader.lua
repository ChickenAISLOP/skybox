-- Registers textures and material configs with the engine at runtime (DB:create_entry)
-- and loads them into the dynamic resource package.
_G.skybox_animated_loader = _G.skybox_animated_loader or {}
local L = _G.skybox_animated_loader

if L._loaded then
	return
end
L._loaded = true

dofile(ModPath .. "lua/util.lua")
local U = _G.skybox_animated_util

local NS = "units/mods/skybox_animated/"
L.TEX_DB = NS .. "textures/"
L.MOD_PATH = ModPath

local INPUT_DIR = ModPath .. "input/dds/"
local GENERATED_DIR = INPUT_DIR .. "generated/"
local VARIANTS_FILE = ModPath .. "data/skyboxes.json"

local IDS_TEXTURE = Idstring("texture")

local RESERVED = { default = true, black = true }

L.problems = {}
L.reg = {}
L.skybox_list = {}

local function problem(msg)
	L.problems[#L.problems + 1] = msg
	log("[skybox_animated] " .. msg)
end

local function sanitize(name)
	return (tostring(name):lower():gsub("[^%w_]", "_"))
end

local function files_in(dir)
	if not file.DirectoryExists(dir) then return {} end
	return file.GetFiles(dir) or {}
end

-- Registering only creates the DB entry; it never triggers a load. Textures are
-- uploaded on demand by ensure_texture_ready, so the main menu pays nothing.
local function register(ids_type, db_path, file_path)
	local ids = Idstring(db_path)
	if not L.reg[db_path] then
		L.reg[db_path] = true
		DB:create_entry(ids_type, ids, file_path)
	end
end

-- One pass over a DDS yields both the cache-busting signature and the format
-- check. Probing a file twice doubled the ~1700 file opens that used to stall
-- the main menu at startup.
local function probe_dds(path)
	local f = io.open(path, "rb")
	if not f then return "missing", "missing" end
	-- Read the header BEFORE seeking for the size. seek("end") leaves the cursor
	-- at EOF, so reading afterwards returns nothing and every file would be
	-- rejected as "not a DDS file".
	local head = f:read(128)
	local size = f:seek("end")
	local parts = { tostring(size) }
	if size > 0 then
		parts[#parts + 1] = head or ""
		if size > 128 then
			f:seek("set", math.floor((size - 128) / 2))
			parts[#parts + 1] = f:read(128) or ""
		end
		f:seek("set", math.max(0, size - 128))
		parts[#parts + 1] = f:read(128) or ""
	end
	f:close()

	if not head or #head < 128 or head:sub(1, 4) ~= "DDS " then
		return table.concat(parts, "|"), "not a DDS file"
	end
	local fourcc = head:sub(85, 88)
	if fourcc ~= "DXT1" and fourcc ~= "DXT5" then
		return table.concat(parts, "|"), "unsupported DDS format '" .. (fourcc:gsub("[^%w]", "?")) .. "', use DXT1 or DXT5"
	end
	local function u32(p)
		local a, b, c, d = head:byte(p, p + 3)
		return a + b * 256 + c * 65536 + d * 16777216
	end
	local h, w = u32(13), u32(17)
	if w % 4 ~= 0 or h % 4 ~= 0 then
		return table.concat(parts, "|"), ("size %dx%d: both sides must be multiples of 4"):format(w, h)
	end
	return table.concat(parts, "|"), nil
end

local probe_cache = {}

local function cached_probe(path)
	local hit = probe_cache[path]
	if hit then return hit[1], hit[2] end
	local sig, why = probe_dds(path)
	probe_cache[path] = { sig, why }
	return sig, why
end

local function suffix(sig)
	local h = 5381
	for i = 1, #sig do
		h = (h * 33 + sig:byte(i)) % 4294967296
	end
	return ("%08x"):format(h)
end

-- Registering a texture only creates the DB entry. It is deliberately NOT
-- queued for loading: uploading every skybox to the GPU while the player sits in
-- the main menu was the source of the menu lag. The selected skybox is loaded on
-- demand by ensure_texture_ready once a heist is actually running.
local function register_texture(db_kind, file_path)
	local sig = cached_probe(file_path)
	local db = L.TEX_DB .. db_kind .. "_" .. suffix(sig)
	register(IDS_TEXTURE, db, file_path)
	return db
end

local function dds_problem(path)
	local _, why = cached_probe(path)
	return why
end

local function skybox_meta()
	local meta = {}
	for _, s in ipairs(U.read_json(VARIANTS_FILE).skyboxes or {}) do
		if s.id then meta[s.id] = s end
	end
	return meta
end

local function make_skybox(id, meta, base, glow, cubemap)
	local m = meta[id] or {}
	return {
		id = id,
		name = m.name or id,
		base = base,
		glow = glow,
		cubemap = cubemap,
	}
end

local function scan_input()
	local files = {}
	-- Root DDS files remain supported. Fresh generator outputs use their exact
	-- source basename in generated/ and take precedence over matching root files.
	for _, dir in ipairs({ INPUT_DIR, GENERATED_DIR }) do
		for _, name in ipairs(files_in(dir)) do
			files[#files + 1] = { name = name, path = dir .. name, generated = dir == GENERATED_DIR }
		end
	end
	table.sort(files, function(a, b)
			if a.generated ~= b.generated then return not a.generated end
			return a.name < b.name
		end)
	local sets, order = {}, {}
	for _, entry in ipairs(files) do
		local f = entry.name
		local base, ext = f:match("^(.+)%.(%w+)$")
		ext = ext and ext:lower()
		if ext == "png" then
			problem("input/dds/" .. f .. " ignored: convert it to DDS or PAYDAY .texture format first")
		end
		if base and (ext == "dds" or ext == "texture") then
			local tail = base:lower():sub(-3)
			local key, kind
			if #base > 3 and (tail == "_df" or tail == "_il" or tail == "_cm") then
				key, kind = base:sub(1, -4), tail:sub(2)
			else
				key, kind = base, "plain"
			end
			if not sets[key] then
				sets[key] = {}
				order[#order + 1] = key
			end
			sets[key][kind] = entry.path
		end
	end

	local found = {}
	for _, name in ipairs(order) do
		local p = sets[name]
		if p.df then
			found[#found + 1] = { name = name, df = p.df, il = p.il, cm = p.cm }
		elseif p.plain and not p.df and not p.il and not p.cm then
			found[#found + 1] = { name = name, df = p.plain, il = p.plain, cm = p.plain }
		else
			problem("input '" .. name .. "' ignored: needs a diffuse _df texture or a plain DDS")
		end
	end
	return found
end

local function register_input(ids_out)
	for _, entry in ipairs(scan_input()) do
		local id = sanitize(entry.name)
		local why = RESERVED[id] and "name is reserved, please rename the files"
			or dds_problem(entry.df)
			or (entry.il and dds_problem(entry.il))
			or (entry.cm and dds_problem(entry.cm))
		if why then
			problem(entry.name .. ": " .. why)
		else
			local base = register_texture(id .. "_df", entry.df)
			local glow = entry.il and register_texture(id .. "_il", entry.il) or nil
			local cube = entry.cm and register_texture(id .. "_cubemap", entry.cm) or nil
			ids_out[id] = { base = base, glow = glow, cubemap = cube }
		end
	end
end

function L.skyboxes()
	return L.skybox_list
end

-- The mod does no scanning or loading while sitting in the menus. Everything is
-- deferred until a heist actually starts, which keeps the main menu responsive.
function L.in_heist()
	return not not (Global and Global.level_data and Global.level_data.level_id)
end

-- Load exactly one texture, on demand, and only while a heist is running. This
-- is the only path that uploads sky textures; the scan itself never does.
function L.ensure_texture_ready(db_path)
	if not db_path then return false end
	if not L.in_heist() then return false end
	local dyn = managers and managers.dyn_resource
	local package = DynamicResourceManager and DynamicResourceManager.DYN_RESOURCES_PACKAGE
	if not (dyn and package) then return false end
	local ids = Idstring(db_path)
	if dyn:is_resource_ready(IDS_TEXTURE, ids, package) then return true end
	L.requested = L.requested or {}
	if L.requested[db_path] then return false end
	L.requested[db_path] = true
	managers.dyn_resource:load(IDS_TEXTURE, ids, package)
	L.requested_count = (L.requested_count or 0) + 1
	return false
end


function L.rescan()
	-- Drop cached probes so regenerated DDS files are picked up.
	probe_cache = {}
	local textures = {}
	-- This mod is intentionally limited to input/dds/ and its generated/ child.
	-- Do not expose or generate configs for the game's bundled sky textures.
	register_input(textures)

	local meta = skybox_meta()
	local list = {}
	for id, t in pairs(textures) do
		list[#list + 1] = make_skybox(id, meta, t.base, t.glow, t.cubemap)
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	L.skybox_list = list
	log("[skybox_animated] rescan " .. #L.skybox_list .. " skyboxes")

	-- Material configs were removed: Underlay does not expose
	-- Unit:set_material_config, so the engine rejected every generated config
	-- and the work was dead. Textures are applied directly instead.
	-- Deliberately no start_loading() here: the scan only registers DB entries so
	-- the menu lists are populated. Textures load on demand inside a heist via
	-- ensure_texture_ready, which keeps the main menu free of GPU uploads.
	L._scanned = true
end

-- Scanning is done once at load. The menu builds skybox choice lists from this
-- data, so it must be populated before any menu is built; deferring it left the
-- lists empty and crashed the multiple-choice item. It is cheap now that the
-- animation frames are gone (only the static DDS files are probed).
L._scanned = false
L._active = false

function L.ensure_scanned()
	if L._scanned then return end
	L._scanned = true
	L.rescan()
end

function L.activate()
	L._active = true
	L.ensure_scanned()
end

function L.deactivate()
	L._active = false
end

Hooks:Add("GameSetupUpdate", "skybox_animated_activate_in_heist", function()
	if L._active or not L.in_heist() then return end
	L.activate()
end)

-- Scan at load so the skybox choice lists are populated before any menu builds.
L.ensure_scanned()

Hooks:Add("MenuManagerOnOpenMenu", "skybox_animated_scan_for_menu", function(menu_manager, menu_name)
	if menu_name == "skybox_animated_options" then L.ensure_scanned() end
end)
