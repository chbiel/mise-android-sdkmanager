-- metadata.lua
-- mise backend plugin — wraps Android's sdkmanager to manage SDK packages.
-- Each tool corresponds to one sdkmanager package family (build-tools, platforms, …).android-sdkmanager

PLUGIN = { -- luacheck: ignore
  name        = "android-sdkmanager",
  version     = "1.0.0",
  description = "Installs Android SDK's sdkmanager dependencies",
  author      = "chbiel",
  homepage    = "https://github.com/chbiel/mise-android-sdkmanager",
  license     = "MIT",
  notes       = {
    "Requires android-sdk (vfox:mise-plugins/vfox-android-sdk) and java as dependencies",
    "Always declare: depends = [\"android-sdk\", \"java\"]",
    "Supported tools: build-tools, platforms, platform-tools, emulator, system-images, ndk, cmake",
    "For system-images the version is the Android API level (e.g. android-36); ABI is auto-detected",
  },
}
