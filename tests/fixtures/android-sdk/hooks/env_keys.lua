function PLUGIN:EnvKeys(ctx) -- luacheck: ignore
    return {
        { key = "PATH", value = ctx.path .. "/cmdline-tools/" .. ctx.version .. "/bin" },
        { key = "ANDROID_HOME", value = ctx.path },
        { key = "ANDROID_SDK_ROOT", value = ctx.path },
    }
end
