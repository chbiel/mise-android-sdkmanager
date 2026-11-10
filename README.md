# android-sdkmanager

A [mise backend plugin](https://mise.jdx.dev/backend-plugin-development.html) for Android SDK packages. It wraps `sdkmanager` and the modern `android sdk` CLI, installs packages inside the selected `android-sdk` dependency, and exports their environment and executable paths.

Requires Linux or macOS, a POSIX shell, and configured `android-sdk` and `java` tools. Windows is not supported.

## Quick start

Add this to `mise.toml`:

```toml
[plugins]
android-sdkmanager = "https://github.com/chbiel/mise-android-sdkmanager"

[tool_alias.android-sdk]
backend = "vfox:mise-plugins/vfox-android-sdk"

[tools]
android-sdk = "latest"
java = "temurin-21"

"android-sdkmanager:platform-tools" = { version = "latest", depends = ["android-sdk", "java"] }
"android-sdkmanager:build-tools" = { version = "36.0.0", depends = ["android-sdk", "java"] }
"android-sdkmanager:platforms" = { version = "android-36", depends = ["android-sdk", "java"] }
```

Install everything with one command, including on a clean machine:

```bash
mise install
```

The `depends` declarations make mise install Android command-line tools and Java before resolving and installing SDK packages. No separate dependency-install step is required. The plugin also declares these prerequisites; the examples keep the ordering explicit.

Commands such as `adb` become available in the active mise environment, without manual `_.path` entries:

```bash
mise exec -- adb version
```

If you register the plugin under another name, such as `jds-sdkmanager`, use that prefix in tool declarations and commands.

## Packages and versions

| Family | Version example | Behavior |
| --- | --- | --- |
| `build-tools` | `36.0.0` | Side-by-side versions |
| `platforms` | `android-36` | Android API platform |
| `platform-tools` | `latest` | One shared revision; includes `adb` |
| `emulator` | `latest` | One shared revision |
| `ndk` | `28.2.13676358` | Side-by-side versions |
| `cmake` | `3.22.1` | Side-by-side versions |
| `system-images` | `android-36` | Play Store image with a host-derived ABI |
| `system-images/<flavor>/<abi>` | `android-36` | Explicit image variant |

### Platform-tools and emulator

Use `latest` for these two families. Mise resolves it to a numeric revision for update tracking, but Android's installer accepts only the package name, not a target revision. **Numeric pins and lockfile revisions are advisory.** An installation attempt that finishes with a different valid revision, newer or older, produces a warning by default.

To fail installation on a revision mismatch, add `strict_revision`:

```toml
"android-sdkmanager:platform-tools" = { version = "latest", strict_revision = true, depends = ["android-sdk", "java"] }
```

This boolean option applies only to platform-tools and emulator. It checks the observed revision during installation; it cannot retrieve unavailable older releases or prevent another project from changing the shared package later. It also applies to `latest`, because mise passes its resolved number. Older mise releases that serialize booleans as `"true"`/`"false"` are supported.

Activation does not report revision mismatches. Mise also calls the environment hook when discovering executable paths for inactive installed versions during shim rebuilding; those records do not represent the current project's requested revisions. Missing or invalid package payloads still produce health warnings. To recheck a configured tool's revision explicitly, use the force-install command in [Activation and recovery](#activation-and-recovery); plain `mise install` can skip existing records.

#### Recovering from revision mismatch warnings

If platform-tools or emulator reports `installed revision ... differs from mise's resolved version ...`, mise's cached versions or lockfile may be older than the installed shared package. This can happen even with `version = "latest"`, because mise resolves `latest` to a numeric revision.

With both tools configured as `latest`, run these commands from the affected project:

```bash
mise cache clear android-sdkmanager:platform-tools android-sdkmanager:emulator
mise upgrade --no-prune android-sdkmanager:platform-tools android-sdkmanager:emulator
# Run this final command only if the project uses a mise lockfile.
mise lock --bump android-sdkmanager:platform-tools android-sdkmanager:emulator
```

Replace `android-sdkmanager` with your registered plugin name, such as `jds-sdkmanager`, in all three commands.

The commands refresh version discovery, upgrade the selected tools, and re-resolve their lockfile entries. Plain `mise lock` can preserve existing locked versions; `--bump` advances `latest`. Review the lockfile changes and commit them if the lockfile is tracked.

`--no-prune` retains the old mise installation records; it does not preserve an older copy of the shared SDK package. Upgrading can affect other projects using the same SDK root. Avoid concurrent SDK updates from Android Studio, Gradle, or manual installers.

If warnings remain, inspect fresh `mise ls-remote` results for the affected tools and compare them with package metadata in the selected SDK root. Cache and lockfile refreshes cannot fix every upstream listing or installation mismatch. Revisions remain advisory, and warnings can recur when another project or SDK tool updates a shared package.

### System images

The `system-images` shorthand selects `google_apis_playstore` with `arm64-v8a` on ARM64 hosts and `x86_64` otherwise. For explicit variants:

```toml
"android-sdkmanager:system-images/google_apis/arm64-v8a" = { version = "android-36", depends = ["android-sdk", "java"] }
"android-sdkmanager:system-images/google_apis_playstore/x86_64" = { version = "android-36", depends = ["android-sdk", "java"] }
```

Flavor and ABI are part of the tool identity, keeping mise's installation records and version caches separate. Flavors start with a lowercase letter and contain lowercase letters, digits, or single, nontrailing underscores. Supported ABIs are `arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64`; selecting one does not guarantee the host can run it.

For platforms and images, an API identifier such as `android-36` does not pin an immutable package revision. The shared SDK is not a byte-for-byte reproducible environment.

## SDK root and command-line tools

The `android-sdk` dependency owns the versioned SDK root and command-line tools. This plugin manages packages inside that same root:

```text
<selected android-sdk installation>/
  cmdline-tools/<version>/bin/
  build-tools/36.0.0/
  platforms/android-36/
  platform-tools/
```

The plugin and dependency agree on `ANDROID_HOME` and `ANDROID_SDK_ROOT`. Packages follow the dependency's lifecycle: removing its installation can remove its packages. Projects selecting the same dependency installation still share packages, including singleton revisions; this is not project isolation.

The plugin discovers the selected dependency through its injected `PATH`, not a scan for the highest installed version, a receipt, or inherited Android SDK variables. The physical tools directory must have the standard `<sdk-root>/cmdline-tools/<version>` layout. Nonstandard layouts fail with a dependency diagnostic.

The plugin prefers a capable `android sdk` CLI, falling back to `sdkmanager` from the same installation when necessary. All installers and license acceptance target that SDK root explicitly.

The plugin never copies, provisions, or links command-line tools. Keeping tools and packages together lets tools such as `apkanalyzer`, which derive their SDK root from their physical location, find installed build-tools.

### Migration from the separate shared root

1. Update this plugin.
2. Remove every `cmdline_tools` option. The option now fails with a migration error; select the desired `android-sdk` version instead.
3. Install the selected `android-sdk` and `java` dependencies.
4. Force-install **all configured package tools** without appending `@version`. This preserves their configured options and multiple versions:

   ```bash
   mise install android-sdk java
   mise install --force android-sdkmanager:build-tools android-sdkmanager:platforms android-sdkmanager:platform-tools
   ```

   Include your configured emulator, NDK, CMake, and system-image identities as applicable. For a renamed registration, use commands such as `mise install --force jds-sdkmanager:build-tools`.

5. Remove or update stale `flutter config --android-sdk` settings, `local.properties` SDK paths, and hardcoded environment or PATH overrides that still select `${MISE_DATA_DIR}/android-sdk-tools`.

The old shared root, packages, licenses, and tooling links remain untouched. Nothing is moved, copied, uninstalled, or deleted automatically. Decide whether to remove that root only after checking other consumers.

Repeat the explicit force-install step after future `android-sdk` version switches. Existing mise package records do not prove that packages exist in the newly selected SDK. Plain `mise install` can skip those records; activation does not repair them. Mise may cache activation results and warnings until explicit reinstall.

## Activation and recovery

**Activation is read-only.** It does not execute Android tools, download packages, accept licenses, write receipts, wait for the installation lock, or check revision equality. When no Android command-line tools are selected in the current environment, activation silently contributes no environment variables; unrelated mise operations can proceed without Android SDK dependencies. SDK version discovery and package installation still require those dependencies.

With a selected SDK, activation warns about detected missing package files without blocking activation, naming the affected SDK root and an explicit force-install command. Mise caches environment results, so these warnings are not continuous integrity checks.

Retry an affected configured tool explicitly:

```bash
mise install --force android-sdkmanager:build-tools
```

Without `@version`, mise preserves that tool's configured requests and options. It recreates the per-tool record, not the SDK. The plugin validates packages in the selected dependency and reuses healthy side-by-side packages without downloading them again. Packages in a previously selected SDK cannot satisfy validation. Singleton packages are reused when their revision matches; otherwise an installer attempt allows upgrades.

Plain `mise install` can skip a damaged package if mise still records it as installed. Force-install retries missing payloads, but SDK metadata can make the installer consider an incomplete package already installed. In that case, inspect the reported files, `source.properties`, `package.xml`, and installed-package listing. The plugin does not automatically uninstall shared packages, delete metadata, or wipe the SDK.

Successful installation requires valid metadata and the expected payload; failed commands are never accepted merely because files exist. An atomic `.mise-sdk-package.json` receipt records the package, resolved and observed revisions, SDK root, and tooling source. Receipts never select the installation root. Legacy `.installed` markers remain compatible and are not migrated during activation. Removing a package tool's mise record leaves SDK packages intact; removing the `android-sdk` dependency can remove them.

### CI caches

Use the same single `mise install` for clean runners and intact restored installations. Cache the selected `android-sdk` dependency, including its packages, together with mise's package records. Key caches by Android SDK and Java versions, configured package versions, OS, and architecture. Keep restored paths consistent and exclude `.mise-install-lock` and its contents.

A cache containing only mise records cannot restore SDK files. If your pipeline needs explicit validation after restoration, optionally force-install its configured Android package tools:

```bash
mise install --force android-sdkmanager:build-tools android-sdkmanager:platforms
```

This is recovery or additional validation, not a required bootstrap step. Invalidate unrecoverable caches through your CI system; the plugin does not delete caches or retry workflows automatically.

### Flutter or installer diagnostics

Run diagnostics in the same mise environment as the build:

```bash
printf '%s\n' "$ANDROID_HOME" "$ANDROID_SDK_ROOT"
ls -l "$ANDROID_HOME/cmdline-tools/"
sdkmanager --sdk_root="$ANDROID_HOME" --list_installed
flutter doctor -v
```

Pass `--sdk_root` explicitly to avoid inspecting a stale inherited SDK. The values must match the selected `android-sdk` installation. If command-line tools are missing, repair the dependency rather than creating external tools links. For license problems, run `sdkmanager --sdk_root="$ANDROID_HOME" --licenses` in this same environment after stopping other SDK writers.

## Concurrent installation and locks

All plugin mutations of one SDK root share an atomic directory lock at `<sdk-root>/.mise-install-lock`, including roots reached through symlinks. Different roots can install concurrently. Android Studio, Gradle, and manually launched installers do not honor this lock; avoid concurrent external writers.

`MISE_ANDROID_SDK_LOCK_TIMEOUT` controls the wait: an integer from `0` to `86400` seconds, default `600`. Zero fails immediately on contention. This limits lock waiting, not installation duration. Activation never acquires the lock.

Normal completion and errors release it, but abrupt termination can leave a lock behind. The plugin never steals a lock based on age or a missing parent process; an installer child might still be writing.

**Before removing an abandoned lock, inspect its reported owner record and stop or wait for all SDK writers.** Remove `owner.<token>/info`, then remove the empty owner and lock directories with `rmdir`. A lock without an owner record may already be empty. Inspect unexpected contents rather than deleting recursively. Never remove an active lock or delete the SDK root to clear one.

## Development

| Command | Coverage |
| --- | --- |
| `mise run test --unit` | Offline Lua regression and cross-process locking |
| `mise run test --runtime` | Also exercises actual mise with fake SDK installers |
| `mise run test --sdk-stress` | Also downloads SDK tools 20.0, Java 21, build-tools 36.0.0, platform android-36, NDK 28.2.13676358, and CMake 3.22.1 for concurrent installs, warm activation, and real `apkanalyzer files list` on a minimal archive |
| `mise run test` | Unit/runtime coverage plus real version discovery, platform-tools, and emulator installation |
