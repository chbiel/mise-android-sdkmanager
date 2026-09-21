local plugin, root, token, mode = ...
local support = dofile(plugin .. "/tests/support.lua")
support.setup(plugin)
with_sdk_lock(root, token, function(canonical)
    if mode == "fail" then
        error("expected callback failure")
    end
    local handle = assert(io.open(canonical .. "/events", "a"))
    handle:write("start ", token, "\n")
    handle:close()
    support.exec("sleep 1")
    handle = assert(io.open(canonical .. "/events", "a"))
    handle:write("end ", token, "\n")
    handle:close()
end)
