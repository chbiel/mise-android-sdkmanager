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

- **`hooks/backend_list_versions.lua`** — enumerates available versions for each package
  family by listing packages from the SDK tool.
- **`hooks/backend_install.lua`** — installs the requested package via the SDK tool.
- **`hooks/backend_exec_env.lua`** — adds the installed package's `bin/` directory
  to `PATH` so tools like `adb`, `emulator`, and NDK scripts are available without
  manual `_.path` entries in `mise.toml`. It also self-heals (see below).

### `sdkmanager` vs. the new `android sdk` command

In newer `cmdline-tools` versions the legacy `sdkmanager` is deprecated in favour of a
new `android sdk …` command. The plugin auto-detects which to use:

- It **prefers `sdkmanager` whenever it is present and working**, so existing
  cmdline-tools versions (e.g. v20/v21) keep the tested legacy behaviour.
- It falls back to `android sdk install` (which uses `/`-separated package names, e.g.
  `build-tools/36.0.0`, and needs no interactive license step) only once `sdkmanager` is
  gone.

Detection is by binary presence: the modern `android` CLI is searched for inside the
SDK's `cmdline-tools/*/bin` first, so the long-removed legacy `tools/bin/android` tool is
never picked up.

### Self-heal after an `android-sdk` upgrade

Packages are installed into the shared `ANDROID_SDK_ROOT`, which is owned by the
`android-sdk` tool — not into this plugin's own install directory. When `android-sdk` is
upgraded, `ANDROID_SDK_ROOT` points at a new directory and the previously installed
packages are absent from it. On activation, `backend_exec_env.lua` detects a package
missing from the current SDK root and transparently reinstalls it, so upgrading
`android-sdk` no longer silently loses `build-tools`, `platforms`, and friends.

## Notes

Some sdkmanager dependencies do not have a targetable version, like `emulator` and
`platform-tools` — sdkmanager only ever offers a single version for them. Use `latest`
as their required version in `mise.toml`. The plugin reads the real version from
`sdkmanager --list`, so `latest` resolves to that concrete number (e.g. `36.6.11`)
and mise records it in the lock file instead of the `latest` alias.
