--!nonstrict
-- Builds one Nix file from `noctalia config export merged` (or `full`), minus the
-- paths the user listed in exclude_paths. Manual settings are managed separately.

local toml = require("./toml.luau")
local nix = require("./nix.luau")
local filter = require("./filter.luau")
local pathRewrite = require("./path-rewrite.luau")

local M = {}

-- Part of the first line of every generated file; an existing target without it is
-- never overwritten.
local MARKER = "blockedste899/nix-config-generator"
local LEGACY_MARKERS = { "local/nix-config-generator", "local/selective-nix-auto-v2" }
local MARKER_DIR = "nix-config-generator"
local COMMAND_TIMEOUT_MS = 30000

function M.config()
	return {
		target = noctalia.getConfig("target_path"),
		exclude = noctalia.getConfig("exclude_paths") or { "calendar.account" },
		mode = noctalia.getConfig("export_mode") or "merged",
		rewrite_paths = noctalia.getConfig("rewrite_paths") == true,
		path_prefix_from = noctalia.getConfig("path_prefix_from") or "~",
		path_prefix_to = noctalia.getConfig("path_prefix_to") or "~",
	}
end

-- Same lookup as Noctalia's FileUtils::stateDir() / configDir().
function M.settingsPath()
	for _, var in { "NOCTALIA_STATE_HOME", "XDG_STATE_HOME" } do
		local dir = noctalia.getenv(var)
		if dir and dir ~= "" then
			return dir .. "/noctalia/settings.toml"
		end
	end
	return noctalia.expandPath("~/.local/state/noctalia/settings.toml")
end

function M.configDir()
	for _, var in { "NOCTALIA_CONFIG_HOME", "XDG_CONFIG_HOME" } do
		local dir = noctalia.getenv(var)
		if dir and dir ~= "" then
			return dir .. "/noctalia"
		end
	end
	return noctalia.expandPath("~/.config/noctalia")
end

function M.targetPath(raw)
	raw = noctalia.string.trim(tostring(raw or ""))
	if raw == "" then
		return nil
	end
	return noctalia.expandPath(raw)
end

local function splitPath(path)
	local dir, name = string.match(path, "^(.*)/([^/]*)$")
	return (dir == "" and "/" or dir), name or path
end

-- fileExists() follows symlinks; the listing also reveals a dangling one.
function M.pathExistsLoose(path)
	if noctalia.fileExists(path) then
		return true
	end
	local dir, name = splitPath(path)
	if not noctalia.fileExists(dir) then
		return false
	end
	local entries = noctalia.listDir(dir)
	return entries ~= nil and table.find(entries, name) ~= nil
end

function M.inspectTarget(target)
	local present = M.pathExistsLoose(target)
	if not present then
		return nil
	end
	local info, infoErr = noctalia.fileInfo(target)
	if not info then
		return nil, noctalia.tr("errors.unverifiable", { path = target, error = tostring(infoErr) })
	end
	if info.isDir then
		return nil, noctalia.tr("errors.foreign", { path = target })
	end
	local text, readErr = noctalia.readFile(target)
	if not text then
		return nil, noctalia.tr("errors.unverifiable", { path = target, error = tostring(readErr) })
	end
	local firstLine = string.match(text, "^[^\n]*") or ""
	local recognized = string.find(firstLine, MARKER, 1, true) ~= nil
	for _, marker in LEGACY_MARKERS do
		recognized = recognized or string.find(firstLine, marker, 1, true) ~= nil
	end
	if not recognized then
		return nil, noctalia.tr("errors.foreign", { path = target })
	end
	return text
end

-- Runs the same CLI the user runs by hand, so the result really is the merged config
-- the shell uses. `done(stdout)` or `done(nil, err)`.
function M.fetch(cfg, done)
	if not noctalia.commandExists("noctalia") then
		return done(nil, noctalia.tr("errors.no_noctalia"))
	end
	if cfg.mode ~= "merged" and cfg.mode ~= "full" then
		return done(nil, "Invalid export mode")
	end
	local args = { "noctalia", "config", "export", cfg.mode, "--credentials", "omit" }
	local started = noctalia.runAsync(args, function(result)
		if result.timedOut then
			return done(nil, noctalia.tr("errors.timeout", { command = "noctalia config export" }))
		end
		if result.exitCode ~= 0 then
			return done(nil, noctalia.tr("errors.export_failed", { error = noctalia.string.trim(result.stderr or "") }))
		end
		if result.stdoutTruncated then
			return done(nil, "Noctalia export output was truncated; refusing to write")
		end
		done(result.stdout or "")
	end, COMMAND_TIMEOUT_MS)
	if not started then
		done(nil, noctalia.tr("errors.export_failed", { error = "could not start noctalia config export" }))
	end
end

local function header(cfg)
	return table.concat({
		"# " .. MARKER .. " — AUTO-GENERATED from `noctalia config export " .. cfg.mode .. "`; do not edit.",
		"# Credentials recognized by Noctalia are omitted. Manage excluded paths separately.",
		"#",
		"",
	}, "\n")
end

-- Returns { content, current, target, stats } or nil, err.
function M.plan(cfg, text, checkpoint)
	local target = M.targetPath(cfg.target)
	if not target then
		return nil, noctalia.tr("errors.no_target")
	end
	local current, targetErr = M.inspectTarget(target)
	if targetErr then
		return nil, targetErr
	end

	local parsed, parseErr = toml.parse(text or "", checkpoint)
	if not parsed then
		return nil, noctalia.tr("errors.parse", { path = "noctalia config export", error = parseErr })
	end

	local auto, _, stats = filter.partition(parsed, filter.compilePatterns(cfg.exclude), checkpoint)
	if cfg.rewrite_paths then
		local from = noctalia.expandPath(cfg.path_prefix_from)
		auto = pathRewrite.apply(auto, from, cfg.path_prefix_to, checkpoint)
	end
	local content = header(cfg) .. nix.render(auto, "", checkpoint) .. "\n"

	return {
		content = content,
		current = current,
		target = target,
		stats = stats,
	}
end

-- Write via a temporary file and atomic rename.
function M.write(plan, done)
	local target = plan.target
	local dir, name = splitPath(target)
	local ok, err = noctalia.mkdirAll(dir)
	if not ok then
		return done(false, noctalia.tr("errors.write", { path = dir, error = tostring(err) }))
	end

	local prefix = dir .. "/." .. MARKER_DIR .. "."
	local started = noctalia.runAsync({ "mktemp", "-d", prefix .. "XXXXXX" }, function(made)
		local tmpDir = noctalia.string.trim(made.stdout or "")
		if made.exitCode ~= 0 or string.sub(tmpDir, 1, #prefix) ~= prefix or string.find(tmpDir, "/", #prefix + 1, true) then
			local reason = made.timedOut and "mktemp timed out" or noctalia.string.trim(made.stderr or "")
			return done(false, noctalia.tr("errors.write", { path = dir, error = reason ~= "" and reason or "mktemp failed" }))
		end
		local tmp = tmpDir .. "/" .. name

		local function finish(success, message)
			if noctalia.fileExists(tmp) then
				noctalia.removeFile(tmp)
			end
			noctalia.runAsync({ "rmdir", tmpDir })
			done(success, message)
		end

		local written, writeErr = noctalia.writeFile(tmp, plan.content)
		if not written then
			return finish(false, noctalia.tr("errors.write", { path = tmp, error = tostring(writeErr) }))
		end

		local function commit()
			local _, targetErr = M.inspectTarget(target)
			if targetErr then
				return finish(false, targetErr)
			end
			local renamed, renameErr = noctalia.renameFile(tmp, target)
			if not renamed then
				return finish(false, noctalia.tr("errors.write", { path = target, error = tostring(renameErr) }))
			end
			finish(true)
		end

		if not noctalia.commandExists("nix-instantiate") then
			return commit()
		end
		local checking = noctalia.runAsync({ "nix-instantiate", "--parse", tmp }, function(result)
			if result.timedOut then
				return finish(false, noctalia.tr("errors.timeout", { command = "nix-instantiate --parse" }))
			end
			if result.exitCode ~= 0 then
				return finish(false, noctalia.tr("errors.invalid", { error = noctalia.string.trim(result.stderr or "") }))
			end
			commit()
		end, COMMAND_TIMEOUT_MS)
		if not checking then
			commit()
		end
	end, COMMAND_TIMEOUT_MS)
	if not started then
		done(false, noctalia.tr("errors.write", { path = dir, error = "could not start mktemp" }))
	end
end

return M
