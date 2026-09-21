local M = {}

--- Select one dependency installation, never the highest version in the mise store.
function M.resolve(options)
    local file = require("file")
    local cmd = require("cmd")
    if RUNTIME.osType == "windows" then
        error("android-sdkmanager requires a POSIX shell (Linux or macOS)")
    end
    local directory = options and options.cmdline_tools
    if directory then
        directory = directory:gsub("/+$", "")
    else
        for entry in ((os.getenv("PATH") or "") .. ":"):gmatch("(.-):") do
            if entry:match("^/.*/cmdline%-tools/[^/]+/bin/?$") then
                if
                    file.exists(file.join_path(entry, "sdkmanager")) or file.exists(file.join_path(entry, "android"))
                then
                    directory = entry:gsub("/+$", ""):gsub("/bin$", "")
                    break
                end
            end
        end
    end
    if not directory or not directory:match("^/.*/cmdline%-tools/[^/]+$") then
        error(
            "Cannot locate selected Android command-line tools: install the configured android-sdk and java dependencies; "
                .. "or set cmdline_tools to an absolute cmdline-tools/<version> directory"
        )
    end
    local source = directory:match("^(.*)/[^/]+$")
    -- Canonicalize the selected directory while retaining its complete cmdline-tools tree.
    local canonical = cmd.exec("cd " .. shell_quote(directory) .. " && pwd -P"):gsub("\n$", "")
    local tools = {}
    local android = file.join_path(canonical, "bin", "android")
    local sdkmanager = file.join_path(canonical, "bin", "sdkmanager")
    local probe_failure
    if file.exists(android) then
        -- Some modern releases print subcommand usage on stderr and exit 2 for --help.
        local ok, output = pcall(
            cmd.exec,
            "if output=$("
                .. shell_quote(android)
                .. " sdk --help 2>&1); then status=0; else status=$?; fi\n"
                .. 'case "$status" in\n0|2) printf \'%s\\n\' "$output";;\n'
                .. '*) printf \'%s\\n\' "$output" >&2; exit "$status";;\nesac'
        )
        if ok and output:find("install", 1, true) and output:find("list", 1, true) then
            table.insert(tools, { path = android, kind = "android" })
        else
            probe_failure = "Cannot use modern android sdk commands from " .. android .. ":\n" .. tostring(output)
        end
    end
    if file.exists(sdkmanager) then
        table.insert(tools, { path = sdkmanager, kind = "sdkmanager" })
    end
    if #tools == 0 then
        error(probe_failure or ("No SDK installer found in " .. canonical))
    end
    if probe_failure then
        require("log").warn(probe_failure .. "\nUsing sdkmanager from the same command-line tools installation")
    end
    return { directory = canonical, source = source, tools = tools }
end

--- A bounded, read-only check of the exposed SDK layout; never probes executables.
function M.exposed(sdk_root)
    local file = require("file")
    local directory = file.join_path(sdk_root, "cmdline-tools")
    if not file.exists(directory) then
        return false
    end
    -- Shell file tests also handle regular files and dangling links among version directories.
    local result = require("cmd").exec(
        "for binary in "
            .. shell_quote(directory)
            .. "/*/bin/sdkmanager "
            .. shell_quote(directory)
            .. '/*/bin/android; do\nif [ -f "$binary" ]; then printf found; break; fi\ndone'
    )
    return result == "found"
end

--- Caller holds the SDK-root lock. Preserve every user-owned cmdline-tools path.
function M.expose(sdk_root, selected)
    local cmd = require("cmd")
    local file = require("file")
    local destination = file.join_path(sdk_root, "cmdline-tools")
    local target = cmd.exec(
        "if [ -L " .. shell_quote(destination) .. " ]; then readlink " .. shell_quote(destination) .. "; fi"
    ):gsub("\n$", "")
    if target ~= ".mise-cmdline-tools" and (target ~= "" or file.exists(destination)) then
        if M.exposed(sdk_root) then
            return
        end
        error("Cannot expose cmdline-tools: existing user-owned path is incomplete: " .. destination)
    end
    cmd.exec(
        "set -eu\nroot=$(cd "
            .. shell_quote(sdk_root)
            .. " && pwd -P)\nsource=$(cd "
            .. shell_quote(selected.source)
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
    ln -sfn "$source" .mise-cmdline-tools
fi
if [ ! -L cmdline-tools ] && [ ! -e cmdline-tools ]; then
    ln -sn .mise-cmdline-tools cmdline-tools
fi
if [ "$(readlink cmdline-tools)" != .mise-cmdline-tools ]; then
    echo "Cannot replace user-owned cmdline-tools path" >&2
    exit 1
fi
]]
    )
end

function M.format_package(kind, package_name)
    return kind == "android" and package_name:gsub(";", "/") or package_name
end

function M.list(info, sdk_root)
    local command = shell_quote(info.path)
    if info.kind == "android" then
        return require("cmd").exec(
            command .. " sdk list --all --all-versions",
            { env = { ANDROID_SDK_ROOT = sdk_root, ANDROID_HOME = sdk_root } }
        )
    end
    return require("cmd").exec(command .. " --sdk_root=" .. shell_quote(sdk_root) .. " --list")
end

function M.install(info, package_name, sdk_root)
    local binary = shell_quote(info.path)
    local pkg = shell_quote(M.format_package(info.kind, package_name))
    local function execute(command, phase, options)
        -- mise exposes stdout on success and stderr on failure; retain both and the real status.
        local ok, output = pcall(
            require("cmd").exec,
            "if output=$(\n"
                .. command
                .. " 2>&1\n); then\nprintf '%s\\n' \"$output\"\n"
                .. 'else\nstatus=$?\nprintf \'%s\\n\' "$output" >&2\nexit "$status"\nfi',
            options or {}
        )
        if not ok then
            return false,
                phase
                    .. " failed for '"
                    .. package_name
                    .. "' using "
                    .. info.path
                    .. " in "
                    .. sdk_root
                    .. ":\n"
                    .. tostring(output)
        end
        return true, output
    end
    if info.kind == "android" then
        return execute(
            binary .. " sdk install " .. pkg,
            "install",
            { env = { ANDROID_SDK_ROOT = sdk_root, ANDROID_HOME = sdk_root } }
        )
    end
    local command = binary .. " --sdk_root=" .. shell_quote(sdk_root)
    local ok, output = execute("(yes 2>/dev/null || :) | " .. command .. " --licenses", "license acceptance")
    if not ok then
        return false, output
    end
    return execute(command .. " --install " .. pkg, "install")
end

return M
