# android-sdkmanager — mise backend plugin

A [mise backend plugin](https://mise.jdx.dev/backend-plugin-development.html) that
manages Android SDK packages via `sdkmanager`. It exposes each package family as a
separate tool in the `android-sdkmanager:tool` format, e.g.:

```toml
"android-sdkmanager:build-tools" = { version = "36.0.0", depends = ["android-sdk", "java"] }
```

Requires `android-sdk` (recommended `vfox:mise-plugins/vfox-android-sdk`) and `java` installed as tools.

## How to use

### 1. Register the plugin

```bash
mise plugin install android-sdkmanager https://github.com/chbiel/mise-android-sdkmanager
```

or

```toml
[plugins]
android-sdkmanager = "https://github.com/chbiel/mise-android-sdkmanager"
```
in your `mise.toml` and run `mise install`.

### 2. Declare tools in your `mise.toml`

```toml
[tools]
"android-sdk" = "latest"          # provides sdkmanager and ANDROID_SDK_ROOT
java = "temurin-17"               # required by sdkmanager

# Ensure `depends` is always configured
"android-sdkmanager:platform-tools" = { version = "latest", depends = ["android-sdk", "java"] }
"android-sdkmanager:build-tools"    = { version = "36.0.0", depends = ["android-sdk", "java"] }
"android-sdkmanager:platforms"      = { version = "android-36", depends = ["android-sdk", "java"] }
```

Supported tools: `build-tools`, `platforms`, `platform-tools`, `emulator`,
`system-images`, `ndk`, `cmake`.

### 3. Install

```bash
mise install
```

## How it works

- **`hooks/backend_list_versions.lua`** — queries `sdkmanager --list` to enumerate
  available versions for each package family.
- **`hooks/backend_install.lua`** — runs `sdkmanager --install` for the requested
  package.
- **`hooks/backend_exec_env.lua`** — adds the installed package's `bin/` directory
  to `PATH` so tools like `adb`, `emulator`, and NDK scripts are available without
  manual `_.path` entries in `mise.toml`.

## Notes

Some sdkmanager dependencies do not have targetable version, like `emulator`. Use `latest` as their required version.
