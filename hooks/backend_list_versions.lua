require("utils")

--- Lists available versions for an sdkmanager package family.
--- @param ctx {tool: string} Context — tool is the part after "android-sdkmanager:" in mise.toml
--- @return {versions: string[]} Available versions
function PLUGIN:BackendListVersions(ctx) -- luacheck: ignore
    local tool = ctx.tool

    -- The SDK tool may not be available yet on a fresh machine before android-sdk is
    -- installed. Fall back to an empty list so mise can still proceed with a pinned version.
    local ok, info = pcall(locate_sdk_tool)
    if not ok then
        return { versions = {} }
    end

    local cmd = require("cmd")

    if info.kind == "android" then
        -- The new `android sdk list` output format is not yet stable/confirmed. Parse it
        -- best-effort; when nothing is recognised, return an empty list so pinned versions
        -- still resolve. sdkmanager remains the primary, tested path.
        local android_output = cmd.exec(info.path .. " sdk list 2>/dev/null")
        return { versions = parse_versions(tool, android_output, "/") }
    end

    local output = cmd.exec(info.path .. " --list 2>/dev/null")
    return { versions = parse_versions(tool, output, ";") }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- (Lua hook files are loaded in isolation — helpers cannot be shared across files)
-- ---------------------------------------------------------------------------

--- Parses package listing output into the versions exposed for a tool family.
--- @param tool string Tool family
--- @param output string Raw listing output
--- @param sep string Package path separator (";" for sdkmanager, "/" for android)
--- @return string[] Versions
function parse_versions(tool, output, sep) -- luacheck: ignore
    local versions = {}
    local seen = {}
    local sep_pat = sep:gsub("(%W)", "%%%1")

    for line in output:gmatch("[^\n]+") do
        -- sdkmanager --list rows look like:
        --   "  build-tools;36.0.0             | 36.0.0  | Android SDK Build-Tools 36"
        local path = line:match("^%s+([^%s|]+)")
        if path then
            if NO_VERSION_TOOLS[tool] then
                -- The package path is just the tool name (e.g. "emulator"); read the real
                -- version from the second pipe-delimited column.
                if path == tool then
                    local ver = line:match("|%s*([^|]-)%s*|")
                    if ver and ver ~= "" and not seen[ver] then
                        seen[ver] = true
                        table.insert(versions, ver)
                    end
                end
            elseif tool == "system-images" then
                -- Expose only the Android API level; ABI is selected at install time.
                local api = path:match("^system%-images" .. sep_pat .. "(android%-%d+)" .. sep_pat)
                if api and not seen[api] then
                    seen[api] = true
                    table.insert(versions, api)
                end
            else
                local t, v = path:match("^([%w%-%+%.]+)" .. sep_pat .. "(.+)$")
                if t == tool and v and not seen[v] then
                    seen[v] = true
                    table.insert(versions, v)
                end
            end
        end
    end

    return versions
end
