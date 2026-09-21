local M = {}

local families = {
    ["platform-tools"] = { singleton = true, payload = "adb", bin = "" },
    emulator = { singleton = true, payload = "emulator", bin = "" },
    ["build-tools"] = { payload = "aapt", bin = "" },
    platforms = { payload = "android.jar" },
    ["system-images"] = { payload = "system.img" },
    ndk = { payload = "ndk-build", bin = "" },
    cmake = { payload = "bin/cmake", bin = "bin" },
}

function M.host_abi()
    return (RUNTIME.archType == "arm64" or RUNTIME.archType == "aarch64") and "arm64-v8a" or "x86_64"
end

function M.valid_revision(version)
    local core, suffix = version:match("^(%d[%d%.]*)(.*)$")
    if not core or core:sub(-1) == "." or core:find("..", 1, true) then
        return false
    end
    suffix = suffix:lower():gsub("[%s%-_%.]", "")
    return suffix == ""
        or suffix:match("^rc%d+$") ~= nil
        or suffix:match("^alpha%d+$") ~= nil
        or suffix:match("^beta%d+$") ~= nil
        or suffix:match("^preview%d+$") ~= nil
end

function M.same_revision(a, b)
    local function normalize(version)
        local core, suffix = version:match("^(%d[%d%.]*)(.*)$")
        if not core then
            return version
        end
        core = core:gsub("%d+", function(number)
            return tostring(tonumber(number))
        end)
        while core:sub(-2) == ".0" do
            core = core:sub(1, -3)
        end
        return core .. suffix:lower():gsub("[%s%-_%.]", "")
    end
    return normalize(a) == normalize(b)
end

---@class SdkPackage
---@field tool string
---@field family string
---@field singleton boolean
---@field payload string
---@field bin? string
---@field flavor? string
---@field abi? string
---@field id? string
---@field relative_path? string
---@field version? string

---@return SdkPackage
function M.describe(tool, version)
    local family, flavor, abi = tool:match("^(system%-images)/([^/]+)/([^/]+)$")
    family = family or tool
    local spec = families[family]
    if not spec then
        error("Unsupported Android SDK tool: " .. tool)
    end
    if family == "system-images" then
        flavor, abi = flavor or "google_apis_playstore", abi or M.host_abi()
        -- One spelling per identity avoids collisions in mise's kebab-cased install paths.
        if not flavor:match("^[a-z][a-z0-9_]*$") or flavor:find("__", 1, true) or flavor:sub(-1) == "_" then
            error("Invalid system-image flavor: " .. flavor)
        end
        if abi ~= "arm64-v8a" and abi ~= "armeabi-v7a" and abi ~= "x86" and abi ~= "x86_64" then
            error("Unsupported system-image ABI: " .. abi)
        end
    end
    local package = {
        tool = tool,
        family = family,
        singleton = spec.singleton == true,
        payload = spec.payload,
        bin = spec.bin,
        flavor = flavor,
        abi = abi,
    }
    if version then
        if family == "platforms" or family == "system-images" then
            if not version:match("^android%-%w[%w._%-]*$") or version:find("..", 1, true) then
                error("Invalid Android API version: " .. version)
            end
        elseif not M.valid_revision(version) then
            error("Invalid Android SDK revision: " .. version)
        end
        local id = family
        if not package.singleton then
            id = id .. ";" .. version
        end
        if family == "system-images" then
            id = id .. ";" .. flavor .. ";" .. abi
        end
        package.id = id
        package.relative_path = id:gsub(";", "/")
        package.version = version
    end
    return package
end

function M.options(tool, options)
    options = options or {}
    if options.cmdline_tools ~= nil then
        error(
            "cmdline_tools has been removed; remove this option and select the android-sdk dependency version instead"
        )
    end
    local package = M.describe(tool)
    local strict = options.strict_revision
    -- Older mise releases stringify TOML booleans before passing backend options.
    if strict == "true" then
        strict = true
    elseif strict == "false" then
        strict = false
    end
    if strict ~= nil then
        if type(strict) ~= "boolean" then
            error("strict_revision must be a boolean")
        end
        if not package.singleton then
            error("strict_revision is only supported for platform-tools and emulator")
        end
    end
    return { strict_revision = strict }
end

function M.directory(root, package)
    return require("file").join_path(root, package.relative_path)
end

function M.bin_path(root, package)
    if package.bin == nil then
        return nil
    end
    return require("file").join_path(M.directory(root, package), package.bin)
end

--- Metadata and a representative payload must agree before an installation is reused.
function M.installed_revision(root, package)
    local file = require("file")
    local directory = M.directory(root, package)
    local payload = file.join_path(directory, package.payload)
    if not file.exists(payload) then
        return nil, "Missing package payload " .. payload
    end
    local revision, package_path
    local properties = file.join_path(directory, "source.properties")
    local xml_path = file.join_path(directory, "package.xml")
    if file.exists(properties) then
        for line in file.read(properties):gmatch("[^\r\n]+") do
            local key, value = line:match("^%s*([%w%.]+)%s*=%s*(.-)%s*$")
            if key == "Pkg.Revision" then
                revision = value
            elseif key == "Pkg.Path" then
                package_path = value
            end
        end
    end
    if file.exists(xml_path) then
        local xml = file.read(xml_path)
        local attributes = xml:match("<localPackage%s+([^>]+)>")
        local identity = attributes and attributes:match("path%s*=%s*[\"']([^\"']+)[\"']")
        if identity ~= package.id then
            return nil, "Missing or unexpected package identity in " .. xml_path
        end
        package_path = package_path or identity
        local block = xml:match("<revision>%s*(.-)%s*</revision>")
        local major = block and block:match("<major>%s*(%d+)%s*</major>")
        if not revision and major then
            local minor = block:match("<minor>%s*(%d+)%s*</minor>") or "0"
            local micro = block:match("<micro>%s*(%d+)%s*</micro>") or "0"
            local preview = block:match("<preview>%s*(%d+)%s*</preview>")
            revision = major .. "." .. minor .. "." .. micro
            if preview and tonumber(preview) > 0 then
                revision = revision .. "-rc" .. preview
            end
        end
    end
    if not revision or not M.valid_revision(revision) then
        return nil, "Missing or invalid package revision metadata in " .. directory
    end
    if package_path and package_path:gsub("/", ";") ~= package.id then
        return nil, "Unexpected package identity '" .. package_path .. "' in " .. directory
    end
    if
        not package.singleton
        and package.family ~= "platforms"
        and package.family ~= "system-images"
        and not M.same_revision(revision, package.version)
    then
        return nil, "Unexpected package revision '" .. revision .. "' in " .. directory
    end
    return revision
end

return M
