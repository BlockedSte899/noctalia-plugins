#!/usr/bin/env bash
# Read-only integration test against the current Noctalia configuration.
set -eu
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d "${TMPDIR:-/tmp}/nix-config-generator-test.XXXXXXXX")"
trap 'rm -rf -- "$dir"' EXIT
cp -R "$root/lib" "$dir/lib"
noctalia config export merged --credentials omit > "$dir/input.toml"
python3 - "$dir" <<'PY'
from pathlib import Path
import os, sys
root = Path(sys.argv[1])
text = (root / "input.toml").read_text()
for n in range(1, 100):
    eq = "=" * n
    if f"]{eq}]" not in text:
        (root / "fixture.luau").write_text(f"return [{eq}[{text}]{eq}]\n")
        break
else:
    raise RuntimeError("Could not quote TOML fixture")
home = os.environ["HOME"]
for n in range(1, 100):
    eq = "=" * n
    if f"]{eq}]" not in home:
        (root / "home.luau").write_text(f"return [{eq}[{home}]{eq}]\n")
        break
else:
    raise RuntimeError("Could not quote home directory")
PY
cat > "$dir/run.luau" <<'LUA'
local toml = require("./lib/toml")
local nix = require("./lib/nix")
local filter = require("./lib/filter")
local pathRewrite = require("./lib/path-rewrite")
local text = require("./fixture")
local parsed, err = toml.parse(text)
assert(parsed, err)
local auto = filter.partition(parsed, filter.compilePatterns({"calendar.account"}))
local home = require("./home")
print(nix.render(pathRewrite.apply(auto, home, "~")))
LUA
luau "$dir/run.luau" > "$dir/output.nix"
nix-instantiate --parse "$dir/output.nix" >/dev/null
nix-instantiate --eval --strict --json "$dir/output.nix" > "$dir/output.json"
python3 - "$dir" <<'PY'
import json, os, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
expected = tomllib.loads((root / "input.toml").read_text())
if "calendar" in expected:
    expected["calendar"].pop("account", None)
    if not expected["calendar"]:
        expected.pop("calendar")
actual = json.loads((root / "output.json").read_text())
home = os.environ["HOME"].rstrip("/")
def rewrite(value, path=()):
    if isinstance(value, dict):
        return {k: rewrite(v, path + (k,)) for k, v in value.items()}
    if isinstance(value, list):
        return [rewrite(v, path) for v in value]
    if isinstance(value, str) and not (path[:2] == ("plugin_settings", "blockedste899/nix-config-generator") and path[-1:] in (("path_prefix_from",), ("path_prefix_to",)) and len(path) == 3):
        if value == home or value.startswith(home + "/"):
            return "~" + value[len(home):]
    return value
expected = rewrite(expected)
assert expected == actual, "The generated Nix does not match the filtered export"
print("Live merged export matches generated Nix, with exclusions and home prefix replacement")
PY
