# android-sdkmanager

A [mise backend plugin](https://mise.jdx.dev/backend-plugin-development.html) for Android SDK packages. It wraps `sdkmanager` and the modern `android sdk` CLI, keeps packages in a shared SDK root, and exports their environment and executable paths.

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

Use `latest` for these two families. Mise resolves it to a numeric revision for update tracking, but Android's installer accepts only the package name, not a target revision. **Numeric pins and lockfile revisions are advisory.** A valid installation with a different revision, newer or older, produces a warning by default.

To fail installation on a revision mismatch, add `strict_revision`:

```toml
"android-sdkmanager:platform-tools" = { version = "latest", strict_revision = true, depends = ["android-sdk", "java"] }
```

This boolean option applies only to platform-tools and emulator. It checks the observed revision; it cannot retrieve unavailable older releases or prevent another project from changing the shared package later. It also applies to `latest`, because mise passes its resolved number. Older mise releases that serialize booleans as `"true"`/`"false"` are supported.

### System images

The `system-images` shorthand selects `google_apis_playstore` with `arm64-v8a` on ARM64 hosts and `x86_64` otherwise. For explicit variants:

```toml
"android-sdkmanager:system-images/google_apis/arm64-v8a" = { version = "android-36", depends = ["android-sdk", "java"] }
"android-sdkmanager:system-images/google_apis_playstore/x86_64" = { version = "android-36", depends = ["android-sdk", "java"] }
```

Flavor and ABI are part of the tool identity, keeping mise's installation records and version caches separate. Flavors start with a lowercase letter and contain lowercase letters, digits, or single, nontrailing underscores. Supported ABIs are `arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64`; selecting one does not guarantee the host can run it.

For platforms and images, an API identifier such as `android-36` does not pin an immutable package revision. The shared SDK is not a byte-for-byte reproducible environment.

## SDK root and command-line tools

Packages live outside the versioned `android-sdk` dependency:

```text
${MISE_DATA_DIR}/android-sdk-tools
# fallback: ~/.local/share/mise/android-sdk-tools
```

The plugin exports this path as both `ANDROID_HOME` and `ANDROID_SDK_ROOT`. SDK packages survive command-line tools upgrades, but the root remains shared across projects: singleton revisions and tooling links are not project-isolated.

Tooling comes from the selected dependency's `PATH`, not a scan for the highest installed version. An inherited Android SDK environment variable does not override this selection. To select a specific installation, add an absolute `cmdline_tools` path:

```toml
"android-sdkmanager:build-tools" = { version = "36.0.0", cmdline_tools = "/opt/android/cmdline-tools/20.0", depends = ["android-sdk", "java"] }
```

This changes the installer source, not the SDK destination or prerequisite declarations. The plugin prefers a capable `android sdk` CLI, falling back to `sdkmanager` from the same source when necessary.

Explicit installation exposes the dependency's complete `cmdline-tools` tree through managed links inside the SDK root, allowing Flutter to find it. It refreshes those links when needed but preserves user-owned directories and links, reporting a conflict if they are incomplete.

## Activation and recovery

**Activation is read-only.** Unlike older plugin versions, it does not download packages, accept licenses, repair links, or wait for the installation lock. It warns about detected missing files without blocking activation. Mise caches environment results, so these warnings are not continuous integrity checks.

Retry an affected configured tool explicitly:

```bash
mise install --force android-sdkmanager:build-tools
```

Without `@version`, mise preserves that tool's configured requests and options. It recreates the per-tool record, not the shared SDK. The plugin refreshes tooling links and reuses healthy side-by-side packages without downloading them again. Singleton packages are reused when their revision matches; otherwise an installer attempt allows upgrades.

Plain `mise install` can skip a damaged package if mise still records it as installed. Force-install retries missing payloads, but SDK metadata can make the installer consider an incomplete package already installed. In that case, inspect the reported files, `source.properties`, `package.xml`, and installed-package listing. The plugin does not automatically uninstall shared packages, delete metadata, or wipe the SDK.

Successful installation requires valid metadata and the expected payload; failed commands are never accepted merely because files exist. An atomic `.mise-sdk-package.json` receipt records the package, resolved and observed revisions, SDK root, and tooling source. Legacy `.installed` markers remain compatible and are not migrated during activation. Removing a mise installation leaves shared SDK packages intact.

### CI caches

Use the same single `mise install` for clean runners and intact restored installations. Cache the shared SDK payload, mise's installation records, and the command-line tools dependency together. Keep restored paths consistent so tooling links remain valid. Include OS and architecture in cache keys, and exclude `.mise-install-lock` and its contents.

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

Pass `--sdk_root` explicitly: otherwise sdkmanager can inspect its own installation root. For a missing managed tooling link, force-install one configured package to refresh it. Do not hardcode `ANDROID_HOME` to the versioned dependency.

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
| `mise run test --sdk-stress` | Also downloads SDK tools 20.0, Java 21, build-tools 36.0.0, platform android-36, NDK 28.2.13676358, and CMake 3.22.1 for concurrent installs and warm activation |
| `mise run test` | Unit/runtime coverage plus real version discovery, platform-tools, and emulator installation |
