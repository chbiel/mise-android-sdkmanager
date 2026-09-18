--- Tools whose sdkmanager package path is a bare name (no version component).
--- They expose exactly one version and cannot be pinned to a specific number.
NO_VERSION_TOOLS = { -- luacheck: ignore
    emulator = true,
    ["platform-tools"] = true,
}

--- Quotes one argument for the POSIX shell used by this plugin.
function shell_quote(value) -- luacheck: ignore
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function system_image_abi() -- luacheck: ignore
    return (RUNTIME.archType == "arm64" or RUNTIME.archType == "aarch64") and "arm64-v8a" or "x86_64"
end

function valid_sdk_revision(version) -- luacheck: ignore
    local core, suffix = version:match("^(%d[%d%.]*)(.*)$")
    if not core or core:sub(-1) == "." or core:find("..", 1, true) then
        return false
    end
    suffix = suffix:lower():gsub("[%s%-_]", "")
    return suffix == ""
        or suffix:match("^rc%d+$") ~= nil
        or suffix:match("^alpha%d+$") ~= nil
        or suffix:match("^beta%d+$") ~= nil
        or suffix:match("^preview%d+$") ~= nil
end

--- Numeric releases sort by component, with previews before the corresponding stable release.
function compare_package_versions(a, b) -- luacheck: ignore
    if a:match("^android%-") and b:match("^android%-") then
        return compare_versions_desc(b, a)
    end
    local ac, as = a:match("^(%d[%d%.]*)(.*)$")
    local bc, bs = b:match("^(%d[%d%.]*)(.*)$")
    if not ac or not bc then
        return compare_versions_desc(b, a)
    end
    local function parts(core)
        local result = {}
        for number in core:gmatch("%d+") do
            table.insert(result, tonumber(number))
        end
        return result
    end
    local ap, bp = parts(ac), parts(bc)
    for i = 1, math.max(#ap, #bp) do
        local av, bv = ap[i] or 0, bp[i] or 0
        if av ~= bv then
            return av < bv
        end
    end
    local function preview(suffix)
        local ranks = { preview = 1, alpha = 2, beta = 3, rc = 4 }
        local label, number = suffix:lower():match("([%a]+)[%s%-_]*(%d*)")
        return suffix == "" and 5 or (ranks[label] or 0), tonumber(number) or 0
    end
    local ar, an = preview(as)
    local br, bn = preview(bs)
    if ar ~= br then
        return ar < br
    elseif an ~= bn then
        return an < bn
    end
    return a < b
end

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
--- Prefers the modern `android` CLI when present so newer cmdline-tools installations
--- are used first, while keeping the legacy `sdkmanager` as a fallback.
--- @return {path: string, kind: string} path to the binary and its kind ("sdkmanager" | "android")
function locate_sdk_tool() -- luacheck: ignore
    local tools = available_sdk_tools()
    if #tools > 0 then
        return tools[1]
    end

    error(
        "Neither sdkmanager nor the android CLI was found — ensure android-sdk is installed and declared as a dependency"
    )
end

--- Returns all available SDK package-management tools, android first (preferred)
--- then the legacy `sdkmanager` fallback. Either may be absent.
--- @return {path: string, kind: string}[] Located tools in preference order
function available_sdk_tools() -- luacheck: ignore
    local tools = {}

    local android = find_sdk_binary("android")
    if android then
        table.insert(tools, { path = android, kind = "android" })
    end

    local sdkmanager = find_sdk_binary("sdkmanager")
    if sdkmanager then
        table.insert(tools, { path = sdkmanager, kind = "sdkmanager" })
    end

    return tools
end

--- Returns the base directory mise installs tools into (${MISE_DATA_DIR}/installs,
--- falling back to ~/.local/share/mise/installs).
--- @return string Absolute path to the mise installs directory
function mise_installs_dir() -- luacheck: ignore
    local file = require("file")
    local data_dir = os.getenv("MISE_DATA_DIR")
    if not data_dir or data_dir == "" then
        local home = os.getenv("HOME") or ""
        data_dir = file.join_path(home, ".local", "share", "mise")
    end
    return file.join_path(data_dir, "installs")
end

--- Discovers android-sdk install roots (directories that contain a
--- `cmdline-tools/<ver>/bin/sdkmanager`) independently of any environment variables.
--- This lets the plugin locate `sdkmanager`/`android` even when neither ANDROID_SDK_ROOT
--- nor ANDROID_HOME is set — so users no longer need to hardcode ANDROID_HOME.
--- Roots are returned highest-version-first. The stable root is outside installs.
--- @return string[] Candidate android-sdk roots, best first
function find_android_sdk_roots() -- luacheck: ignore
    local cmd = require("cmd")
    local file = require("file")

    local installs = mise_installs_dir()
    if not file.exists(installs) then
        return {}
    end
    -- One find covers both binaries; strip the trailing cmdline-tools layout to get roots.
    local listing = cmd.exec(
        "find "
            .. shell_quote(installs)
            .. " -maxdepth 6 -type f \\( -name sdkmanager -o -name android \\) -path '*/cmdline-tools/*/bin/*'"
    )

    local roots = {}
    local seen = {}
    for line in listing:gmatch("[^\n]+") do
        local root = line:match("^(.*)/cmdline%-tools/[^/]+/bin/[^/]+$")
        if root and root ~= "" and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end

    table.sort(roots, compare_versions_desc)
    return roots
end

--- Finds a named binary inside the SDK's cmdline-tools directories, falling back to PATH.
--- Search order: explicit ANDROID_SDK_ROOT/ANDROID_HOME env roots, then android-sdk roots
--- auto-discovered under the mise installs directory (env-independent), then PATH.
--- cmdline-tools is searched first so the modern `android` CLI is preferred over the
--- long-removed legacy `tools/bin/android` tool that may still linger on PATH.
--- @param name string Binary name (e.g. "sdkmanager" or "android")
--- @return string|nil Absolute path to the binary, or nil if not found
function find_sdk_binary(name) -- luacheck: ignore
    local file = require("file")

    local roots = {}
    local seen = {}
    local function add_root(root)
        if root and root ~= "" and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end

    for _, var in ipairs({ "ANDROID_SDK_ROOT", "ANDROID_HOME" }) do
        add_root(os.getenv(var))
    end
    for _, root in ipairs(find_android_sdk_roots()) do
        add_root(root)
    end

    for _, root in ipairs(roots) do
        local candidate = find_binary_in_root(root, name)
        if candidate then
            return candidate
        end
    end

    local cmd = require("cmd")
    local from_path = cmd.exec("command -v " .. shell_quote(name) .. " 2>/dev/null || echo ''")
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
    if not file.exists(cmdline_tools) then
        return nil
    end

    -- Preferred: the "latest" symlink/directory.
    local latest = file.join_path(cmdline_tools, "latest", "bin", name)
    if file.exists(latest) then
        return latest
    end

    -- Fall back to versioned directories (e.g. "20.0"), highest version first.
    local listing = cmd.exec("ls -1 " .. shell_quote(cmdline_tools))
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

--- Locates dependency tooling without selecting the stable root's own link.
function find_cmdline_tools_source(sdk_root) -- luacheck: ignore
    local cmd = require("cmd")
    local seen = { [sdk_root] = true }
    local function from_root(root)
        if not root or root == "" or seen[root] then
            return nil
        end
        seen[root] = true
        if find_binary_in_root(root, "sdkmanager") or find_binary_in_root(root, "android") then
            return require("file").join_path(root, "cmdline-tools")
        end
        return nil
    end

    for _, key in ipairs({ "ANDROID_HOME", "ANDROID_SDK_ROOT" }) do
        local source = from_root(os.getenv(key))
        if source then
            return source
        end
    end
    for _, name in ipairs({ "sdkmanager", "android" }) do
        local binary = cmd.exec("command -v " .. shell_quote(name) .. " 2>/dev/null || :"):match("^%s*(.-)%s*$")
        local source = from_root(binary:match("^(.*)/cmdline%-tools/[^/]+/bin/[^/]+$"))
        if source then
            return source
        end
    end
    for _, root in ipairs(find_android_sdk_roots()) do
        local source = from_root(root)
        if source then
            return source
        end
    end
    error("Cannot expose cmdline-tools: install android-sdk and declare it as a dependency")
end

--- The private indirection identifies links we own, without overwriting user installations.
function ensure_cmdline_tools(sdk_root) -- luacheck: ignore
    local cmd = require("cmd")
    local file = require("file")
    local destination = file.join_path(sdk_root, "cmdline-tools")
    local managed_name = ".mise-cmdline-tools"
    local target = cmd.exec(
        "if [ -L " .. shell_quote(destination) .. " ]; then readlink " .. shell_quote(destination) .. "; fi"
    ):gsub("\n$", "")
    if target ~= managed_name and (target ~= "" or file.exists(destination)) then
        if find_binary_in_root(sdk_root, "sdkmanager") or find_binary_in_root(sdk_root, "android") then
            return
        end
        error("Cannot expose cmdline-tools: existing user-owned path is incomplete: " .. destination)
    end

    local source = find_cmdline_tools_source(sdk_root)
    -- Resolve both directories before linking so aliases cannot introduce a cycle.
    cmd.exec(
        "set -eu\n"
            .. "mkdir -p "
            .. shell_quote(sdk_root)
            .. "\n"
            .. "root=$(cd "
            .. shell_quote(sdk_root)
            .. " && pwd -P)\n"
            .. "source=$(cd "
            .. shell_quote(source)
            .. " && pwd -P)\n"
            .. [[
case "$source/" in
    "$root/"*) echo "Cannot link cmdline-tools from inside the stable SDK root" >&2; exit 1 ;;
esac
cd "$root"
if [ -e .mise-cmdline-tools ] && [ ! -L .mise-cmdline-tools ]; then
    echo "Cannot replace user-owned .mise-cmdline-tools directory" >&2
    exit 1
fi
if [ "$(readlink .mise-cmdline-tools 2>/dev/null || :)" != "$source" ]; then
    ln -sfn "$source" .mise-cmdline-tools ||
        [ "$(readlink .mise-cmdline-tools)" = "$source" ]
fi
if [ ! -L cmdline-tools ] && [ ! -e cmdline-tools ]; then
    ln -sn .mise-cmdline-tools cmdline-tools ||
        [ "$(readlink cmdline-tools)" = .mise-cmdline-tools ]
fi
if [ "$(readlink cmdline-tools)" != .mise-cmdline-tools ]; then
    echo "Cannot replace user-owned cmdline-tools path" >&2
    exit 1
fi
]]
    )
end

--- Builds the canonical (semicolon-separated) sdkmanager package identifier.
--- system-images: selects the arch-appropriate ABI automatically.
--- @param tool string Tool family (e.g. "build-tools")
--- @param version string Requested version
--- @return string Package identifier in sdkmanager form
function build_package_name(tool, version) -- luacheck: ignore
    if tool == "system-images" then
        return "system-images;" .. version .. ";google_apis_playstore;" .. system_image_abi()
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
--- @param info {path: string, kind: string} Located tool
--- @param package_name string Canonical (semicolon) package identifier
--- @param target_root string Absolute path to install into
--- @return boolean, string Success and captured output or error
function run_install(info, package_name, target_root) -- luacheck: ignore
    local cmd = require("cmd")
    local binary = shell_quote(info.path)
    local pkg = shell_quote(format_package(info.kind, package_name))

    if info.kind == "android" then
        return pcall(
            cmd.exec,
            binary .. " sdk install " .. pkg .. " 2>&1",
            { env = { ANDROID_SDK_ROOT = target_root, ANDROID_HOME = target_root } }
        )
    end

    local command = binary .. " --sdk_root=" .. shell_quote(target_root)
    -- Ignore only yes's expected broken pipe, not sdkmanager's license exit status.
    local ok, output = pcall(cmd.exec, "(yes 2>/dev/null || :) | " .. command .. " --licenses 2>&1")
    if not ok then
        return false, tostring(output)
    end
    return pcall(cmd.exec, command .. " --install " .. pkg .. " 2>&1")
end

--- Reads the installed revision only when metadata and the package payload are present.
--- @return string|nil revision
--- @return string|nil failure
function installed_package_revision(sdk_root, tool, version) -- luacheck: ignore
    local file = require("file")
    local package_dir = resolve_package_dir(sdk_root, tool, version)
    if not package_dir then
        return nil, "Unsupported Android SDK tool: " .. tool
    end
    local payloads = {
        ["platform-tools"] = "adb",
        emulator = "emulator",
        ["build-tools"] = "aapt",
        platforms = "android.jar",
        ["system-images"] = "system.img",
        ndk = "ndk-build",
        cmake = "bin/cmake",
    }
    if not file.exists(file.join_path(package_dir, payloads[tool])) then
        return nil, "Missing package payload in " .. package_dir
    end

    local revision, package_path
    local properties = file.join_path(package_dir, "source.properties")
    local xml_path = file.join_path(package_dir, "package.xml")
    if file.exists(properties) then
        for line in file.read(properties):gmatch("[^\r\n]+") do
            local key, value = line:match("^%s*([%w%.]+)%s*=%s*(.-)%s*$")
            if key == "Pkg.Revision" then
                revision = value
            elseif key == "Pkg.Path" then
                package_path = value
            end
        end
    end
    if file.exists(xml_path) then
        local xml = file.read(xml_path)
        local attributes = xml:match("<localPackage%s+([^>]+)>")
        local xml_package_path = attributes and attributes:match("path%s*=%s*[\"']([^\"']+)[\"']")
        if not xml_package_path or xml_package_path ~= build_package_name(tool, version) then
            return nil, "Missing or unexpected package identity in " .. xml_path
        end
        package_path = package_path or xml_package_path
        local block = xml:match("<revision>%s*(.-)%s*</revision>")
        local major = block and block:match("<major>%s*(%d+)%s*</major>")
        if not revision and major then
            local minor = block:match("<minor>%s*(%d+)%s*</minor>") or "0"
            local micro = block:match("<micro>%s*(%d+)%s*</micro>") or "0"
            local preview = block:match("<preview>%s*(%d+)%s*</preview>")
            revision = major .. "." .. minor .. "." .. micro
            if preview and tonumber(preview) > 0 then
                revision = revision .. "-rc" .. preview
            end
        end
    end
    if not revision or not valid_sdk_revision(revision) then
        return nil, "Missing or invalid package revision metadata in " .. package_dir
    end
    if package_path and package_path:gsub("/", ";") ~= build_package_name(tool, version) then
        return nil, "Unexpected package identity '" .. package_path .. "' in " .. package_dir
    end
    return revision
end

--- Installs using android first, then sdkmanager, checking command status and package metadata.
--- @param tool string Tool family (e.g. "build-tools", "emulator")
--- @param version string Requested version
--- @param target_root string Absolute path to install into (the stable SDK root)
function install_package(tool, version, target_root) -- luacheck: ignore
    local cmd = require("cmd")

    local package_name = build_package_name(tool, version)
    if not resolve_package_dir(target_root, tool, version) then
        error("Unsupported Android SDK tool: " .. tool)
    end
    cmd.exec("mkdir -p " .. shell_quote(target_root))

    local tools = available_sdk_tools()
    if #tools == 0 then
        error(
            "Neither sdkmanager nor the android CLI was found — ensure android-sdk is installed and declared as a dependency"
        )
    end

    local errors = {}
    for _, info in ipairs(tools) do
        local ok, output = run_install(info, package_name, target_root)
        if ok then
            local revision, failure = installed_package_revision(target_root, tool, version)
            if revision then
                if NO_VERSION_TOOLS[tool] and revision ~= version then
                    require("log").warn(
                        tool
                            .. ": installed revision "
                            .. revision
                            .. " differs from mise's resolved version "
                            .. version
                            .. "; using the installed revision. The SDK installer cannot pin this shared package; "
                            .. "configured/locked revisions are advisory"
                    )
                end
                return
            end
            table.insert(errors, info.kind .. ": " .. failure .. "\n" .. output)
        else
            table.insert(errors, info.kind .. ": " .. tostring(output))
        end
    end

    error("Failed to install '" .. package_name .. "' into '" .. target_root .. "':\n" .. table.concat(errors, "\n"))
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
        return file.join_path(sdk_root, "system-images", version, "google_apis_playstore", system_image_abi())
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

--- Repairs missing/incomplete packages without making activation fatal.
--- @param sdk_root string Absolute path to the Android SDK root
--- @param tool string Tool family
--- @param version string Installed version
function ensure_package_installed(sdk_root, tool, version) -- luacheck: ignore
    if installed_package_revision(sdk_root, tool, version) then
        return
    end

    local ok, failure = pcall(install_package, tool, version, sdk_root)
    if not ok then
        require("log").warn("Could not repair " .. tool .. ": " .. tostring(failure))
    end
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
