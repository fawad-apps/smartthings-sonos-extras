#!/usr/bin/env bash
#
# Syntax-check and unit-test the driver. Exits non-zero on any failure, so
# scripts/deploy.sh can refuse to ship a broken build.
#
# Usage: scripts/test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v lua >/dev/null 2>&1; then
    echo "!!  lua not found - install it with: brew install lua" >&2
    exit 1
fi

echo "==> Syntax-checking Lua"
find src -name '*.lua' -print0 | xargs -0 -n1 luac -p
echo "    all sources parse"

echo "==> Running tests"
lua tests/test_driver.lua
