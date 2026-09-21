#!/usr/bin/env bash
set -euo pipefail
plugin=${1:?plugin directory}
parent=${2:?test directory}
root=$(mktemp -d "$parent/locking.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
lua=${SDK_TEST_LUA:-lua}
mkdir -p "$root/sdk" "$root/other"
ln -s "$root/sdk" "$root/alias"

"$lua" "$plugin/tests/lock-worker.lua" "$plugin" "$root/sdk" first &
first=$!
for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -f "$root/sdk/events" ]] && break
    sleep 0.02
done
[[ -f "$root/sdk/events" ]]
"$lua" "$plugin/tests/lock-worker.lua" "$plugin" "$root/alias" second &
second=$!
"$lua" "$plugin/tests/lock-worker.lua" "$plugin" "$root/other" independent &
independent=$!
wait "$first"
wait "$second"
wait "$independent"
[[ "$(cat "$root/sdk/events")" == $'start first\nend first\nstart second\nend second' ]]
[[ "$(cat "$root/other/events")" == $'start independent\nend independent' ]]
[[ ! -e "$root/sdk/.mise-install-lock" && ! -e "$root/other/.mise-install-lock" ]]

if "$lua" "$plugin/tests/lock-worker.lua" "$plugin" "$root/sdk" failed fail > "$root/failure" 2>&1; then
    echo "Lock callback unexpectedly succeeded" >&2
    exit 1
fi
grep -q "expected callback failure" "$root/failure"
[[ ! -e "$root/sdk/.mise-install-lock" ]]

mkdir "$root/sdk/.mise-install-lock"
MISE_ANDROID_SDK_LOCK_TIMEOUT=0 "$lua" "$plugin/tests/lock-worker.lua" "$plugin" "$root/other" free
if MISE_ANDROID_SDK_LOCK_TIMEOUT=0 "$lua" "$plugin/tests/lock-worker.lua" "$plugin" "$root/sdk" blocked > "$root/timeout" 2>&1; then
    echo "Stale lock unexpectedly acquired" >&2
    exit 1
fi
grep -q "Timed out waiting for Android SDK lock" "$root/timeout"
[[ -d "$root/sdk/.mise-install-lock" ]]
rmdir "$root/sdk/.mise-install-lock"
echo "PASS: canonical-root serialization, independent roots, failures, and stale locks"
