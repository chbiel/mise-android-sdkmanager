require("utils")

--- Installs an sdkmanager package family at the requested version.
--- @param ctx {tool: string, version: string, install_path: string} Context
--- @return table Empty table on success
function PLUGIN:BackendInstall(ctx) -- luacheck: ignore
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path
    local cmd = require("cmd")

    local package_name = build_package_name(tool, version)
    -- Install into the stable, plugin-owned SDK root (not android-sdk's versioned dir),
    -- so switching/upgrading android-sdk never loses the installed packages.
    local sdk_root = sdk_install_root()
    ensure_cmdline_tools(sdk_root)
    install_package(tool, version, sdk_root)

    -- Write a marker so mise can track this tool version as installed.
    cmd.exec("mkdir -p " .. shell_quote(install_path))
    cmd.exec("printf '%s\\n' " .. shell_quote(package_name) .. " > " .. shell_quote(install_path .. "/.installed"))

    return {}
end
