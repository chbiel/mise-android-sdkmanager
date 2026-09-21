local plugin, parent = ...
assert(plugin and parent, "usage: regression.lua PLUGIN_DIR TEST_DIR")
local data = assert(os.getenv("MISE_DATA_DIR"), "MISE_DATA_DIR must be isolated inside TEST_DIR")
assert(data:sub(1, #parent + 1) == parent .. "/", "MISE_DATA_DIR must be isolated inside TEST_DIR")
local support = dofile(plugin .. "/tests/support.lua")
support.setup(plugin)
dofile(plugin .. "/hooks/backend_list_versions.lua")
dofile(plugin .. "/hooks/backend_exec_env.lua")
dofile(plugin .. "/hooks/backend_install.lua")

local count = 0
local function test(name, callback)
    callback()
    count = count + 1
    print("PASS: " .. name)
end
local equal, raises = support.equal, support.raises
local selected_root = parent .. "/selected-sdk"
local selected_directory = selected_root .. "/cmdline-tools/20.0"
support.exec("mkdir -p " .. support.quote(selected_directory .. "/bin"))
support.write(selected_directory .. "/bin/sdkmanager", "must not execute")
local getenv = os.getenv
local environment = {
    PATH = selected_directory .. "/bin:" .. (getenv("PATH") or ""),
    ANDROID_HOME = parent .. "/old-shared-root",
    ANDROID_SDK_ROOT = parent .. "/unselected-sdk",
}
os.getenv = function(key)
    return environment[key] or getenv(key)
end
local function versions(tool, output)
    return table.concat(parse_versions(tool, output), ",")
end
local function assert_readonly_commands()
    for _, command in ipairs(support.commands) do
        assert(support.readonly_command(command), "Activation attempted a forbidden command: " .. command)
    end
end

test("canonical package names and paths", function()
    local cases = {
        { "platform-tools", "36.0.2", "platform-tools", "/sdk/platform-tools" },
        { "emulator", "36.2.1", "emulator", "/sdk/emulator" },
        { "build-tools", "36.0.0", "build-tools;36.0.0", "/sdk/build-tools/36.0.0" },
        { "platforms", "android-36", "platforms;android-36" },
        { "ndk", "28.2.13676358", "ndk;28.2.13676358", "/sdk/ndk/28.2.13676358" },
        { "cmake", "3.22.1", "cmake;3.22.1", "/sdk/cmake/3.22.1/bin" },
        {
            "system-images/google_apis/arm64-v8a",
            "android-36",
            "system-images;android-36;google_apis;arm64-v8a",
        },
    }
    for _, case in ipairs(cases) do
        equal(build_package_name(case[1], case[2]), case[3])
        equal(resolve_package_dir("/sdk", case[1], case[2]), "/sdk/" .. case[3]:gsub(";", "/"))
        equal(resolve_bin_path("/sdk", case[1], case[2]), case[4])
    end
    equal(build_package_name("system-images", "android-36"), "system-images;android-36;google_apis_playstore;x86_64")
    RUNTIME.archType = "arm64"
    equal(build_package_name("system-images", "android-36"), "system-images;android-36;google_apis_playstore;arm64-v8a")
    RUNTIME.archType = "amd64"
end)

test("reject ambiguous identities and path traversal", function()
    for _, tool in ipairs({
        "system-images/Google_apis/arm64-v8a",
        "system-images/google-apis/arm64-v8a",
        "system-images/google__apis/arm64-v8a",
        "system-images/google_apis/arm64_v8a",
        "system-images/google_apis/arm64-v8a/extra",
        "system-images/../x86_64",
        "unknown",
    }) do
        local ok = pcall(build_package_name, tool, "android-36")
        assert(not ok, tool .. " unexpectedly accepted")
    end
    raises(function()
        build_package_name("build-tools", "../36")
    end, "Invalid")
    raises(function()
        build_package_name("platforms", "android-../36")
    end, "Invalid")
end)

local listing = [[
Installed packages:
  Path | Version | Description
  platform-tools | 1.0.0 | old
Available packages:
  Path | Version | Description
  platform-tools | 36.0.2 | current
  build-tools;36.0.0 | 36.0.0 | stable
  build-tools;9.0.0 | 9.0.0 | old
  build-tools;36.0.0-rc2 | 36.0.0-rc2 | preview
  build-tools;36.0.0-rc1 | 36.0.0-rc1 | preview
  platforms;android-36 | 2 | platform
  platforms;android-9 | 2 | platform
  system-images;android-36;google_apis;arm64-v8a | 9 | image
  system-images;android-35;google_apis_playstore;x86_64 | 9 | image
Available Updates:
  platform-tools | 1.0.0 | 36.0.2
]]
test("available listings, numeric order, previews and image identity", function()
    equal(versions("platform-tools", listing), "36.0.2")
    equal(versions("build-tools", listing), "9.0.0,36.0.0-rc1,36.0.0-rc2,36.0.0")
    equal(versions("platforms", listing), "android-9,android-36")
    equal(versions("system-images/google_apis/arm64-v8a", listing), "android-36")
    equal(versions("system-images", listing), "android-35")
    equal(versions("emulator", "emulator 36.2.1 Android Emulator\nemulator 36.2.1 Android Emulator"), "36.2.1")
    equal(versions("platform-tools", "Installed packages:\nplatform-tools | 1.0.0 | old\n"), "")
    equal(
        versions("system-images/google_apis/arm64-v8a", "system-images/android-36/google_apis/arm64-v8a 9 image"),
        "android-36"
    )
end)

test("modern dot-separated prereleases validate, normalize, and sort numerically", function()
    assert(valid_sdk_revision("36.0.0-rc.1"))
    equal(build_package_name("build-tools", "36.0.0-rc.1"), "build-tools;36.0.0-rc.1")
    equal(
        versions("emulator", "emulator 36.0.0 stable\nemulator 36.0.0-rc.10 preview\nemulator 36.0.0-rc.2 preview"),
        "36.0.0-rc.2,36.0.0-rc.10,36.0.0"
    )
    local preview = parent .. "/preview"
    support.exec("mkdir -p " .. support.quote(preview .. "/build-tools/36.0.0-rc.1"))
    support.write(preview .. "/build-tools/36.0.0-rc.1/aapt", "fake")
    support.write(
        preview .. "/build-tools/36.0.0-rc.1/source.properties",
        "Pkg.Path=build-tools;36.0.0-rc.1\nPkg.Revision=36.0.0-rc1\n"
    )
    equal(installed_package_revision(preview, "build-tools", "36.0.0-rc.1"), "36.0.0-rc1")
end)

test("hook option validation happens before tooling discovery", function()
    for _, value in ipairs({ 1, {}, "yes" }) do
        raises(function()
            PLUGIN:BackendListVersions({ tool = "emulator", options = { strict_revision = value } })
        end, "strict_revision must be a boolean")
    end
    raises(function()
        PLUGIN:BackendListVersions({ tool = "build-tools", options = { strict_revision = true } })
    end, "only supported")
    for _, value in ipairs({ false, 10, "relative/tools", "/sdk/cmdline-tools/20.0" }) do
        for _, hook in ipairs({ PLUGIN.BackendListVersions, PLUGIN.BackendInstall, PLUGIN.BackendExecEnv }) do
            raises(function()
                hook(PLUGIN, { tool = "emulator", version = "36.2.1", options = { cmdline_tools = value } })
            end, "cmdline_tools has been removed")
        end
    end
end)

local directory = parent .. "/regression"
support.exec("mkdir -p " .. support.quote(directory .. "/build-tools/36.0.0"))
local payload = directory .. "/build-tools/36.0.0/"
test("payload and revision metadata validation", function()
    equal(installed_package_revision(directory, "build-tools", "36.0.0"), nil)
    support.write(payload .. "aapt", "fake")
    equal(installed_package_revision(directory, "build-tools", "36.0.0"), nil)
    support.write(payload .. "source.properties", "Pkg.Path=build-tools;36.0.0\nPkg.Revision=36\n")
    equal(installed_package_revision(directory, "build-tools", "36.0.0"), "36")
    support.write(payload .. "source.properties", "Pkg.Path=build-tools;35.0.0\nPkg.Revision=36.0.0\n")
    equal(installed_package_revision(directory, "build-tools", "36.0.0"), nil)
    support.write(payload .. "source.properties", "Pkg.Path=build-tools;36.0.0\nPkg.Revision=35.0.0\n")
    equal(installed_package_revision(directory, "build-tools", "36.0.0"), nil)
    os.remove(payload .. "source.properties")
    support.write(
        payload .. "package.xml",
        '<localPackage path="build-tools;36.0.0"><revision><major>36</major></revision></localPackage>'
    )
    equal(installed_package_revision(directory, "build-tools", "36.0.0"), "36.0.0")
    support.write(payload .. "package.xml", '<localPackage path="build-tools;35.0.0"></localPackage>')
    equal(installed_package_revision(directory, "build-tools", "36.0.0"), nil)
end)

test("activation is read-only, nonfatal, and keeps legacy records", function()
    local root = selected_root
    support.exec(
        "mkdir -p " .. support.quote(root .. "/.mise-install-lock") .. " " .. support.quote(directory .. "/record")
    )
    support.write(directory .. "/record/.installed", "legacy marker\n")
    support.warnings = {}
    support.commands = {}
    support.readonly = true
    local result = PLUGIN:BackendExecEnv({
        tool = "platform-tools",
        version = "36.0.2",
        install_path = directory .. "/record",
        options = { strict_revision = true },
    })
    support.readonly = false
    assert_readonly_commands()
    equal(result.env_vars[1].value, root)
    equal(result.env_vars[2].value, root)
    equal(result.env_vars[3].value, root .. "/platform-tools")
    assert(#support.warnings > 0, "incomplete activation should warn")
    assert(table.concat(support.warnings, "\n"):find("mise install --force", 1, true))
    equal(support.read(directory .. "/record/.installed"), "legacy marker\n")
    assert(not support.exists(directory .. "/record/.mise-sdk-package.json"))
    assert(support.exists(root .. "/.mise-install-lock"), "activation removed lock")
    support.exec("rmdir " .. support.quote(root .. "/.mise-install-lock"))
end)

test("healthy activation does not execute installers or acquire locks", function()
    local root = selected_root
    support.exec(
        "mkdir -p " .. support.quote(root .. "/platform-tools") .. " " .. support.quote(root .. "/cmdline-tools/20/bin")
    )
    support.write(root .. "/platform-tools/adb", "fake")
    support.write(root .. "/platform-tools/source.properties", "Pkg.Path=platform-tools\nPkg.Revision=36.0.2\n")
    support.write(root .. "/cmdline-tools/20/bin/sdkmanager", "fake")
    support.warnings = {}
    support.commands = {}
    support.readonly = true
    local result = PLUGIN:BackendExecEnv({
        tool = "platform-tools",
        version = "36.0.2",
        install_path = directory .. "/record",
        options = {},
    })
    support.readonly = false
    assert_readonly_commands()
    equal(#support.warnings, 0)
    equal(result.env_vars[3].value, root .. "/platform-tools")
    assert(not support.exists(root .. "/.mise-install-lock"))
    support.readonly = true
    PLUGIN:BackendExecEnv({
        tool = "platform-tools",
        version = "35.0.0",
        install_path = directory .. "/record",
        options = { strict_revision = true },
    })
    support.readonly = false
    assert_readonly_commands()
    assert(
        table.concat(support.warnings):find("differs from mise", 1, true),
        "activation should warn about revision drift"
    )
end)

test("selected PATH wins over inherited roots and canonical aliases agree", function()
    local tools = require("sdk_tools")
    equal(tools.locate().root, selected_root)
    local alias = parent .. "/sdk-alias"
    support.exec("ln -s " .. support.quote(selected_root) .. " " .. support.quote(alias))
    local previous = environment.PATH
    environment.PATH = alias .. "/cmdline-tools/20.0/bin:" .. previous
    equal(tools.locate().root, selected_root)
    equal(tools.locate().directory, selected_directory)
    environment.PATH = "/usr/bin:/bin"
    raises(tools.locate, "install the configured android-sdk and java dependencies")
    environment.PATH = previous
end)

test("nonstandard physical tools layout fails rather than splitting roots", function()
    local physical = parent .. "/nonstandard-tools"
    local alias = parent .. "/nonstandard-sdk/cmdline-tools"
    support.exec("mkdir -p " .. support.quote(physical .. "/bin") .. " " .. support.quote(alias))
    support.write(physical .. "/bin/sdkmanager", "must not execute")
    support.exec("ln -s " .. support.quote(physical) .. " " .. support.quote(alias .. "/20"))
    local previous = environment.PATH
    environment.PATH = alias .. "/20/bin"
    raises(require("sdk_tools").locate, "unsupported physical layout")
    environment.PATH = previous
end)

test("plugin declares discovery dependencies", function()
    local previous = PLUGIN
    dofile(plugin .. "/metadata.lua")
    equal(table.concat(PLUGIN.depends, ","), "android-sdk,java")
    _G.PLUGIN = previous
end)

print(string.format("PASS: %d Lua regression groups", count))
