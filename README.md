# android-sdkmanager

A [mise backend plugin](https://mise.jdx.dev/backend-plugin-development.html) for Android SDK packages. It exposes each Android package family as a separate `mise` tool, for example:

```toml
"android-sdkmanager:build-tools" = { version = "36.0.0", depends = ["android-sdk", "java"] }
```

This keeps Android SDK packages managed by `mise` without forcing them into the versioned `android-sdk` tool directory.

## At a glance

- Install Android packages via `sdkmanager` or the newer `android sdk ...` command.
- Expose tools like `build-tools`, `platforms`, `platform-tools`, `emulator`, `system-images`, `ndk`, and `cmake`.
- Use a stable plugin-owned SDK root so package installs survive upgrades and tool switches.
- Automatically export `ANDROID_SDK_ROOT` and `ANDROID_HOME` for the active environment.

## Prerequisites

Install these as separate `mise` tools:

- `android-sdk` (recommended: `vfox:mise-plugins/vfox-android-sdk`)
- `java`

## Quick start

### 1. Register the plugin

```bash
mise plugin install android-sdkmanager https://github.com/chbiel/mise-android-sdkmanager
```

or add it in `mise.toml`:

```toml
[plugins]
android-sdkmanager = "https://github.com/chbiel/mise-android-sdkmanager"
```

Then run:

```bash
mise install
```

### 2. Declare Android tools

```toml
[tools]
"android-sdk" = "latest"          # provides cmdline-tools / sdkmanager and ANDROID_SDK_ROOT
java = "temurin-17"               # required by Android tools

"android-sdkmanager:platform-tools" = { version = "latest", depends = ["android-sdk", "java"] }
"android-sdkmanager:build-tools"    = { version = "36.0.0", depends = ["android-sdk", "java"] }
"android-sdkmanager:platforms"      = { version = "android-36", depends = ["android-sdk", "java"] }
```

### 3. Use the installed tools

After installation, the plugin exposes commands from the installed package directories without manual `_.path` entries. For example, `adb`, `emulator`, and Android build tools become available in the active environment.

## Supported package families

| Family | Notes |
| --- | --- |
| `build-tools` | Common Android build tools, pinned by version |
| `platforms` | Android API platforms, for example `android-36` |
| `platform-tools` | Usually versioned as `latest` because sdkmanager exposes one available revision |
| `emulator` | Same as `platform-tools`: single provided revision |
| `system-images` | Filters to host-compatible images such as `google_apis_playstore` |
| `ndk` | Native development kit packages |
| `cmake` | Android CMake package set |

## Why this plugin exists

Android SDK installs are easy to lose or duplicate when the base `android-sdk` tool is upgraded. The plugin avoids that by separating:

- the `android-sdk` tool, which provides the command-line tooling
- the plugin-managed installation root, which keeps actual Android packages stable

This matters because Gradle and Android Studio expect a single, stable SDK root.

## Quick overview: how the plugin works

The plugin acts as a `mise` backend for Android SDK packages. In practice, it does three main jobs:

1. It discovers which Android package versions are available for each package family.
2. It installs the requested package into a stable, plugin-owned SDK root instead of the versioned `android-sdk` tool directory.
3. It activates the environment so the right Android variables and `PATH` entries are present for the current shell.

The backend is split across a few hooks:

- `hooks/backend_list_versions.lua` — lists available versions for each package family.
- `hooks/backend_install.lua` — installs the requested package into the plugin's stable SDK root.
- `hooks/backend_exec_env.lua` — exports `ANDROID_SDK_ROOT` and `ANDROID_HOME`, adds package `bin/` folders to `PATH`, and repairs missing or incomplete packages when the environment loads.

## `sdkmanager` vs. `android sdk`

Newer `cmdline-tools` versions prefer the `android` CLI over the legacy `sdkmanager`. This plugin handles both.

- It prefers the modern `android` binary when present.
- It falls back to `sdkmanager` if the `android` command is missing or fails.
- When using `android sdk install`, package names are slash-separated, for example `build-tools/36.0.0`.
- If the install is incomplete or the command fails, the plugin retries with `sdkmanager`.
- A directory alone does not count as a successful install; the plugin requires command success, package metadata, and the expected payload.

The plugin detects the right binary by scanning:

1. `ANDROID_SDK_ROOT` / `ANDROID_HOME`
2. `mise` discovered `cmdline-tools/*/bin`
3. `PATH`

It prefers the new `android` binary but still falls back cleanly to `sdkmanager`.

## Stable, plugin-owned SDK root

Packages are not installed into the `android-sdk` tool directory itself. That directory is versioned and owned by `android-sdk`, so upgrades or switches would point `ANDROID_SDK_ROOT` at a fresh empty directory and silently drop previously installed packages.

Instead, the plugin installs into a single stable root it owns:

```text
${MISE_DATA_DIR}/android-sdk-tools
# fallback: ~/.local/share/mise/android-sdk-tools
```

On environment activation, `backend_exec_env.lua` overrides the `android-sdk` value so that both `ANDROID_SDK_ROOT` and `ANDROID_HOME` point to the stable root. The `android-sdk` tool is then only used to provide the Android command-line tooling and `java`.

Because that root stays fixed across upgrades, all packages coexist in one unified location, which is what Gradle and AGP expect. If a tracked package disappears from the stable root, the plugin tries to reinstall it when the hook runs. Incomplete packages are also repaired, and any repair failure is reported as a warning instead of blocking activation.

## Common gotchas

### `latest` for some package families

Some Android package families do not have a meaningful targetable revision, including `emulator` and `platform-tools`. In those cases, use `latest` in `mise.toml`.

The plugin parses revisions from `android sdk list` or `sdkmanager --list` output, which may contain both installed and available packages. This lets `latest` resolve to a concrete revision such as `36.6.11`, which mise can track for updates and record in a lockfile.

For `platform-tools` and `emulator`, the SDK installer accepts only the package name, not a target revision. If a successful, validated installation produces a different revision, the plugin warns with both revisions and uses the installed package. This also applies when the installed revision is older. Numeric pins are advisory for these two families: mise may display or lock a resolved revision that differs from the package in the shared SDK root.

Installer failures, missing payloads, invalid revision metadata, and incorrect package identities still fail installation. Other package families are unaffected.

### Recovering from a singleton revision mismatch in CI

Older plugin versions reject revision differences, for example resolving `platform-tools` to `37.0.0` but installing `37.0.1`. Update the plugin to a version containing the warning policy above, including any pinned plugin reference or cached plugin checkout in CI.

Before that update is available, try refreshing discovery and the resolved version from the consuming project, with Android SDK and Java dependencies installed:

```bash
mise cache clear android-sdkmanager:platform-tools
mise ls-remote android-sdkmanager:platform-tools
mise upgrade android-sdkmanager:platform-tools
```

Use your registered plugin name instead of `android-sdkmanager` (for example, `jds-sdkmanager`). Keep the tool configured as `latest`; if it is explicitly pinned, update that request deliberately. Refresh the lockfile outside locked CI, review the changes, and commit the updated lockfile. Clearing the cache alone does not update a locked version.

This workaround requires discovery and installation to agree on the revision. If a fresh listing still reports `37.0.0` while installation produces `37.0.1`, repeated cache clearing will not bypass the old rejection policy; update the plugin instead.

### Shared installation

These package families share a single install root and cannot provide isolated pinned versions across projects:

- `platform-tools`
- `emulator`

### `system-images`

`system-images` only lists API levels that offer `google_apis_playstore` for the current host ABI. On ARM64, the plugin prefers `arm64-v8a`; otherwise it uses `x86_64`.

## Development

Run:

```bash
mise run test --unit
```

for offline regression coverage.

The broader test command also runs isolated integration tests, which download Java and Android SDK packages:

```bash
mise run test
```
