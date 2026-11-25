--!nonstrict
-- Control-center tile: click opens the panel, right-click exports immediately.

local STATUS_KEY = "nix_config_generator.status"
local COMMAND_KEY = "nix_config_generator.command"

local status = noctalia.state.get(STATUS_KEY) or {}

local function render()
	local failed = status.error ~= nil and status.error ~= ""
	shortcut.setIcon(failed and "alert-triangle" or "file-code")
	if failed then
		shortcut.setLabel(noctalia.tr("shortcut.error"))
	elseif status.pending then
		shortcut.setLabel(noctalia.tr("shortcut.pending"))
	else
		shortcut.setLabel(noctalia.tr("shortcut.label"))
	end
	shortcut.setActive(failed)
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

function onClick()
	noctalia.togglePanel("local/nix-config-generator:panel")
end

function onRightClick()
	noctalia.state.set(COMMAND_KEY, { action = "export", nonce = tostring(noctalia.nowMs()) })
end

render()
