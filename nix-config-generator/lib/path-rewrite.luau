--!nonstrict
-- Rewrite values, never TOML keys. Return a new tree without changing the input.
local M = {}

function M.validate(from, to)
	if type(from) ~= "string" or from == "" or string.sub(from, 1, 1) ~= "/" then
		error("Path prefix must be a non-empty absolute path")
	end
	while #from > 1 and string.sub(from, -1) == "/" do
		from = string.sub(from, 1, -2)
	end
	if from == "/" then
		error("The root directory cannot be used as a path prefix")
	end
	if type(to) ~= "string" or to == "" then
		error("Replacement path prefix must not be empty")
	end
	while #to > 1 and string.sub(to, -1) == "/" do
		to = string.sub(to, 1, -2)
	end
	return from, to
end

local function rewrite(node, path, from, to, checkpoint)
	if checkpoint then checkpoint() end
	if node.t == "table" then
		local result = table.clone(node)
		result.map = table.clone(node.map)
		for _, key in node.keys do
			local childPath = table.clone(path)
			table.insert(childPath, key)
			result.map[key] = rewrite(node.map[key], childPath, from, to, checkpoint)
		end
		return result
	elseif node.t == "array" then
		local result = table.clone(node)
		result.items = {}
		for _, item in node.items do
			table.insert(result.items, rewrite(item, path, from, to, checkpoint))
		end
		return result
	elseif node.t == "string" then
		-- This is the rule itself, not a path to rewrite: changing it would
		-- silently alter the configured rule on the next Home Manager activation.
		if #path == 3 and path[1] == "plugin_settings"
			and path[2] == "blockedste899/nix-config-generator"
			and (path[3] == "path_prefix_from" or path[3] == "path_prefix_to") then
			return node
		end
		local value = node.v
		if string.sub(value, 1, #from) == from
			and (#value == #from or string.sub(value, #from + 1, #from + 1) == "/") then
			local suffix = string.sub(value, #from + 1)
			if to == "/" and suffix ~= "" then suffix = string.sub(suffix, 2) end
			local result = table.clone(node)
			result.v = to .. suffix
			return result
		end
	end
	return node
end

function M.apply(root, from, to, checkpoint)
	from, to = M.validate(from, to)
	return rewrite(root, {}, from, to, checkpoint)
end

return M
