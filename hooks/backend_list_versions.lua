require "utils"

--- Lists available versions for an sdkmanager package family.
--- @param ctx {tool: string} Context — tool is the part after "android-sdkmanager:" in mise.toml
--- @return {versions: string[]} Available versions
function PLUGIN:BackendListVersions(ctx) -- luacheck: ignore
  local tool = ctx.tool

  local NO_VERSION_TOOLS = {
    emulator           = true,
    ["platform-tools"] = true,
  }

  if NO_VERSION_TOOLS[tool] then
    return { versions = { "latest" } }
  end

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
      if tool == "system-images" then
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
