-- metadata.lua
-- mise backend plugin — wraps Android's sdkmanager to manage SDK packages.
-- Each tool corresponds to one SDK package family or explicit system-image variant.

PLUGIN = { -- luacheck: ignore
    name = "android-sdkmanager",
    version = "1.5.0",
    description = "Manages packages inside the selected android-sdk dependency",
    author = "chbiel",
    homepage = "https://github.com/chbiel/mise-android-sdkmanager",
    license = "MIT",
    depends = { "android-sdk", "java" },
    notes = {
        "Requires android-sdk (vfox:mise-plugins/vfox-android-sdk) and java as dependencies",
        "Configure android-sdk and java versions; the plugin declares these dependencies",
        "Packages live inside the selected android-sdk root; command-line tools remain dependency-owned",
        "After switching android-sdk versions, force-install all configured package tools",
        "The cmdline_tools option has been removed; select the android-sdk dependency instead",
        "Supported tools: build-tools, platforms, platform-tools, emulator, system-images, ndk, cmake",
        "Use system-images/<flavor>/<abi> for explicit image identities; the version is the Android API level",
        "Activation is read-only; retry missing packages with mise install --force <configured-tool>",
    },
}
