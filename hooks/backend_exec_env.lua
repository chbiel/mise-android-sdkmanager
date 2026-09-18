require("utils")

--- Advertises PATH entries for sdkmanager tools that install runnable binaries and
--- pins the SDK root to a stable, plugin-owned directory.
---
--- Packages are installed into a stable root (sdk_install_root()) rather than into the
--- android-sdk tool's own versioned directory. We therefore export ANDROID_SDK_ROOT /
--- ANDROID_HOME pointing at that stable root, overriding the value the android-sdk
--- dependency exports. This keeps every package under one unified root that survives
--- android-sdk upgrades and that Gradle/AGP can consume.
---
--- It also self-heals drift: if a tracked package is missing from the stable root (e.g.
--- it was deleted), it is transparently reinstalled before its PATH entry is exported.
--- @param ctx {tool: string, version: string, install_path: string} Context
--- @return {env_vars: table[]} Environment entries for this tool
function PLUGIN:BackendExecEnv(ctx) -- luacheck: ignore
    local sdk_root = sdk_install_root()

    local ok, failure = pcall(ensure_cmdline_tools, sdk_root)
    if not ok then
        require("log").warn("Could not expose cmdline-tools: " .. tostring(failure))
    end
    ensure_package_installed(sdk_root, ctx.tool, ctx.version)

    local env_vars = {
        { key = "ANDROID_SDK_ROOT", value = sdk_root },
        { key = "ANDROID_HOME", value = sdk_root },
    }

    local bin_path = resolve_bin_path(sdk_root, ctx.tool, ctx.version)
    if bin_path then
        table.insert(env_vars, { key = "PATH", value = bin_path })
    end

    return { env_vars = env_vars }
end
