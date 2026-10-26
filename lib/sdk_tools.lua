local M = {}

--- Return nil when this environment has no selected Android command-line tools.
function M.locate_if_available()
    local file = require("file")
    local cmd = require("cmd")
    if RUNTIME.osType == "windows" then
        error("android-sdkmanager requires a POSIX shell (Linux or macOS)")
    end
    local directory
    for entry in ((os.getenv("PATH") or "") .. ":"):gmatch("(.-):") do
        if entry:match("^/.*/cmdline%-tools/[^/]+/bin/?$") then
            if file.exists(file.join_path(entry, "sdkmanager")) or file.exists(file.join_path(entry, "android")) then
                directory = entry:gsub("/+$", ""):gsub("/bin$", "")
                break
            end
        end
    end
    if not directory or not directory:match("^/.*/cmdline%-tools/[^/]+$") then
        return nil
    end
    local canonical = cmd.exec("cd " .. shell_quote(directory) .. " && pwd -P"):gsub("\n$", "")
    local root = canonical:match("^(.+)/cmdline%-tools/[^/]+$")
    if not root then
        error(
            "Selected android-sdk has an unsupported physical layout: "
                .. canonical
                .. ". Select an android-sdk dependency containing cmdline-tools/<version> inside its SDK root"
        )
    end
    return { directory = canonical, root = root }
end

--- Select one dependency installation, never the highest version in the mise store.
function M.locate()
    local selected = M.locate_if_available()
    if not selected then
        error(
            "Cannot locate selected Android command-line tools: install the configured android-sdk and java dependencies; "
                .. "and ensure the selected android-sdk exports cmdline-tools/<version>/bin on PATH"
        )
    end
    return selected
end

--- Capability probes are only allowed during explicit discovery and installation.
function M.resolve()
    local file = require("file")
    local cmd = require("cmd")
    local selected = M.locate()
    local canonical = selected.directory
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
                .. '*) printf \'%s\\n\' "$output" >&2; exit "$status";;\nesac',
            { env = { ANDROID_HOME = selected.root, ANDROID_SDK_ROOT = selected.root } }
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
    selected.tools = tools
    return selected
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
