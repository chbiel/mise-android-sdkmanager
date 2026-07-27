--- Tools whose sdkmanager package path is a bare name (no version component).
--- They expose exactly one version and cannot be pinned to a specific number.
NO_VERSION_TOOLS = { -- luacheck: ignore
    emulator = true,
    ["platform-tools"] = true,
}

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

--- Installs a package using the located tool, handling sdkmanager/android differences.
--- @param info {path: string, kind: string} Located tool
--- @param package_name string Canonical (semicolon) package identifier
function install_package(info, package_name) -- luacheck: ignore
    local cmd = require("cmd")
    local pkg = format_package(info.kind, package_name)

    if info.kind == "android" then
        -- The android CLI prints its Terms of Service once and proceeds; no license ceremony.
        cmd.exec(info.path .. " sdk install '" .. pkg .. "'")
    else
        -- Accept all SDK licenses non-interactively before installing.
        cmd.exec("yes 2>/dev/null | " .. info.path .. " --licenses >/dev/null 2>&1 || true")
        cmd.exec(info.path .. " --install '" .. pkg .. "'")
    end
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

    local ok, info = pcall(locate_sdk_tool)
    if not ok then
        return
    end

    install_package(info, build_package_name(tool, version))
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
