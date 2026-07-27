require("utils")

--- Installs an sdkmanager package family at the requested version.
--- @param ctx {tool: string, version: string, install_path: string} Context
--- @return table Empty table on success
function PLUGIN:BackendInstall(ctx) -- luacheck: ignore
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path
    local cmd = require("cmd")

    local info = locate_sdk_tool()
    local package_name = build_package_name(tool, version)
    install_package(info, package_name)

    -- Write a marker so mise can track this tool version as installed.
    cmd.exec("mkdir -p " .. install_path)
    cmd.exec("printf '%s\\n' '" .. package_name .. "' > " .. install_path .. "/.installed")

    return {}
end
