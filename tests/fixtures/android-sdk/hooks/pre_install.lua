function PLUGIN:PreInstall(ctx) -- luacheck: ignore
    return { version = ctx.version }
end
