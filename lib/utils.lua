local packages = require("packages")

NO_VERSION_TOOLS = { emulator = true, ["platform-tools"] = true } -- luacheck: ignore

function shell_quote(value) -- luacheck: ignore
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function with_sdk_lock(sdk_root, operation, callback) -- luacheck: ignore
    return require("sdk_lock").with_lock(sdk_root, operation, callback)
end

function system_image_abi() -- luacheck: ignore
    return packages.host_abi()
end

function valid_sdk_revision(version) -- luacheck: ignore
    return packages.valid_revision(version)
end

function build_package_name(tool, version) -- luacheck: ignore
    return packages.describe(tool, version).id
end

function resolve_package_dir(sdk_root, tool, version) -- luacheck: ignore
    return packages.directory(sdk_root, packages.describe(tool, version))
end

function resolve_bin_path(sdk_root, tool, version) -- luacheck: ignore
    return packages.bin_path(sdk_root, packages.describe(tool, version))
end

function installed_package_revision(sdk_root, tool, version) -- luacheck: ignore
    return packages.installed_revision(sdk_root, packages.describe(tool, version))
end

function revision_warning(tool, version, revision) -- luacheck: ignore
    return tool
        .. ": installed revision "
        .. revision
        .. " differs from mise's resolved version "
        .. version
        .. ". The SDK installer cannot pin this shared package; configured/locked revisions are advisory"
end

--- Caller holds the root lock. Reuse payloads, but never turn an installer failure into success.
function install_package(tool, version, sdk_root, options, selected) -- luacheck: ignore
    options = packages.options(tool, options)
    local package = packages.describe(tool, version)
    local revision = packages.installed_revision(sdk_root, package)
    if revision and (not package.singleton or packages.same_revision(revision, version)) then
        return revision
    end

    local sdk_tools = require("sdk_tools")
    selected = selected or sdk_tools.resolve()
    local errors = {}
    for _, info in ipairs(selected.tools) do
        local ok, output = sdk_tools.install(info, package.id, sdk_root)
        if ok then
            local installed, failure = packages.installed_revision(sdk_root, package)
            if installed then
                if package.singleton and not packages.same_revision(installed, version) then
                    local warning = revision_warning(tool, version, installed)
                    if options.strict_revision then
                        error(warning .. "\nstrict_revision requires a matching installed revision")
                    end
                    require("log").warn(warning)
                end
                return installed
            end
            table.insert(
                errors,
                info.kind
                    .. " ("
                    .. info.path
                    .. "): validation failed after installer success: "
                    .. failure
                    .. "\nThe SDK installer may consider an incomplete package installed; "
                    .. "inspect its package.xml/source.properties and --list_installed output before recovery.\n"
                    .. output
            )
        else
            table.insert(errors, tostring(output))
        end
    end
    error("Failed to install '" .. package.id .. "' into '" .. sdk_root .. "':\n" .. table.concat(errors, "\n"))
end

function compare_versions_desc(a, b) -- luacheck: ignore
    local function parts(value)
        local result = {}
        for number in value:gmatch("%d+") do
            table.insert(result, tonumber(number))
        end
        return result
    end
    local ap, bp = parts(a), parts(b)
    for i = 1, math.max(#ap, #bp) do
        local av, bv = ap[i] or -1, bp[i] or -1
        if av ~= bv then
            return av > bv
        end
    end
    return a > b
end

--- Numeric releases sort by component, with previews before their stable release.
function compare_package_versions(a, b) -- luacheck: ignore
    if a:match("^android%-") and b:match("^android%-") then
        return compare_versions_desc(b, a)
    end
    local ac, as = a:match("^(%d[%d%.]*)(.*)$")
    local bc, bs = b:match("^(%d[%d%.]*)(.*)$")
    if not ac or not bc then
        return compare_versions_desc(b, a)
    end
    local function parts(core)
        local result = {}
        for number in core:gmatch("%d+") do
            table.insert(result, tonumber(number))
        end
        return result
    end
    local ap, bp = parts(ac), parts(bc)
    for i = 1, math.max(#ap, #bp) do
        local av, bv = ap[i] or 0, bp[i] or 0
        if av ~= bv then
            return av < bv
        end
    end
    local function preview(suffix)
        local ranks = { preview = 1, alpha = 2, beta = 3, rc = 4 }
        local label, number = suffix:lower():match("([%a]+)[%s%-_%.]*(%d*)")
        return suffix == "" and 5 or (ranks[label] or 0), tonumber(number) or 0
    end
    local ar, an = preview(as)
    local br, bn = preview(bs)
    if ar ~= br then
        return ar < br
    elseif an ~= bn then
        return an < bn
    end
    return a < b
end
