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
- **`hooks/backend_install.lua`** — installs the requested package via the SDK tool into
  the plugin's stable SDK root (see below).
- **`hooks/backend_exec_env.lua`** — pins `ANDROID_SDK_ROOT`/`ANDROID_HOME` to the stable
  root and adds the installed package's `bin/` directory to `PATH` so tools like `adb`,
  `emulator`, and NDK scripts are available without manual `_.path` entries in
  `mise.toml`. It also self-heals (see below).

### `sdkmanager` vs. the new `android sdk` command

In newer `cmdline-tools` versions the legacy `sdkmanager` is deprecated in favour of a
new `android sdk …` command. The plugin handles both:

- It **prefers `sdkmanager`**, so existing cmdline-tools versions (e.g. v20/v21) keep the
  tested legacy behaviour.
- It **falls back to `android sdk install`** (which uses `/`-separated package names, e.g.
  `build-tools/36.0.0`, and needs no interactive license step) whenever `sdkmanager` fails
  to install a package. Starting with cmdline-tools 22 some packages (e.g. `emulator`) can
  no longer be installed via `sdkmanager` at all, so the plugin verifies the package
  landed on disk and retries with the `android` CLI when it did not.

Detection is by binary presence: the modern `android` CLI is searched for inside the
SDK's `cmdline-tools/*/bin` first, so the long-removed legacy `tools/bin/android` tool is
never picked up.

### Stable, plugin-owned SDK root

Packages are **not** installed into the `android-sdk` tool's own directory. That
directory is versioned and owned by the `android-sdk` tool, so upgrading or switching
`android-sdk` would point `ANDROID_SDK_ROOT` at a fresh, empty directory and the
previously installed packages would silently disappear.

Instead, the plugin installs every package (via `sdkmanager --sdk_root=…`) into a single
stable root it owns:

```
${MISE_DATA_DIR}/android-sdk-tools  # fallback: ~/.local/share/mise/android-sdk-tools
```

On activation, `backend_exec_env.lua` exports `ANDROID_SDK_ROOT` and `ANDROID_HOME`
pointing at this stable root, overriding the value the `android-sdk` dependency sets. The
`android-sdk` tool is then used purely to provide the `sdkmanager`/`cmdline-tools` binary
(and `java`), never as the install target.

Because the stable root never moves when `android-sdk` is upgraded, all packages coexist
in one unified root — which Gradle/AGP require — and survive tool switches. As a safety
net, if a tracked package is ever missing from the stable root (e.g. it was deleted),
`backend_exec_env.lua` transparently reinstalls it on activation.

## Notes

Some sdkmanager dependencies do not have a targetable version, like `emulator` and
`platform-tools` — sdkmanager only ever offers a single version for them. Use `latest`
as their required version in `mise.toml`. The plugin reads the real version from
`sdkmanager --list`, so `latest` resolves to that concrete number (e.g. `36.6.11`)
and mise records it in the lock file instead of the `latest` alias.
