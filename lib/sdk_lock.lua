require("utils")

local M = {}

--- Holds a cross-process lock across the complete Lua callback, not just one shell command.
function M.with_lock(sdk_root, operation, callback)
    local cmd = require("cmd")
    local timeout = os.getenv("MISE_ANDROID_SDK_LOCK_TIMEOUT") or "600"
    if not timeout:match("^%d+$") or tonumber(timeout) > 86400 then
        error("MISE_ANDROID_SDK_LOCK_TIMEOUT must be an integer from 0 to 86400 seconds")
    end
    local owner = cmd.exec(
        "set -eu\numask 077\n"
            .. "mkdir -p "
            .. shell_quote(sdk_root)
            .. "\n"
            .. "root=$(cd "
            .. shell_quote(sdk_root)
            .. " && pwd -P)\n"
            .. 'lock="$root/.mise-install-lock"\n'
            .. "remaining="
            .. tonumber(timeout)
            .. "\n"
            .. [[
# uutils mkdir can exit 0 after losing a creation race; require its creation message.
while ! failure=$(mkdir -v "$lock" 2>&1) || [ -z "$failure" ]; do
    if [ -L "$lock" ] || { [ -e "$lock" ] && [ ! -d "$lock" ]; } || [ ! -w "$root" ]; then
        printf 'Cannot acquire Android SDK lock: %s (check permissions and conflicting paths)\n' "$lock" >&2
        printf '%s\n' "$failure" >&2
        exit 1
    fi
    if [ "$remaining" -eq 0 ]; then
        printf 'Timed out waiting for Android SDK lock: %s\n' "$lock" >&2
        printf '%s\n' "$failure" >&2
        for info in "$lock"/owner.*/info; do
            if [ -f "$info" ]; then
                printf 'Owner record: %s\n' "$info" >&2
                cat "$info" >&2
            fi
        done
        printf 'Do not remove this lock until all SDK installers have stopped; see README lock recovery.\n' >&2
        exit 1
    fi
    sleep 1
    remaining=$((remaining - 1))
done
owner=
cleanup() {
    if [ -n "$owner" ]; then
        if [ -f "$owner/info" ]; then rm "$owner/info"; fi
        rmdir "$owner"
    fi
    rmdir "$lock"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
owner=$(mktemp -d "$lock/owner.XXXXXXXX")
]]
            .. "printf '%s\\n' "
            .. shell_quote("operation=" .. operation)
            .. ' "acquired=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$owner/info"\n'
            .. "printf '%s\\n' \"$owner\"\n"
            .. "trap - 0 INT TERM HUP\n"
    ):gsub("\n$", "")

    local canonical_root = owner:match("^(.*)/%.mise%-install%-lock/owner%.[^/]+$")
    if not canonical_root then
        error("Invalid Android SDK lock ownership response: " .. owner)
    end
    local ok, result = pcall(callback, canonical_root)
    local released, failure = pcall(
        cmd.exec,
        "set -eu\n"
            .. "lock="
            .. shell_quote(canonical_root .. "/.mise-install-lock")
            .. "\n"
            .. "owner="
            .. shell_quote(owner)
            .. "\n"
            .. [[
if [ -L "$lock" ] || [ -L "$owner" ] || [ ! -d "$owner" ]; then
    printf 'Android SDK lock ownership changed; refusing cleanup: %s\n' "$lock" >&2
    exit 1
fi
rm "$owner/info"
rmdir "$owner"
rmdir "$lock"
]]
    )
    if not ok then
        error(tostring(result) .. (released and "" or "\nLock cleanup also failed: " .. tostring(failure)), 0)
    end
    if not released then
        error("Android SDK lock cleanup failed: " .. tostring(failure), 0)
    end
    return result
end

return M
