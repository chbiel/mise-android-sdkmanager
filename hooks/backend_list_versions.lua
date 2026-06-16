require "utils"

--- Lists available versions for an sdkmanager package family.
--- @param ctx {tool: string} Context — tool is the part after "android-sdkmanager:" in mise.toml
--- @return {versions: string[]} Available versions
function PLUGIN:BackendListVersions(ctx) -- luacheck: ignore
  local tool = ctx.tool

  -- These tools expose exactly one version in sdkmanager and are installed with a
  -- bare (versionless) package name. They cannot be pinned to a specific number.
  local NO_VERSION_TOOLS = {
    emulator           = true,
    ["platform-tools"] = true,
  }

  -- sdkmanager may not be available yet on a fresh machine before android-sdk is installed.
  -- Fall back to an empty list so mise can still proceed with a pinned version.
  local ok, sdkmanager = pcall(locate_sdkmanager)
  if not ok then
    return { versions = {} }
  end

  local cmd      = require("cmd")
  local output   = cmd.exec(sdkmanager .. " --list 2>/dev/null")
  local versions = {}
  local seen     = {}

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
        local api = path:match("^system%-images;(android%-%d+);")
        if api and not seen[api] then
          seen[api] = true
          table.insert(versions, api)
        end
      else
        local t, v = path:match("^([%w%-%+%.]+);(.+)$")
        if t == tool and v and not seen[v] then
          seen[v] = true
          table.insert(versions, v)
        end
      end
    end
  end

  return { versions = versions }
end
