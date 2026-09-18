require("utils")

--- Lists available versions for an sdkmanager package family.
--- @param ctx {tool: string} Context — tool is the part after "android-sdkmanager:" in mise.toml
--- @return {versions: string[]} Available versions
function PLUGIN:BackendListVersions(ctx) -- luacheck: ignore
    local tool = ctx.tool

    -- The SDK tool may not be available yet on a fresh machine before android-sdk is
    -- installed. Fall back to an empty list so mise can still proceed with a pinned version.
    local tools = available_sdk_tools()
    if #tools == 0 then
        return { versions = {} }
    end

    local cmd = require("cmd")
    local errors = {}

    for _, info in ipairs(tools) do
        local command = shell_quote(info.path) .. ((info.kind == "android") and " sdk list" or " --list")
        local ok, output = pcall(cmd.exec, command)
        if ok then
            local versions = parse_versions(tool, output)
            if #versions > 0 then
                return { versions = versions }
            end
        else
            table.insert(errors, info.kind .. ": " .. tostring(output))
        end
    end

    if #errors > 0 then
        error("Failed to list versions for '" .. tool .. "':\n" .. table.concat(errors, "\n"))
    end
    return { versions = {} }
end

--- Parses package listing output into the versions exposed for a tool family.
--- @param tool string Tool family
--- @param output string Raw listing output
--- @return string[] Versions
function parse_versions(tool, output) -- luacheck: ignore
    local versions = {}
    local seen = {}

    for line in output:gmatch("[^\n]+") do
        local path, columns = line:match("^%s*([^%s|]+)%s*(.*)$")
        local version
        if path then
            path = path:gsub("/", ";")
            if NO_VERSION_TOOLS[tool] then
                if path == tool then
                    if columns:sub(1, 1) == "|" then
                        version = columns:match("^|%s*([^|]-)%s*|")
                    else
                        version = columns:match("^(%S+)")
                    end
                    if version and not valid_sdk_revision(version) then
                        version = nil
                    end
                end
            elseif tool == "system-images" then
                local api = path:match("^system%-images;(android%-[^;]+);")
                if api and path == build_package_name(tool, api) then
                    version = api
                end
            else
                local family, value = path:match("^([^;]+);([^;]+)$")
                if family == tool then
                    version = value
                end
            end
        end
        if version and not seen[version] then
            seen[version] = true
            table.insert(versions, version)
        end
    end

    table.sort(versions, compare_package_versions)
    return versions
end
