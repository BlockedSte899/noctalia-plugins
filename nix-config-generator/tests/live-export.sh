#!/usr/bin/env bash
# Read-only integration test against the current Noctalia configuration.
set -eu
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d "${TMPDIR:-/tmp}/selective-nix-test.XXXXXXXX")"
trap 'rm -rf -- "$dir"' EXIT
cp -R "$root/lib" "$dir/lib"
noctalia config export merged --credentials omit > "$dir/input.toml"
python3 - "$dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
text = (root / "input.toml").read_text()
for n in range(1, 100):
    eq = "=" * n
    if f"]{eq}]" not in text:
        (root / "fixture.luau").write_text(f"return [{eq}[{text}]{eq}]\n")
        break
else:
    raise RuntimeError("Could not quote TOML fixture")
PY
cat > "$dir/run.luau" <<'LUA'
local toml = require("./lib/toml")
local nix = require("./lib/nix")
local filter = require("./lib/filter")
local text = require("./fixture")
local parsed, err = toml.parse(text)
assert(parsed, err)
local auto = filter.partition(parsed, filter.compilePatterns({"calendar.account"}))
print(nix.render(auto))
LUA
luau "$dir/run.luau" > "$dir/output.nix"
nix-instantiate --parse "$dir/output.nix" >/dev/null
nix-instantiate --eval --strict --json "$dir/output.nix" > "$dir/output.json"
python3 - "$dir" <<'PY'
import json, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
expected = tomllib.loads((root / "input.toml").read_text())
if "calendar" in expected:
    expected["calendar"].pop("account", None)
    if not expected["calendar"]:
        expected.pop("calendar")
actual = json.loads((root / "output.json").read_text())
assert expected == actual, "The generated Nix does not match the filtered export"
print("Live merged export matches generated Nix, with calendar.account excluded")
PY
