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
    -- so switching/upgrading android-sdk never loses the installed packages. Prefers
    -- sdkmanager, falling back to `android sdk install` for packages sdkmanager can no
    -- longer install (e.g. emulator in cmdline-tools 22+).
    install_package(tool, version, sdk_install_root())

    -- Write a marker so mise can track this tool version as installed.
    cmd.exec("mkdir -p " .. install_path)
    cmd.exec("printf '%s\\n' '" .. package_name .. "' > " .. install_path .. "/.installed")

    return {}
end
