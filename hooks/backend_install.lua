require("utils")

---@param ctx BackendInstallCtx
function PLUGIN:BackendInstall(ctx) -- luacheck: ignore
    local packages = require("packages")
    local sdk_tools = require("sdk_tools")
    local options = packages.options(ctx.tool, ctx.options)
    local package = packages.describe(ctx.tool, ctx.version)
    local selected = sdk_tools.resolve()
    local sdk_root = selected.root
    with_sdk_lock(sdk_root, "install " .. package.id, function(locked_root)
        local revision = install_package(ctx.tool, ctx.version, locked_root, options, selected)
        require("sdk_state").write(ctx.install_path, package, ctx.version, revision, locked_root, selected.directory)
    end)
    return {}
end
