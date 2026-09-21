function PLUGIN:PostInstall(ctx) -- luacheck: ignore
    local version
    for _, info in pairs(ctx.sdkInfo) do
        version = info.version
        break
    end
    require("cmd").exec('bash "$SDK_TEST_PLUGIN/tests/fixtures/dependency/bin/install"', {
        env = { ASDF_INSTALL_PATH = ctx.rootPath, ASDF_INSTALL_VERSION = assert(version) },
    })
end
