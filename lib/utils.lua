--- Resolves the sdkmanager binary: checks PATH first, then falls back to ANDROID_SDK_ROOT.
function locate_sdkmanager() -- luacheck: ignore
  local cmd       = require("cmd")
  local file      = require("file")

  local from_path = cmd.exec("command -v sdkmanager 2>/dev/null || echo ''")
  from_path       = from_path:match("^%s*(.-)%s*$")
  if from_path ~= "" and file.exists(from_path) then
    return from_path
  end

  for _, var in ipairs({ "ANDROID_SDK_ROOT", "ANDROID_HOME" }) do
    local sdk_root = os.getenv(var)
    if sdk_root and sdk_root ~= "" then
      local candidate = locate_sdkmanager_in_root(sdk_root)
      if candidate then
        return candidate
      end
    end
  end

  error("sdkmanager not found — ensure android-sdk is installed and declared as a dependency")
end

--- Finds sdkmanager inside a single SDK root's cmdline-tools directory.
--- Prefers the "latest" install, then falls back to the highest versioned
--- directory (e.g. cmdline-tools/20.0/bin/sdkmanager).
--- @param sdk_root string Absolute path to the Android SDK root
--- @return string|nil Absolute path to sdkmanager, or nil if none found
function locate_sdkmanager_in_root(sdk_root) -- luacheck: ignore
  local cmd  = require("cmd")
  local file = require("file")

  local cmdline_tools = file.join_path(sdk_root, "cmdline-tools")

  -- Preferred: the "latest" symlink/directory.
  local latest = file.join_path(cmdline_tools, "latest", "bin", "sdkmanager")
  if file.exists(latest) then
    return latest
  end

  -- Fall back to versioned directories (e.g. "20.0"), highest version first.
  local listing = cmd.exec("ls -1 " .. cmdline_tools .. " 2>/dev/null")
  local entries = {}
  for entry in listing:gmatch("[^\n]+") do
    local name = entry:match("^%s*(.-)%s*$")
    if name ~= "" and name ~= "latest" then
      table.insert(entries, name)
    end
  end

  table.sort(entries, compare_versions_desc)

  for _, entry in ipairs(entries) do
    local candidate = file.join_path(cmdline_tools, entry, "bin", "sdkmanager")
    if file.exists(candidate) then
      return candidate
    end
  end

  return nil
end

--- Comparator sorting version-like strings in descending order.
--- Compares dot-separated numeric segments; non-numeric names sort last.
function compare_versions_desc(a, b) -- luacheck: ignore
  local function parts(v)
    local p = {}
    for n in v:gmatch("%d+") do
      table.insert(p, tonumber(n))
    end
    return p
  end

  local pa, pb = parts(a), parts(b)
  local len = math.max(#pa, #pb)
  for i = 1, len do
    local na = pa[i] or -1
    local nb = pb[i] or -1
    if na ~= nb then
      return na > nb
    end
  end

  return a > b
end
