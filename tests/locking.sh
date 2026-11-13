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
status=0
for pid in "$first" "$second" "$independent"; do
    wait "$pid" || status=1
done
[[ "$status" == 0 ]]
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
real_mkdir=$(command -v mkdir)
mkdir "$root/bin"
cat > "$root/bin/mkdir" <<'EOF'
#!/bin/sh
set -eu
# Model uutils mkdir reporting success after losing a concurrent creation.
for argument do
    if [ "$argument" = "$SDK_TEST_LOCK" ] && [ -d "$argument" ]; then
        exit 0
    fi
done
exec "$SDK_TEST_MKDIR" "$@"
EOF
chmod +x "$root/bin/mkdir"
if PATH="$root/bin:$PATH" SDK_TEST_MKDIR="$real_mkdir" SDK_TEST_LOCK="$root/sdk/.mise-install-lock" \
    MISE_ANDROID_SDK_LOCK_TIMEOUT=0 "$lua" "$plugin/tests/lock-worker.lua" "$plugin" "$root/sdk" blocked > "$root/timeout" 2>&1; then
    echo "Stale lock unexpectedly acquired" >&2
    exit 1
fi
grep -q "Timed out waiting for Android SDK lock" "$root/timeout"
[[ -d "$root/sdk/.mise-install-lock" ]]
rmdir "$root/sdk/.mise-install-lock"
echo "PASS: canonical-root serialization despite mkdir false success, independent roots, failures, and stale locks"
