--- Advertises PATH entries for sdkmanager tools that install runnable binaries.
--- android-sdk (vfox:mise-plugins/vfox-android-sdk) exports ANDROID_SDK_ROOT,
--- so we build the correct paths here instead of using manual _.path entries in mise.toml.
--- @param ctx {tool: string, version: string, install_path: string} Context
--- @return {env_vars: table[]} PATH entries for this tool
function PLUGIN:BackendExecEnv(ctx) -- luacheck: ignore
    local sdk_root = os.getenv("ANDROID_SDK_ROOT") or os.getenv("ANDROID_HOME")
    if not sdk_root or sdk_root == "" then
        return { env_vars = {} }
    end

    local bin_path = resolve_bin_path(sdk_root, ctx.tool, ctx.version)
    if not bin_path then
        return { env_vars = {} }
    end

    return { env_vars = { { key = "PATH", value = bin_path } } }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Returns the bin directory for the given tool, or nil if the tool has no runnable binaries.
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
