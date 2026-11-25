--!nonstrict
-- Watches every source of `noctalia config export` (settings.toml, *.toml in the config
-- dir, the generated file and this plugin's own settings) and regenerates one Nix file.

local exporter = require("./lib/export.luau")

local STATUS_KEY = "nix_config_generator.status"
local COMMAND_KEY = "nix_config_generator.command"

local lastSignature = nil
local busy = false
local pendingManual = false

local RETRY_FIRST = 5
local RETRY_MAX = 300
local failures = 0
local retryAt = nil

local SLICE = 0.006
local IDLE_INTERVAL = 2000
local FAST_INTERVAL = 50
local job = nil
local sliceEnd = 0

local function config()
	return exporter.config()
end

local function checkpoint()
	if os.clock() > sliceEnd then
		coroutine.yield()
	end
end

local function fileSignature(path)
	local info = path and noctalia.fileInfo(path)
	if not info then
		return "-"
	end
	-- mtime is only second-resolution. Include contents to catch same-size edits
	-- made within the same second; signatures stay in memory and are never logged.
	local content = noctalia.readFile(path)
	return `{info.mtime}:{info.size}:` .. (content or "<unreadable>")
end

local function signature(cfg)
	local parts = {
		fileSignature(exporter.settingsPath()),
		noctalia.json.encode(cfg) or "",
	}
	local dir = exporter.configDir()
	local entries = noctalia.listDir(dir) or {}
	table.sort(entries)
	for _, name in entries do
		if string.match(name, "%.toml$") then
			table.insert(parts, fileSignature(dir .. "/" .. name))
		end
	end
	local target = exporter.targetPath(cfg.target)
	if target then
		table.insert(parts, fileSignature(target))
	end
	return table.concat(parts, "|")
end

local function publish(plan, err)
	noctalia.state.set(STATUS_KEY, {
		pending = plan ~= nil and plan.content ~= plan.current,
		target = plan and plan.target or "",
		values = plan and plan.stats.values or 0,
		excluded = plan and plan.stats.excluded or 0,
		error = err or "",
	})
end

local function succeeded(inputSignature)
	failures = 0
	retryAt = nil
	lastSignature = inputSignature
end

local function failed(err, manual)
	failures += 1
	retryAt = os.time() + math.min(RETRY_FIRST * 2 ^ (failures - 1), RETRY_MAX)
	noctalia.log(`nix-config-generator: export failed (attempt {failures}): {err}`)
	if manual or failures == 1 then
		noctalia.notifyError(noctalia.tr("notify.failed_title"), err)
	end
end

local function write(plan, manual, inputSignature)
	busy = true
	exporter.write(plan, function(ok, writeErr)
		busy = false
		if not ok then
			publish(nil, writeErr)
			failed(writeErr, manual)
			return
		end
		succeeded(inputSignature)
		plan.current = plan.content
		publish(plan)
		if manual then
			noctalia.notify(
				noctalia.tr("notify.done_title"),
				noctalia.trp("notify.done_body", plan.stats.values, {
					path = plan.target,
					count = plan.stats.values,
					excluded = plan.stats.excluded,
				})
			)
		end
	end)
end

local function finish(plan, err, manual, inputSignature)
	publish(plan, err)
	if not plan then
		failed(err, manual)
	elseif plan.content ~= plan.current then
		write(plan, manual, inputSignature)
	else
		succeeded(inputSignature)
		if manual then
			noctalia.notify(noctalia.tr("notify.unchanged_title"), noctalia.tr("notify.unchanged_body", { path = plan.target }))
		end
	end
end

local function step()
	sliceEnd = os.clock() + SLICE
	local ok, plan, err = coroutine.resume(job.co)
	if coroutine.status(job.co) ~= "dead" then
		return
	end
	local manual = job.manual
	local inputSignature = job.inputSignature
	job = nil
	if not ok then
		plan, err = nil, tostring(plan)
	end
	finish(plan, err, manual, inputSignature)
end

local function start(manual)
	if job then
		job.manual = job.manual or manual
		return
	end
	if busy then
		pendingManual = pendingManual or manual
		return
	end
	local cfg = config()
	local inputSignature = signature(cfg)
	busy = true
	exporter.fetch(cfg, function(text, err)
		busy = false
		if pendingManual then
			manual = true
			pendingManual = false
		end
		if not text then
			publish(nil, err)
			failed(err, manual)
			return
		end
		job = {
			manual = manual,
			inputSignature = inputSignature,
			co = coroutine.create(function()
				return exporter.plan(cfg, text, checkpoint)
			end),
		}
		step()
	end)
end

function update()
	if job then
		step()
	elseif not busy then
		local cfg = config()
		local current = signature(cfg)
		if current ~= lastSignature then
			lastSignature = current
			start(false)
		elseif retryAt ~= nil and os.time() >= retryAt then
			retryAt = nil
			start(false)
		end
	end
	noctalia.setUpdateInterval((job or busy) and FAST_INTERVAL or IDLE_INTERVAL)
end

function onConfigChanged()
	lastSignature = nil
	update()
end

function onIpc(event, _payload)
	if event == "export" then
		start(true)
	end
end

noctalia.state.watch(COMMAND_KEY, function(value)
	if type(value) == "table" then
		onIpc(value.action, nil)
	end
end)

update()
