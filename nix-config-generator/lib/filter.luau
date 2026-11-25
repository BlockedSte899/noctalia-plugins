--!nonstrict
-- Splits one parsed config tree into "auto" and "manual" trees by dotted patterns.
-- A pattern is a list of dotted segments; `*` matches one segment, `**` matches any
-- number of them. A pattern that ends before the path does still cover the subtree,
-- so `calendar` and `calendar.*` both exclude everything under `calendar`.

local M = {}

local function newTable()
	return { t = "table", map = {}, keys = {} }
end

function M.compilePatterns(list)
	local patterns = {}
	for _, p in list or {} do
		local segs = {}
		local text = string.match(tostring(p), "^%s*(.-)%s*$")
		local seg = ""
		local i = 1
		while i <= #text do
			local c = string.sub(text, i, i)
			if c == "\\" then
				i += 1
				if i > #text then error("Trailing escape in exclusion path: " .. text) end
				seg ..= string.sub(text, i, i)
			elseif c == "." then
				if seg == "" then error("Empty segment in exclusion path: " .. text) end
				table.insert(segs, seg)
				seg = ""
			else
				seg ..= c
			end
			i += 1
		end
		if text ~= "" then
			if seg == "" then error("Empty segment in exclusion path: " .. text) end
			table.insert(segs, seg)
			table.insert(patterns, segs)
		end
	end
	return patterns
end

-- An array cannot safely be split into auto/manual parts. Refuse an exclusion
-- that could reach inside it instead of accidentally exporting its contents.
local function canDescend(pattern, pi, path, si)
	if si > #path then return pi <= #pattern end
	if pi > #pattern then return false end
	if pattern[pi] == "**" then
		return canDescend(pattern, pi + 1, path, si) or canDescend(pattern, pi, path, si + 1)
	end
	if pattern[pi] == "*" or pattern[pi] == path[si] then
		return canDescend(pattern, pi + 1, path, si + 1)
	end
	return false
end

local function matchFrom(pattern, pi, path, si)
	if pi > #pattern then
		return true
	end
	local seg = pattern[pi]
	if seg == "**" then
		if matchFrom(pattern, pi + 1, path, si) then
			return true
		end
		if si <= #path then
			return matchFrom(pattern, pi, path, si + 1)
		end
		return false
	end
	if si > #path then
		return false
	end
	if seg == "*" or seg == path[si] then
		return matchFrom(pattern, pi + 1, path, si + 1)
	end
	return false
end

function M.matches(patterns, path)
	for _, pattern in patterns do
		if matchFrom(pattern, 1, path, 1) then
			return true
		end
	end
	return false
end

local function insertPath(root, path, node)
	local current = root
	for i = 1, #path - 1 do
		local key = path[i]
		if current.map[key] == nil or current.map[key].t ~= "table" then
			current.map[key] = newTable()
			table.insert(current.keys, key)
		end
		current = current.map[key]
	end
	local last = path[#path]
	if current.map[last] == nil then
		table.insert(current.keys, last)
	end
	current.map[last] = node
end

-- Arrays (including [[arrays of tables]]) are atomic.
local function walk(node, path, auto, excluded, patterns, stats, checkpoint)
	if #node.keys == 0 then
		if #path == 0 then return end
		local target = M.matches(patterns, path) and excluded or auto
		insertPath(target, path, node)
		stats.values += 1
		return
	end
	for _, key in node.keys do
		if checkpoint then
			checkpoint()
		end
		local child = node.map[key]
		if child.special then
			error("Unsupported TOML value at " .. table.concat(path, ".") .. "." .. key)
		else
			local childPath = table.clone(path)
			table.insert(childPath, key)
			if child.t == "table" and #child.keys > 0 then
				walk(child, childPath, auto, excluded, patterns, stats, checkpoint)
			else
				local isExcluded = M.matches(patterns, childPath)
				if child.t == "array" and not isExcluded then
					for _, pattern in patterns do
						if canDescend(pattern, 1, childPath, 1) then
							error("Exclusion descends into an array; exclude the whole array: " .. table.concat(childPath, "."))
						end
					end
				end
				insertPath(isExcluded and excluded or auto, childPath, child)
				if isExcluded then
					stats.excluded += 1
				else
					stats.values += 1
				end
			end
		end
	end
end

-- Returns autoRoot, excludedRoot, stats. The original tree is left untouched; scalar
-- and array nodes are shared between the two results (the renderer only reads them).
function M.partition(root, patterns, checkpoint)
	local auto = newTable()
	local excluded = newTable()
	local stats = { values = 0, excluded = 0, skipped = 0 }
	walk(root, {}, auto, excluded, patterns, stats, checkpoint)
	return auto, excluded, stats
end

return M
