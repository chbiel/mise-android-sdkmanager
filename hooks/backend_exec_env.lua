require("utils")

---@param ctx BackendExecEnvCtx
function PLUGIN:BackendExecEnv(ctx) -- luacheck: ignore
    local packages = require("packages")
    packages.options(ctx.tool, ctx.options)
    local package = packages.describe(ctx.tool, ctx.version)
    local sdk_root = require("sdk_tools").locate().root
    local log = require("log")
    local plugin_name = (RUNTIME.pluginDirPath or ""):match("([^/]+)/?$") or "android-sdkmanager"
    local repair = " Run mise install --force "
        .. shell_quote(plugin_name .. ":" .. ctx.tool)
        .. " to retry explicitly."

    -- These checks are advisory: mise can cache this hook's environment result.
    local ok, revision, failure = pcall(packages.installed_revision, sdk_root, package)
    if not ok or not revision then
        log.warn((ok and failure or tostring(revision)) .. repair)
    elseif package.singleton and not packages.same_revision(revision, ctx.version) then
        log.warn(revision_warning(ctx.tool, ctx.version, revision))
    end

    local env_vars = {
        { key = "ANDROID_SDK_ROOT", value = sdk_root },
        { key = "ANDROID_HOME", value = sdk_root },
    }
    local bin_path = packages.bin_path(sdk_root, package)
    if bin_path then
        table.insert(env_vars, { key = "PATH", value = bin_path })
    end
    return { env_vars = env_vars }
end
