--- Tools whose sdkmanager package path is a bare name (no version component).
--- They expose exactly one version and cannot be pinned to a specific number.
NO_VERSION_TOOLS = { -- luacheck: ignore
    emulator = true,
    ["platform-tools"] = true,
}

--- Returns the stable, plugin-owned Android SDK root.
--- Packages are installed here instead of into the android-sdk tool's own versioned
--- directory, so switching/upgrading android-sdk never loses the installed packages.
--- The android-sdk tool is used only to provide the sdkmanager binary and Java.
--- @return string Absolute path to the stable SDK root
function sdk_install_root() -- luacheck: ignore
    local file = require("file")

    local data_dir = os.getenv("MISE_DATA_DIR")
    if not data_dir or data_dir == "" then
        local home = os.getenv("HOME") or ""
        data_dir = file.join_path(home, ".local", "share", "mise")
    end

    return file.join_path(data_dir, "android-sdk-tools")
end

--- Locates the SDK package-management tool.
--- Prefers the legacy `sdkmanager` whenever it is present and working, so existing
--- cmdline-tools versions keep the tested behaviour. Only falls back to the new
--- `android sdk` command when `sdkmanager` is gone.
--- @return {path: string, kind: string} path to the binary and its kind ("sdkmanager" | "android")
function locate_sdk_tool() -- luacheck: ignore
    local sdkmanager = find_sdk_binary("sdkmanager")
    if sdkmanager then
        return { path = sdkmanager, kind = "sdkmanager" }
    end

    local android = find_sdk_binary("android")
    if android then
        return { path = android, kind = "android" }
    end

    error(
        "Neither sdkmanager nor the android CLI was found — ensure android-sdk is installed and declared as a dependency"
    )
end

--- Returns all available SDK package-management tools, sdkmanager first (preferred)
--- then the newer `android` CLI. Either may be absent.
--- @return {path: string, kind: string}[] Located tools in preference order
function available_sdk_tools() -- luacheck: ignore
    local tools = {}

    local sdkmanager = find_sdk_binary("sdkmanager")
    if sdkmanager then
        table.insert(tools, { path = sdkmanager, kind = "sdkmanager" })
    end

    local android = find_sdk_binary("android")
    if android then
        table.insert(tools, { path = android, kind = "android" })
    end

    return tools
end

--- Finds a named binary inside the SDK's cmdline-tools directories, falling back to PATH.
--- cmdline-tools is searched first so the modern `android` CLI is preferred over the
--- long-removed legacy `tools/bin/android` tool that may still linger on PATH.
--- @param name string Binary name (e.g. "sdkmanager" or "android")
--- @return string|nil Absolute path to the binary, or nil if not found
function find_sdk_binary(name) -- luacheck: ignore
    local file = require("file")

    for _, var in ipairs({ "ANDROID_SDK_ROOT", "ANDROID_HOME" }) do
        local sdk_root = os.getenv(var)
        if sdk_root and sdk_root ~= "" then
            local candidate = find_binary_in_root(sdk_root, name)
            if candidate then
                return candidate
            end
        end
    end

    local cmd = require("cmd")
    local from_path = cmd.exec("command -v " .. name .. " 2>/dev/null || echo ''")
    from_path = from_path:match("^%s*(.-)%s*$")
    if from_path ~= "" and file.exists(from_path) then
        return from_path
    end

    return nil
end

--- Finds a named binary inside a single SDK root's cmdline-tools directory.
--- Prefers the "latest" install, then falls back to the highest versioned
--- directory (e.g. cmdline-tools/20.0/bin/<name>).
--- @param sdk_root string Absolute path to the Android SDK root
--- @param name string Binary name
--- @return string|nil Absolute path to the binary, or nil if none found
function find_binary_in_root(sdk_root, name) -- luacheck: ignore
    local cmd = require("cmd")
    local file = require("file")

    local cmdline_tools = file.join_path(sdk_root, "cmdline-tools")

    -- Preferred: the "latest" symlink/directory.
    local latest = file.join_path(cmdline_tools, "latest", "bin", name)
    if file.exists(latest) then
        return latest
    end

    -- Fall back to versioned directories (e.g. "20.0"), highest version first.
    local listing = cmd.exec("ls -1 " .. cmdline_tools .. " 2>/dev/null")
    local entries = {}
    for entry in listing:gmatch("[^\n]+") do
        local entry_name = entry:match("^%s*(.-)%s*$")
        if entry_name ~= "" and entry_name ~= "latest" then
            table.insert(entries, entry_name)
        end
    end

    table.sort(entries, compare_versions_desc)

    for _, entry in ipairs(entries) do
        local candidate = file.join_path(cmdline_tools, entry, "bin", name)
        if file.exists(candidate) then
            return candidate
        end
    end

    return nil
end

--- Builds the canonical (semicolon-separated) sdkmanager package identifier.
--- system-images: selects the arch-appropriate ABI automatically.
--- @param tool string Tool family (e.g. "build-tools")
--- @param version string Requested version
--- @return string Package identifier in sdkmanager form
function build_package_name(tool, version) -- luacheck: ignore
    if tool == "system-images" then
        local abi = (RUNTIME.archType == "arm64" or RUNTIME.archType == "aarch64") and "arm64-v8a" or "x86_64"
        return "system-images;" .. version .. ";google_apis_playstore;" .. abi
    elseif NO_VERSION_TOOLS[tool] then
        return tool
    else
        return tool .. ";" .. version
    end
end

--- Adapts a canonical package identifier to the syntax of the given tool kind.
--- The new `android` CLI uses "/" separators where sdkmanager uses ";".
--- @param kind string "sdkmanager" | "android"
--- @param package_name string Canonical (semicolon) package identifier
--- @return string Package identifier in the syntax expected by `kind`
function format_package(kind, package_name) -- luacheck: ignore
    if kind == "android" then
        return (package_name:gsub(";", "/"))
    end
    return package_name
end

--- Runs a single install attempt with one located tool, into the target root.
--- Failures are swallowed (`|| true`) — success is verified by the caller via the
--- expected on-disk package directory, since cmd.exec cannot report exit codes.
--- @param info {path: string, kind: string} Located tool
--- @param package_name string Canonical (semicolon) package identifier
--- @param target_root string Absolute path to install into
function run_install(info, package_name, target_root) -- luacheck: ignore
    local cmd = require("cmd")
    local pkg = format_package(info.kind, package_name)

    if info.kind == "android" then
        -- The android CLI reads the target root from ANDROID_SDK_ROOT/ANDROID_HOME.
        -- It prints its Terms of Service once and proceeds; no license ceremony.
        local env = "ANDROID_SDK_ROOT='" .. target_root .. "' ANDROID_HOME='" .. target_root .. "' "
        cmd.exec(env .. info.path .. " sdk install '" .. pkg .. "' 2>&1 || true")
    else
        -- Accept all SDK licenses non-interactively before installing, into the target root.
        cmd.exec(
            "yes 2>/dev/null | "
                .. info.path
                .. " --sdk_root='"
                .. target_root
                .. "' --licenses >/dev/null 2>&1 || true"
        )
        cmd.exec(info.path .. " --sdk_root='" .. target_root .. "' --install '" .. pkg .. "' 2>&1 || true")
    end
end

--- Installs a package into the target root, preferring sdkmanager but falling back to
--- the newer `android sdk install` when needed. Some packages (e.g. `emulator`) are no
--- longer installable via sdkmanager in cmdline-tools 22+, so if sdkmanager leaves the
--- package absent on disk we retry with the android CLI. Success is verified by the
--- presence of the package's expected directory.
--- @param tool string Tool family (e.g. "build-tools", "emulator")
--- @param version string Requested version
--- @param target_root string Absolute path to install into (the stable SDK root)
function install_package(tool, version, target_root) -- luacheck: ignore
    local cmd = require("cmd")
    local file = require("file")

    local package_name = build_package_name(tool, version)
    local package_dir = resolve_package_dir(target_root, tool, version)

    cmd.exec("mkdir -p '" .. target_root .. "'")

    local tools = available_sdk_tools()
    if #tools == 0 then
        error(
            "Neither sdkmanager nor the android CLI was found — ensure android-sdk is installed and declared as a dependency"
        )
    end

    for _, info in ipairs(tools) do
        run_install(info, package_name, target_root)

        -- Without an exact on-disk footprint we cannot verify; accept the first attempt.
        if not package_dir or file.exists(package_dir) then
            return
        end
    end

    error("Failed to install '" .. package_name .. "' into '" .. target_root .. "' with sdkmanager or the android CLI")
end

--- Returns the directory that must exist on disk when a package is installed,
--- relative to the given SDK root. Used both to advertise PATH entries and to
--- detect drift after an android-sdk upgrade.
--- @param sdk_root string Absolute path to the Android SDK root
--- @param tool string Tool family
--- @param version string Installed version
--- @return string|nil Absolute directory path, or nil for unknown tools
function resolve_package_dir(sdk_root, tool, version) -- luacheck: ignore
    local file = require("file")
    if tool == "system-images" then
        local abi = (RUNTIME.archType == "arm64" or RUNTIME.archType == "aarch64") and "arm64-v8a" or "x86_64"
        return file.join_path(sdk_root, "system-images", version, "google_apis_playstore", abi)
    end
    local paths = {
        emulator = file.join_path(sdk_root, "emulator"),
        ["platform-tools"] = file.join_path(sdk_root, "platform-tools"),
        ["build-tools"] = file.join_path(sdk_root, "build-tools", version),
        platforms = file.join_path(sdk_root, "platforms", version),
        ndk = file.join_path(sdk_root, "ndk", version),
        cmake = file.join_path(sdk_root, "cmake", version),
    }
    return paths[tool]
end

--- Returns the bin directory for the given tool, or nil if the tool has no runnable binaries.
--- @param sdk_root string Absolute path to the Android SDK root
--- @param tool string Tool family
--- @param version string Installed version
--- @return string|nil Absolute bin directory, or nil
function resolve_bin_path(sdk_root, tool, version) -- luacheck: ignore
    local file = require("file")
    local paths = {
        emulator = file.join_path(sdk_root, "emulator"),
        ["platform-tools"] = file.join_path(sdk_root, "platform-tools"),
        ["build-tools"] = file.join_path(sdk_root, "build-tools", version),
        ndk = file.join_path(sdk_root, "ndk", version),
        cmake = file.join_path(sdk_root, "cmake", version, "bin"),
    }
    return paths[tool]
end

--- Self-heals drift: if a package is missing from the current SDK root (e.g. because
--- android-sdk was upgraded to a new directory), reinstall it. Silently no-ops if the
--- tool has no on-disk footprint we track, or if the SDK tool cannot be located.
--- @param sdk_root string Absolute path to the Android SDK root
--- @param tool string Tool family
--- @param version string Installed version
function ensure_package_installed(sdk_root, tool, version) -- luacheck: ignore
    local file = require("file")
    local package_dir = resolve_package_dir(sdk_root, tool, version)
    if not package_dir or file.exists(package_dir) then
        return
    end

    -- Best-effort during activation: never let a failed reinstall break exec_env.
    pcall(install_package, tool, version, sdk_root)
end

--- Comparator sorting version-like strings in descending order.
--- Compares dot-separated numeric segments; non-numeric names sort last.
function compare_versions_desc(a, b) -- luacheck: ignore
    local function parts(v)
        local p = {}
        for n in v:gmatch("%d+") do
            table.insert(p, tonumber(n))
        end
        return p
    end

    local pa, pb = parts(a), parts(b)
    local len = math.max(#pa, #pb)
    for i = 1, len do
        local na = pa[i] or -1
        local nb = pb[i] or -1
        if na ~= nb then
            return na > nb
        end
    end

    return a > b
end
