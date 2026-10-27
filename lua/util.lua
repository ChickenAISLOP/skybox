_G.skybox_animated_util = _G.skybox_animated_util or {}
local U = _G.skybox_animated_util

if U._loaded then
	return
end
U._loaded = true

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
	if type(json) ~= "table" or type(json.decode) ~= "function" then return {} end
	local data = json.decode(text)
	if type(data) == "table" then return data end
	return {}
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

-- Deep copy
function U.copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = U.copy(v) end
	return out
end