require("utils")

--- Installs an sdkmanager package family at the requested version.
--- @param ctx {tool: string, version: string, install_path: string} Context
--- @return table Empty table on success
function PLUGIN:BackendInstall(ctx) -- luacheck: ignore
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path
    local cmd = require("cmd")

    local sdkmanager = locate_sdkmanager()

    -- Accept all SDK licenses non-interactively before installing.
    cmd.exec("yes 2>/dev/null | " .. sdkmanager .. " --licenses >/dev/null 2>&1 || true")

    local package_name = build_package_name(tool, version)
    cmd.exec(sdkmanager .. " --install '" .. package_name .. "'")

    -- Write a marker so mise can track this tool version as installed.
    cmd.exec("mkdir -p " .. install_path)
    cmd.exec("printf '%s\\n' '" .. package_name .. "' > " .. install_path .. "/.installed")

    return {}
end

-- ---------------------------------------------------------------------------
-- Helpers
-- (Lua hook files are loaded in isolation — helpers cannot be shared across files)
-- ---------------------------------------------------------------------------

--- Builds the sdkmanager package identifier for a given tool/version pair.
--- system-images: selects the arch-appropriate ABI automatically.
function build_package_name(tool, version) -- luacheck: ignore
    local NO_VERSION_TOOLS = {
        emulator = true,
        ["platform-tools"] = true,
    }
    if tool == "system-images" then
        local abi = (RUNTIME.archType == "arm64" or RUNTIME.archType == "aarch64") and "arm64-v8a" or "x86_64"
        return "system-images;" .. version .. ";google_apis_playstore;" .. abi
    elseif NO_VERSION_TOOLS[tool] then
        return tool
    else
        return tool .. ";" .. version
    end
end
