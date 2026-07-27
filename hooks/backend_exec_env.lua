require("utils")

--- Advertises PATH entries for sdkmanager tools that install runnable binaries.
--- android-sdk (vfox:mise-plugins/vfox-android-sdk) exports ANDROID_SDK_ROOT,
--- so we build the correct paths here instead of using manual _.path entries in mise.toml.
---
--- It also self-heals drift: packages are installed into the shared ANDROID_SDK_ROOT,
--- which is owned by the android-sdk tool. When android-sdk is upgraded to a new
--- directory the packages are absent from the new root, so we transparently reinstall
--- the missing package before exporting its PATH entry.
--- @param ctx {tool: string, version: string, install_path: string} Context
--- @return {env_vars: table[]} PATH entries for this tool
function PLUGIN:BackendExecEnv(ctx) -- luacheck: ignore
    local sdk_root = os.getenv("ANDROID_SDK_ROOT") or os.getenv("ANDROID_HOME")
    if not sdk_root or sdk_root == "" then
        return { env_vars = {} }
    end

    ensure_package_installed(sdk_root, ctx.tool, ctx.version)

    local bin_path = resolve_bin_path(sdk_root, ctx.tool, ctx.version)
    if not bin_path then
        return { env_vars = {} }
    end

    return { env_vars = { { key = "PATH", value = bin_path } } }
end
