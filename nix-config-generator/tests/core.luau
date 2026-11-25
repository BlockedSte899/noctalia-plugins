local toml = require("../lib/toml")
local nix = require("../lib/nix")
local filter = require("../lib/filter")

local source = [=[
[bar.default]
center = ["group:g1"]
[[bar.default.capsule_group]]
id = "g1"
members = ["cpu", "ram"]
[calendar]
enabled = true
[calendar.account.personal]
server_url = "https://example.test"
password_file = "/run/agenix/caldav"
[plugin_settings."owner/plugin.name"]
password = "must-not-appear"
enabled = true
[theme]
mode = "dark"
]=]

local tree, err = toml.parse(source)
assert(tree, err)
local patterns = filter.compilePatterns({
	"calendar.account",
	"plugin_settings.owner/plugin\\.name.password",
})
local auto, excluded, stats = filter.partition(tree, patterns)
local out = nix.render(auto)
assert(string.find(out, "capsule_group", 1, true))
assert(string.find(out, "enabled = true", 1, true))
assert(not string.find(out, "example.test", 1, true))
assert(not string.find(out, "must-not-appear", 1, true))
assert(excluded.map.calendar and excluded.map.plugin_settings)
assert(stats.excluded == 3)
assert(filter.matches(filter.compilePatterns({ "calendar.**.password" }), { "calendar", "account", "a", "password" }))
assert(not filter.matches(filter.compilePatterns({ "calendar.*.password" }), { "calendar", "account", "a", "password" }))
assert(not pcall(filter.compilePatterns, { "calendar..account" }))
assert(not pcall(filter.partition, tree, filter.compilePatterns({ "bar.default.capsule_group.members" })))
local withoutArray = filter.partition(tree, filter.compilePatterns({ "bar.default.capsule_group" }))
assert(not string.find(nix.render(withoutArray), "capsule_group", 1, true))
local bad = assert(toml.parse("test = [nan]\n"))
assert(not pcall(nix.render, bad))
local nestedBad = assert(toml.parse("test = [{ value = nan }]\n"))
assert(not pcall(nix.render, nestedBad))
local empty = filter.partition(assert(toml.parse("")), {})
assert(nix.render(empty) == "{ }")
print("core tests passed")
