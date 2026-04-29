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
      local candidate = file.join_path(sdk_root, "cmdline-tools", "latest", "bin", "sdkmanager")
      if file.exists(candidate) then
        return candidate
      end
    end
  end

  error("sdkmanager not found — ensure android-sdk is installed and declared as a dependency")
end
