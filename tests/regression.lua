local root, temporary = assert(arg[1]), assert(arg[2])
package.path = root .. "/lib/?.lua;" .. package.path
---@type {files: table<string, string|boolean>, env: table<string, string>, commands: table[], warnings: string[], execute?: fun(command: string, options?: CmdExecOpts): string}
local state
local passed, failed = 0, 0

local function reset()
    state = { files = {}, env = {}, commands = {}, warnings = {} }
    os.getenv = function(key)
        return state.env[key]
    end
    package.loaded.file = {
        join_path = function(...)
            return table.concat({ ... }, "/")
        end,
        exists = function(path)
            return state.files[path] ~= nil
        end,
        read = function(path)
            assert(type(state.files[path]) == "string", "Unexpected file read: " .. path)
            return state.files[path]
        end,
    }
    package.loaded.cmd = {
        exec = function(command, options)
            table.insert(state.commands, { command = command, options = options })
            if state.execute then
                return state.execute(command, options)
            end
            return ""
        end,
    }
    package.loaded.log = {
        warn = function(message)
            table.insert(state.warnings, message)
        end,
    }
    PLUGIN = {}
    RUNTIME = { archType = "amd64", osType = "linux" }
    dofile(root .. "/lib/utils.lua")
    package.loaded.utils = true
    dofile(root .. "/hooks/backend_list_versions.lua")
    dofile(root .. "/hooks/backend_install.lua")
    dofile(root .. "/hooks/backend_exec_env.lua")
end

local function equal(actual, expected)
    assert(actual == expected, "Expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function contains(actual, expected)
    assert(actual:find(expected, 1, true), "Expected " .. expected .. " in " .. actual)
end

local function raises(callback, text)
    local ok, failure = pcall(callback)
    assert(not ok, "Expected failure")
    contains(tostring(failure), text)
end

local function test(name, callback)
    reset()
    local ok, failure = xpcall(callback, debug.traceback)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n" .. tostring(failure))
    end
end

local function tools()
    ensure_cmdline_tools = function() end
    available_sdk_tools = function()
        return {
            { kind = "android", path = "/SDK's tools/android" },
            { kind = "sdkmanager", path = "/SDK's tools/sdkmanager" },
        }
    end
end

local function installed_platform_tools(revision)
    state.files["/sdk/platform-tools"] = true
    state.files["/sdk/platform-tools/adb"] = true
    state.files["/sdk/platform-tools/source.properties"] = "Pkg.Revision=" .. revision .. "\nPkg.Path=platform-tools\n"
end

test("command-line tooling helpers are available before discovery runs", function()
    equal(type(ensure_cmdline_tools), "function")
    equal(type(find_cmdline_tools_source), "function")
end)

test("pipe and whitespace single-version listings", function()
    equal(parse_versions("platform-tools", "  platform-tools | 36.0.0 | Platform tools\n")[1], "36.0.0")
    equal(parse_versions("emulator", "emulator 36.6.11 Android Emulator\n")[1], "36.6.11")
    equal(#parse_versions("emulator", "emulator | Version | Description\n"), 0)
    equal(#parse_versions("emulator", "emulator Version Description\n"), 0)
end)

test("numeric order, separators and deduplication", function()
    local versions = parse_versions(
        "cmake",
        [[
  cmake;3.10.2.4988404 | 3.10.2 | CMake
  cmake;3.6.4111459 | 3.6 | CMake
cmake/3.10.2.4988404 3.10.2 CMake
cmake/4.0.2 4.0.2 CMake
]]
    )
    equal(table.concat(versions, ","), "3.6.4111459,3.10.2.4988404,4.0.2")
end)

test("preview releases precede stable releases", function()
    local versions = parse_versions(
        "build-tools",
        [[
build-tools/36.0.0 36.0.0 Stable
build-tools/36.0.0-rc10 36.0.0-rc10 Preview
build-tools/36.0.0-rc2 36.0.0-rc2 Preview
build-tools/35.0.1 35.0.1 Stable
]]
    )
    equal(table.concat(versions, ","), "35.0.1,36.0.0-rc2,36.0.0-rc10,36.0.0")
end)

test("platform API order", function()
    equal(
        table.concat(parse_versions("platforms", "platforms;android-10 | 2 |\nplatforms;android-9 | 2 |\n"), ","),
        "android-9,android-10"
    )
end)

test("system images match installation tag and host ABI", function()
    local listing = [[
system-images;android-22;google_apis;x86_64 | 1 | Google APIs
system-images;android-35;google_apis_playstore;arm64-v8a | 1 | Play Store
system-images/android-36/google_apis_playstore/x86_64 1 Play Store
system-images;android-34;google_apis_playstore;x86_64 | 1 | Play Store
]]
    equal(table.concat(parse_versions("system-images", listing), ","), "android-34,android-36")
    for _, arch in ipairs({ "arm64", "aarch64" }) do
        RUNTIME.archType = arch
        equal(table.concat(parse_versions("system-images", listing), ","), "android-35")
        equal(
            build_package_name("system-images", "android-35"),
            "system-images;android-35;google_apis_playstore;arm64-v8a"
        )
        contains(resolve_package_dir("/sdk", "system-images", "android-35"), "/arm64-v8a")
    end
end)

test("missing discovery directories do not run failing commands", function()
    state.env.MISE_DATA_DIR = "/missing"
    equal(#find_android_sdk_roots(), 0)
    equal(find_binary_in_root("/empty-sdk", "android"), nil)
    equal(#state.commands, 0)
end)

test("stable SDK root does not block a discovered SDK", function()
    state.env.ANDROID_HOME = "/stable"
    state.env.MISE_DATA_DIR = "/mise"
    state.files["/mise/installs"] = true
    state.files["/mise/installs/android-sdk/22/cmdline-tools"] = true
    state.files["/mise/installs/android-sdk/22/cmdline-tools/latest/bin/android"] = true
    state.execute = function(command)
        assert(command:match("^find "), command)
        return "/mise/installs/android-sdk/22/cmdline-tools/latest/bin/android\n"
    end
    equal(find_sdk_binary("android"), "/mise/installs/android-sdk/22/cmdline-tools/latest/bin/android")
end)

test("missing roots still allow PATH fallback", function()
    state.env.ANDROID_HOME = "/stable"
    state.files["/external/sdkmanager"] = true
    state.execute = function(command)
        contains(command, "command -v 'sdkmanager'")
        return "/external/sdkmanager\n"
    end
    equal(find_sdk_binary("sdkmanager"), "/external/sdkmanager")
end)

test("discovery errors remain visible", function()
    state.files["/sdk/cmdline-tools"] = true
    state.execute = function()
        error("Permission denied")
    end
    raises(function()
        find_binary_in_root("/sdk", "android")
    end, "Permission denied")
end)

test("listing tries sdkmanager after android failure", function()
    tools()
    state.execute = function(command)
        if command:find(" sdk list", 1, true) then
            error("android unavailable")
        end
        contains(command, shell_quote("/SDK's tools/sdkmanager"))
        return "  platform-tools | 36.0.0 | Platform tools\n"
    end
    equal(PLUGIN:BackendListVersions({ tool = "platform-tools" }).versions[1], "36.0.0")
    equal(#state.commands, 2)
end)

test("listing reports all command failures", function()
    tools()
    state.execute = function(command)
        error(command:find(" sdk list", 1, true) and "android failed" or "sdkmanager failed")
    end
    raises(function()
        PLUGIN:BackendListVersions({ tool = "emulator" })
    end, "sdkmanager failed")
    equal(#state.commands, 2)
end)

test("empty successful listing and absent tooling remain empty", function()
    tools()
    equal(#PLUGIN:BackendListVersions({ tool = "system-images" }).versions, 0)
    available_sdk_tools = function()
        return {}
    end
    equal(#PLUGIN:BackendListVersions({ tool = "platform-tools" }).versions, 0)
end)

for _, tool in ipairs({ "platform-tools", "emulator" }) do
    for _, revision in ipairs({ "37.0.1", "36.0.0" }) do
        test(tool .. " revision drift to " .. revision .. " warns and writes an installation marker", function()
            tools()
            sdk_install_root = function()
                return "/sdk"
            end
            local directory = "/sdk/" .. tool
            state.files[directory .. "/" .. (tool == "emulator" and "emulator" or "adb")] = true
            state.files[directory .. "/source.properties"] = "Pkg.Revision=" .. revision .. "\nPkg.Path=" .. tool

            PLUGIN:BackendInstall({ tool = tool, version = "37.0.0", install_path = "/marker" })

            equal(#state.warnings, 1)
            contains(
                state.warnings[1],
                tool .. ": installed revision " .. revision .. " differs from mise's resolved version 37.0.0"
            )
            contains(state.warnings[1], "using the installed revision")
            contains(state.warnings[1], "cannot pin this shared package")
            contains(state.warnings[1], "configured/locked revisions are advisory")
            equal(#state.commands, 4)
            contains(state.commands[2].command, " sdk install ")
            equal(state.commands[2].options.env.ANDROID_SDK_ROOT, "/sdk")
            equal(state.commands[4].command, "printf '%s\\n' " .. shell_quote(tool) .. " > '/marker/.installed'")
        end)
    end
end

test("matching singleton revision does not warn", function()
    tools()
    installed_platform_tools("36.0.0")
    install_package("platform-tools", "36.0.0", "/sdk")
    equal(#state.warnings, 0)
end)

test("failed install cannot reuse a stale directory or write a marker", function()
    tools()
    installed_platform_tools("35.0.0")
    state.execute = function(command)
        if command:match("^mkdir ") then
            return ""
        end
        error("download failed")
    end
    raises(function()
        PLUGIN:BackendInstall({ tool = "platform-tools", version = "36.0.0", install_path = "/marker" })
    end, "download failed")
    for _, entry in ipairs(state.commands) do
        assert(not entry.command:find(".installed", 1, true))
    end
end)

test("sdkmanager installs after android install fails", function()
    tools()
    installed_platform_tools("36.0.0")
    state.execute = function(command)
        if command:find(" sdk install", 1, true) then
            error("android failed")
        end
        return ""
    end
    install_package("platform-tools", "36.0.0", "/sdk")
    equal(#state.commands, 4)
    contains(state.commands[3].command, "--licenses")
    contains(state.commands[4].command, "--install")
end)

test("sdkmanager fallback accepts revision drift with a warning and installation marker", function()
    tools()
    sdk_install_root = function()
        return "/sdk"
    end
    state.execute = function(command)
        if command:find(" sdk install", 1, true) then
            error("android failed")
        elseif command:find(" --install ", 1, true) then
            installed_platform_tools("37.0.1")
        end
        return ""
    end

    PLUGIN:BackendInstall({ tool = "platform-tools", version = "37.0.0", install_path = "/marker" })

    equal(#state.warnings, 1)
    contains(state.warnings[1], "installed revision 37.0.1 differs from mise's resolved version 37.0.0")
    equal(#state.commands, 6)
    contains(state.commands[3].command, "--licenses")
    contains(state.commands[4].command, "--install")
    equal(state.commands[6].command, "printf '%s\\n' 'platform-tools' > '/marker/.installed'")
end)

test("successful command without metadata retries and fails", function()
    tools()
    state.files["/sdk/platform-tools/adb"] = true
    raises(function()
        install_package("platform-tools", "36.0.0", "/sdk")
    end, "revision metadata")
    equal(#state.commands, 4)
end)

test("missing payload and wrong identity fail verification", function()
    installed_platform_tools("36.0.0")
    state.files["/sdk/platform-tools/adb"] = nil
    local revision, failure = installed_package_revision("/sdk", "platform-tools", "36.0.0")
    equal(revision, nil)
    contains(failure, "payload")
    state.files["/sdk/platform-tools/adb"] = true
    state.files["/sdk/platform-tools/source.properties"] = "Pkg.Revision=36.0.0\nPkg.Path=emulator"
    revision, failure = installed_package_revision("/sdk", "platform-tools", "36.0.0")
    equal(revision, nil)
    contains(failure, "identity")
end)

test("XML metadata and platform package revisions", function()
    state.files["/sdk/platforms/android-36/android.jar"] = true
    state.files["/sdk/platforms/android-36/package.xml"] = [[
<localPackage path="platforms;android-36" obsolete="false">
  <revision><major>2</major></revision>
</localPackage>
]]
    equal(installed_package_revision("/sdk", "platforms", "android-36"), "2.0.0")
end)

test("XML identity is checked even with legacy source properties", function()
    installed_platform_tools("36.0.0")
    state.files["/sdk/platform-tools/source.properties"] = "Pkg.Revision=36.0.0\n"
    state.files["/sdk/platform-tools/package.xml"] =
        '<localPackage path="emulator"><revision><major>36</major></revision></localPackage>'
    local revision, failure = installed_package_revision("/sdk", "platform-tools", "36.0.0")
    equal(revision, nil)
    contains(failure, "identity")
end)

test("metadata supports every package family without confusing API and revision", function()
    local cases = {
        { "build-tools", "36.0.0", "aapt", "36.0.0" },
        { "platforms", "android-36", "android.jar", "2" },
        { "system-images", "android-36", "system.img", "9" },
        { "ndk", "27.2.12479018", "ndk-build", "27.2.12479018" },
        { "cmake", "3.10.2.4988404", "bin/cmake", "3.10.2" },
        { "emulator", "36.6.11", "emulator", "36.6.11" },
    }
    for _, entry in ipairs(cases) do
        local tool, version, payload, revision = entry[1], entry[2], entry[3], entry[4]
        local directory = resolve_package_dir("/sdk", tool, version)
        state.files[directory .. "/" .. payload] = true
        state.files[directory .. "/source.properties"] = "Pkg.Revision=" .. revision
        equal(installed_package_revision("/sdk", tool, version), revision)
    end
end)

test("missing package after android success still tries sdkmanager", function()
    tools()
    state.execute = function(command)
        if command:find(" --install ", 1, true) then
            installed_platform_tools("36.0.0")
        end
        return ""
    end
    install_package("platform-tools", "36.0.0", "/sdk")
    equal(#state.commands, 4)
end)

test("sdkmanager license failures prevent install", function()
    state.execute = function()
        error("license failure")
    end
    local ok, failure = run_install({ kind = "sdkmanager", path = "/sdkmanager" }, "platform-tools", "/sdk")
    equal(ok, false)
    contains(failure, "license failure")
    equal(#state.commands, 1)
end)

test("activation repair failures produce a warning", function()
    tools()
    state.execute = function()
        error("offline")
    end
    ensure_package_installed("/sdk", "platform-tools", "36.0.0")
    equal(#state.warnings, 1)
    contains(state.warnings[1], "offline")
end)

test("activation repair accepts revision drift with a mismatch warning", function()
    tools()
    sdk_install_root = function()
        return "/sdk"
    end
    state.execute = function(command)
        if command:find(" sdk install", 1, true) then
            installed_platform_tools("37.0.1")
        end
        return ""
    end

    local result = PLUGIN:BackendExecEnv({ tool = "platform-tools", version = "37.0.0", install_path = "/marker" })

    equal(#state.warnings, 1)
    contains(state.warnings[1], "installed revision 37.0.1 differs from mise's resolved version 37.0.0")
    contains(state.warnings[1], "using the installed revision")
    assert(not state.warnings[1]:find("Could not repair", 1, true))
    equal(#state.commands, 2)
    equal(result.env_vars[3].value, "/sdk/platform-tools")

    PLUGIN:BackendExecEnv({ tool = "platform-tools", version = "37.0.0", install_path = "/marker" })
    equal(#state.warnings, 1)
    equal(#state.commands, 2)
end)

test("shell quoting preserves spaces and apostrophes", function()
    local value = "SDK's folder/$literal;name"
    local pipe = assert(io.popen("printf '%s' " .. shell_quote(value), "r"))
    equal(pipe:read("*a"), value)
    assert(pipe:close())
end)

test("discovery commands quote paths", function()
    state.env.MISE_DATA_DIR = "/mise's data"
    state.files["/mise's data/installs"] = true
    state.files["/SDK's folder/cmdline-tools"] = true
    find_android_sdk_roots()
    find_binary_in_root("/SDK's folder", "android")
    contains(state.commands[1].command, shell_quote("/mise's data/installs"))
    contains(state.commands[2].command, shell_quote("/SDK's folder/cmdline-tools"))
end)

test("installer commands quote executable and package paths", function()
    local target = "/SDK's folder"
    local ok = run_install({ kind = "sdkmanager", path = "/CLI's folder/sdkmanager" }, "build-tools;36.0.0", target)
    assert(ok)
    contains(state.commands[1].command, shell_quote("/CLI's folder/sdkmanager"))
    contains(state.commands[1].command, "--sdk_root=" .. shell_quote(target))
    contains(state.commands[2].command, "--install 'build-tools;36.0.0'")
    run_install({ kind = "android", path = "/CLI's folder/android" }, "build-tools;36.0.0", target)
    contains(state.commands[3].command, shell_quote("/CLI's folder/android"))
    contains(state.commands[3].command, "'build-tools/36.0.0'")
    equal(state.commands[3].options.env.ANDROID_HOME, target)
end)

test("marker writes succeed in real paths with spaces and apostrophes", function()
    ensure_cmdline_tools = function() end
    install_package = function() end
    state.execute = function(command)
        local pipe = assert(io.popen(command .. " 2>&1", "r"))
        local output = pipe:read("*a")
        assert(pipe:close(), output)
        return output
    end
    local path = temporary .. "/mise's install path"
    PLUGIN:BackendInstall({ tool = "build-tools", version = "36.0.0", install_path = path })
    local marker = assert(io.open(path .. "/.installed", "r"))
    equal(marker:read("*a"), "build-tools;36.0.0\n")
    marker:close()
end)

test("command-line tooling prefers the active dependency over newer discovered installs", function()
    state.env.ANDROID_HOME = "/sdk"
    state.env.ANDROID_SDK_ROOT = "/active"
    state.files["/active/cmdline-tools"] = true
    state.files["/active/cmdline-tools/latest/bin/sdkmanager"] = true
    equal(find_cmdline_tools_source("/sdk"), "/active/cmdline-tools")
    equal(#state.commands, 0)
end)

test("command-line tooling uses PATH before fallback discovery and skips its own root", function()
    state.env.ANDROID_HOME = "/sdk"
    state.env.ANDROID_SDK_ROOT = "/sdk"
    state.files["/active/cmdline-tools"] = true
    state.files["/active/cmdline-tools/latest/bin/sdkmanager"] = true
    state.execute = function(command)
        contains(command, "command -v 'sdkmanager'")
        return "/active/cmdline-tools/latest/bin/sdkmanager\n"
    end
    equal(find_cmdline_tools_source("/sdk"), "/active/cmdline-tools")
end)

test("command-line tooling falls back to discovered dependencies", function()
    state.env.MISE_DATA_DIR = "/mise"
    state.files["/mise/installs"] = true
    state.files["/mise/installs/android-sdk/22/cmdline-tools"] = true
    state.files["/mise/installs/android-sdk/22/cmdline-tools/latest/bin/android"] = true
    state.execute = function(command)
        if command:match("^find ") then
            return "/mise/installs/android-sdk/22/cmdline-tools/latest/bin/android\n"
        end
        return ""
    end
    equal(find_cmdline_tools_source("/sdk"), "/mise/installs/android-sdk/22/cmdline-tools")
end)

test("missing command-line dependency fails install and warns on activation", function()
    sdk_install_root = function()
        return "/sdk"
    end
    raises(function()
        PLUGIN:BackendInstall({ tool = "platform-tools", version = "36.0.0", install_path = "/marker" })
    end, "install android-sdk")
    installed_platform_tools("36.0.0")
    local result = PLUGIN:BackendExecEnv({ tool = "platform-tools", version = "36.0.0", install_path = "/marker" })
    equal(#state.warnings, 1)
    contains(state.warnings[1], "Could not expose cmdline-tools")
    equal(result.env_vars[1].value, "/sdk")
    equal(result.env_vars[2].value, "/sdk")
end)

local function real_filesystem()
    state.execute = function(command)
        local pipe = assert(io.popen("{\n" .. command .. "\n} 2>&1", "r"))
        local output = pipe:read("*a")
        assert(pipe:close(), output)
        return output
    end
    package.loaded.file.exists = function(path)
        return os.execute("test -e " .. shell_quote(path)) == true
    end
end

local function fixture_tools(path)
    assert(os.execute("mkdir -p " .. shell_quote(path .. "/cmdline-tools/latest/bin")))
    local binary = assert(io.open(path .. "/cmdline-tools/latest/bin/sdkmanager", "w"))
    binary:write("#!/bin/sh\nprintf 'fixture sdkmanager\\n'\n")
    binary:close()
    assert(os.execute("chmod +x " .. shell_quote(path .. "/cmdline-tools/latest/bin/sdkmanager")))
end

test("installation and activation expose tooling and repair switched or removed dependencies", function()
    real_filesystem()
    local sdk = temporary .. "/SDK's stable root"
    local first, second = temporary .. "/dependency 20", temporary .. "/dependency's 22"
    fixture_tools(first)
    fixture_tools(second)
    state.env.ANDROID_HOME = first
    sdk_install_root = function()
        return sdk
    end
    install_package = function(_, _, target)
        equal(target, sdk)
        assert(package.loaded.file.exists(sdk .. "/cmdline-tools/latest/bin/sdkmanager"))
    end
    ensure_package_installed = function(target)
        equal(target, sdk)
    end
    PLUGIN:BackendInstall({ tool = "platform-tools", version = "36.0.0", install_path = temporary .. "/link marker" })
    local function check(source)
        equal(state.execute("readlink " .. shell_quote(sdk .. "/.mise-cmdline-tools")), source .. "/cmdline-tools\n")
        equal(state.execute(shell_quote(sdk .. "/cmdline-tools/latest/bin/sdkmanager")), "fixture sdkmanager\n")
    end
    check(first)
    for _ = 1, 2 do
        local result = PLUGIN:BackendExecEnv({ tool = "platform-tools", version = "36.0.0", install_path = "/marker" })
        equal(result.env_vars[1].value, sdk)
        equal(result.env_vars[2].value, sdk)
        equal(result.env_vars[3].value, sdk .. "/platform-tools")
        check(first)
    end
    state.env.ANDROID_HOME = second
    PLUGIN:BackendExecEnv({ tool = "platform-tools", version = "36.0.0", install_path = "/marker" })
    check(second)
    assert(os.execute("mv " .. shell_quote(second) .. " " .. shell_quote(second .. ".removed")))
    state.env.ANDROID_HOME = first
    PLUGIN:BackendExecEnv({ tool = "platform-tools", version = "36.0.0", install_path = "/marker" })
    check(first)
    equal(#state.warnings, 0)
end)

test("existing user tooling and links are preserved", function()
    real_filesystem()
    local sdk, linked = temporary .. "/user SDK", temporary .. "/user linked SDK"
    fixture_tools(sdk)
    ensure_cmdline_tools(sdk)
    assert(not package.loaded.file.exists(sdk .. "/.mise-cmdline-tools"))
    assert(os.execute("mkdir -p " .. shell_quote(linked)))
    assert(
        os.execute("ln -s " .. shell_quote(sdk .. "/cmdline-tools") .. " " .. shell_quote(linked .. "/cmdline-tools"))
    )
    ensure_cmdline_tools(linked)
    equal(state.execute("readlink " .. shell_quote(linked .. "/cmdline-tools")), sdk .. "/cmdline-tools\n")
end)

test("incomplete directories and broken user links are reported without replacement", function()
    real_filesystem()
    local sdk = temporary .. "/incomplete SDK"
    assert(os.execute("mkdir -p " .. shell_quote(sdk .. "/cmdline-tools")))
    raises(function()
        ensure_cmdline_tools(sdk)
    end, "user-owned path is incomplete")
    assert(os.execute("rmdir " .. shell_quote(sdk .. "/cmdline-tools")))
    assert(os.execute("ln -s /nonexistent-sdk-fixture " .. shell_quote(sdk .. "/cmdline-tools")))
    raises(function()
        ensure_cmdline_tools(sdk)
    end, "user-owned path is incomplete")
    equal(state.execute("readlink " .. shell_quote(sdk .. "/cmdline-tools")), "/nonexistent-sdk-fixture\n")
end)

test("aliases cannot create command-line tooling link cycles", function()
    real_filesystem()
    local sdk, alias = temporary .. "/cycle SDK", temporary .. "/cycle alias"
    fixture_tools(sdk .. "/nested")
    assert(os.execute("ln -s " .. shell_quote(sdk .. "/nested") .. " " .. shell_quote(alias)))
    state.env.ANDROID_HOME = alias
    raises(function()
        ensure_cmdline_tools(sdk)
    end, "inside the stable SDK root")
    assert(not package.loaded.file.exists(sdk .. "/cmdline-tools"))
end)

print(string.format("Regression results: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
