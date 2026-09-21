local M = { commands = {}, warnings = {}, readonly = false }

function M.quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.readonly_command(command)
    local normalized = command:gsub("'[^'\n]+'", "'ROOT'")
    return normalized
        == "for binary in 'ROOT'/*/bin/sdkmanager 'ROOT'/*/bin/android; do\n"
            .. 'if [ -f "$binary" ]; then printf found; break; fi\ndone'
end

function M.exec(command, options)
    table.insert(M.commands, command)
    if M.readonly and not M.readonly_command(command) then
        error("Activation attempted a command: " .. command)
    end
    local prefix = ""
    for key, value in pairs((options or {}).env or {}) do
        assert(key:match("^[%w_]+$"))
        prefix = prefix .. key .. "=" .. M.quote(value) .. " "
    end
    local pipe = assert(io.popen(prefix .. "sh -c " .. M.quote(command) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, _, status = pipe:close()
    if not ok then
        error("command exited " .. tostring(status) .. ": " .. output)
    end
    return output
end

function M.write(path, contents)
    local handle = assert(io.open(path, "w"))
    assert(handle:write(contents))
    assert(handle:close())
end

function M.read(path)
    local handle = assert(io.open(path, "r"))
    local contents = handle:read("*a")
    handle:close()
    return contents
end

function M.exists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function encode(value)
    if type(value) == "string" then
        return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
    elseif type(value) == "table" then
        local fields = {}
        for key, item in pairs(value) do
            table.insert(fields, encode(key) .. ":" .. encode(item))
        end
        table.sort(fields)
        return "{" .. table.concat(fields, ",") .. "}"
    end
    return tostring(value)
end

function M.setup(plugin)
    package.path = plugin .. "/lib/?.lua;" .. package.path
    package.preload.cmd = function()
        return { exec = M.exec }
    end
    package.preload.file = function()
        return {
            join_path = function(...)
                return table.concat({ ... }, "/"):gsub("/+", "/"):gsub("/$", "")
            end,
            exists = M.exists,
            read = M.read,
        }
    end
    package.preload.json = function()
        return { encode = encode }
    end
    package.preload.log = function()
        return {
            warn = function(message)
                table.insert(M.warnings, message)
            end,
            info = function() end,
            debug = function() end,
        }
    end
    _G.RUNTIME = { osType = "linux", archType = "amd64", pluginDirPath = plugin, version = "test" }
    _G.PLUGIN = { name = "android-sdkmanager" }
    require("utils")
end

function M.equal(actual, expected, context)
    assert(
        actual == expected,
        (context or "mismatch") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
    )
end

function M.raises(callback, expected)
    local ok, failure = pcall(callback)
    assert(not ok, "expected failure containing " .. expected)
    assert(tostring(failure):find(expected, 1, true), tostring(failure))
end

return M
