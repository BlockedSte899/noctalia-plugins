local toml = require("../lib/toml")
local nix = require("../lib/nix")
local filter = require("../lib/filter")
local pathRewrite = require("../lib/path-rewrite")

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
local paths = assert(toml.parse([=[
" /home/nikita/key" = "/home/nikita"
items = ["/home/nikita/a", "/home/nikita2/a", "prefix /home/nikita/a", "/home/nikita"]
[[entries]]
path = "/home/nikita/space \"and ${text}\""
[plugin_settings."blockedste899/nix-config-generator"]
path_prefix_from = "/home/nikita"
path_prefix_to = "/home/nikita/other"
target_path = "/home/nikita/config"
]=]))
local original = nix.render(paths)
local rewritten = pathRewrite.apply(paths, "/home/nikita/", "~/")
assert(rewritten.map.items.items[1].v == "~/a")
assert(rewritten.map.items.items[2].v == "/home/nikita2/a")
assert(rewritten.map.items.items[3].v == "prefix /home/nikita/a")
assert(rewritten.map.items.items[4].v == "~")
assert(rewritten.map[" /home/nikita/key"].v == "~")
assert(rewritten.map.entries.items[1].map.path.v == '~/space "and ${text}"')
local plugin = rewritten.map.plugin_settings.map["blockedste899/nix-config-generator"].map
assert(plugin.path_prefix_from.v == "/home/nikita")
assert(plugin.path_prefix_to.v == "/home/nikita/other")
assert(plugin.target_path.v == "~/config")
assert(nix.render(paths) == original)
assert(string.find(nix.render(rewritten), [[\${text}]], 1, true))
assert(not pcall(pathRewrite.apply, paths, "", "~"))
assert(not pcall(pathRewrite.apply, paths, "/", "~"))
assert(not pcall(pathRewrite.apply, paths, "relative", "~"))
assert(not pcall(pathRewrite.apply, paths, "/home/nikita", ""))
assert(pathRewrite.apply(paths, "/home/nikita", "/").map.items.items[1].v == "/a")
print("core tests passed")
