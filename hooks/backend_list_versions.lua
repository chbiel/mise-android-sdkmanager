require("utils")

---@param ctx BackendListVersionsCtx
function PLUGIN:BackendListVersions(ctx) -- luacheck: ignore
    local tool = ctx.tool
    local options = require("packages").options(tool, ctx.options)
    local sdk_tools = require("sdk_tools")
    local selected = sdk_tools.resolve(options)
    local errors = {}

    for _, info in ipairs(selected.tools) do
        local ok, output = pcall(sdk_tools.list, info, sdk_install_root())
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
    local package = require("packages").describe(tool)
    local versions = {}
    local seen = {}
    local lower = output:lower()
    local sectioned = lower:match("available packages%s*:") ~= nil
        or lower:match("installed packages%s*:") ~= nil
        or lower:match("available updates%s*:") ~= nil
    local available = not sectioned

    for line in output:gmatch("[^\n]+") do
        local heading = line:lower():match("^%s*(.-)%s*:%s*$")
        if sectioned and heading then
            available = heading == "available packages"
        end
        local path, columns = line:match("^%s*([^%s|]+)%s*(.*)$")
        local version
        if path and available then
            path = path:gsub("/", ";")
            if package.singleton then
                if path == package.family then
                    if columns:sub(1, 1) == "|" then
                        version = columns:match("^|%s*([^|]-)%s*|")
                    else
                        version = columns:match("^(%S+)")
                    end
                    if version and not valid_sdk_revision(version) then
                        version = nil
                    end
                end
            elseif package.family == "system-images" then
                local api = path:match("^system%-images;(android%-[^;]+);")
                if api and path == build_package_name(tool, api) then
                    version = api
                end
            else
                local family, value = path:match("^([^;]+);([^;]+)$")
                if family == package.family then
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
