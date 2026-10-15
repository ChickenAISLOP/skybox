_G.skybox_animated_util = _G.skybox_animated_util or {}
local U = _G.skybox_animated_util

if U.materials then
	return
end

function U.read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*all")
	f:close()
	return data
end

function U.read_json(path)
	local text = U.read(path)
	if not text then return {} end
	local ok, data = pcall(json.decode, text)
	if ok and type(data) == "table" then return data end
	return {}, true
end

function U.write_json(path, data)
	local f = io.open(path, "w+")
	if f then
		f:write(json.encode(data))
		f:close()
		return true
	end
	return false
end

function U.attrs(s)
	local out = {}
	for k, v in s:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do out[#out + 1] = { k, v } end
	return out
end

function U.attr(list, key)
	for _, kv in ipairs(list) do
		if kv[1] == key then return kv[2] end
	end
end

function U.materials(text)
	local list, pos = {}, 1
	while true do
		local s, e, attrs = text:find("<material%s+([^>]-)>", pos)
		if not s then break end
		local body = ""
		if attrs:sub(-1) == "/" then
			pos = e + 1
		else
			local cs, ce = text:find("</material>", e + 1, true)
			if not cs then break end
			body = text:sub(e + 1, cs - 1)
			pos = ce + 1
		end
		local children = {}
		for tag, cattrs in body:gmatch("<([%w_]+)%s+([^>]-)/?>") do
			children[#children + 1] = { tag = tag, attrs = U.attrs(cattrs) }
		end
		list[#list + 1] = { attrs = U.attrs(attrs), children = children }
	end
	return list
end

function U.sanitize(name)
	return (tostring(name):lower():gsub("[^%w_]", "_"))
end

-- Vector helpers
function U.vec3(x, y, z)
	return { x = x or 0, y = y or 0, z = z or 0 }
end

function U.vec3_to_string(v)
	return string.format("%.6f %.6f %.6f", v.x or 0, v.y or 0, v.z or 0)
end

-- Deep copy
function U.copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = U.copy(v) end
	return out
end

-- Merge tables
function U.merge(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" and type(dst[k]) == "table" then
			U.merge(dst[k], v)
		else
			dst[k] = v
		end
	end
	return dst
end