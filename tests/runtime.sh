#!/usr/bin/env bash
set -euo pipefail
plugin=${1:?plugin directory}
parent=${2:?test directory}
root=$(mktemp -d "$parent/runtime.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
mise_bin=$(command -v mise)
export PATH="$(dirname "$mise_bin"):/usr/bin:/bin"
export MISE_DATA_DIR="$root/data" MISE_CACHE_DIR="$root/cache"
export MISE_CONFIG_DIR="$root/config" MISE_STATE_DIR="$root/state"
export MISE_GLOBAL_CONFIG_FILE="$root/global.toml" MISE_SYSTEM_CONFIG_FILE="$root/system.toml"
export MISE_CONFIG_FILE="$root/project/runtime.mise.toml" MISE_TRUSTED_CONFIG_PATHS="$root"
export MISE_OVERRIDE_CONFIG_FILENAMES=runtime.mise.toml MISE_OVERRIDE_TOOL_VERSIONS_FILENAMES=runtime.tool-versions
export MISE_EXPERIMENTAL=1 MISE_YES=1 MISE_USE_VERSIONS_HOST=0 MISE_NOT_FOUND_AUTO_INSTALL=0
export MISE_AUTO_INSTALL=0 MISE_LOCKFILE=0 MISE_DISABLE_DEFAULT_SHORTHANDS=1
export HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" all_proxy="$ALL_PROXY"
export NO_PROXY= no_proxy=
export SDK_TEST_PLUGIN="$plugin" SDK_TEST_LOG="$root/installer.log"
unset ANDROID_HOME ANDROID_SDK_ROOT JAVA_HOME MISE_ENV MISE_DEFAULT_TOOL_VERSIONS_FILENAME
mkdir -p "$root/project"
touch "$SDK_TEST_LOG" "$MISE_GLOBAL_CONFIG_FILE" "$MISE_SYSTEM_CONFIG_FILE"
cd "$root/project"

pass() { printf 'PASS: %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() { "$mise_bin" "$@"; }
install_count() { grep -cE '\|(sdkmanager|android)\|.*(--install |sdk install )' "$SDK_TEST_LOG" || :; }
assert_contains() {
    if ! grep -Fq -- "$2" "$1"; then
        cat "$1" >&2
        die "$1 missing: $2"
    fi
}
expect_failure() {
    local expected=$1
    shift
    if "$@" > "$root/failure.log" 2>&1; then
        die "command unexpectedly succeeded: $*"
    fi
    assert_contains "$root/failure.log" "$expected"
}
write_config() {
    cat > "$MISE_CONFIG_FILE" <<EOF
[tool_alias.android-sdk]
backend = "vfox:android-sdk"
[tool_alias.java]
backend = "asdf:java"
[tools]
android-sdk = "${sdk_version:-20.0.0}"
java = "${java_version:-17.0.0}"
$1
[settings]
experimental = true
EOF
}
record_for() {
    run where "$1"
}
assert_receipt() {
    local record=$1 package=$2 version=$3 selected=$4
    [[ -f "$record/.mise-sdk-package.json" ]] || die "missing receipt: $record"
    local compact
    compact=$(tr -d '[:space:]' < "$record/.mise-sdk-package.json")
    for field in '"schema_version":1' "\"package_id\":\"$package\"" "\"resolved_version\":\"$version\"" \
        "\"sdk_root\":\"$sdk\"" "\"cmdline_tools\":\"$selected\""; do
        [[ "$compact" == *"$field"* ]] || die "receipt missing $field: $compact"
    done
    [[ "$compact" == *'"installed_revision":'* ]] || die "receipt missing revision"
    [[ -z "$(find "$record" -name '.mise-sdk-package.*' ! -name '.mise-sdk-package.json' -print)" ]] \
        || die "atomic receipt left a staging file"
}

write_config '"android-sdkmanager:build-tools" = "36.0.0"'
run plugin link android-sdkmanager "$plugin" > "$root/link.log" 2>&1
run plugin link android-sdk "$plugin/tests/fixtures/android-sdk" >> "$root/link.log" 2>&1
run plugin link java "$plugin/tests/fixtures/dependency" >> "$root/link.log" 2>&1
expect_failure "install the configured android-sdk and java dependencies" run ls-remote android-sdkmanager:build-tools
run install android-sdk java > "$root/dependencies.log" 2>&1 || { cat "$root/dependencies.log" >&2; exit 1; }
run install > "$root/install.log" 2>&1 || { cat "$root/install.log" >&2; exit 1; }
sdk="$MISE_DATA_DIR/installs/android-sdk/20.0.0"
selected="$sdk/cmdline-tools/20.0.0"
record=$(record_for android-sdkmanager:build-tools)
assert_receipt "$record" 'build-tools;36.0.0' 36.0.0 "$selected"
[[ -x "$MISE_DATA_DIR/installs/java/17.0.0/bin/java" ]] || die "Java dependency was not installed"
[[ ! -L "$sdk/cmdline-tools" && ! -e "$sdk/.mise-cmdline-tools" ]] || die "plugin linked command-line tools"
[[ -f "$sdk/cmdline-tools/20.0.0/lib/fixture.jar" ]] || die "incomplete tooling tree"
find "$sdk/cmdline-tools" -type f -exec sha256sum {} + | sort > "$root/tools-before"
[[ ! -e "$sdk/.mise-install-lock" ]] || die "install leaked SDK lock"
pass "cold bootstrap diagnostics, dependency-first install, complete tooling tree, and atomic receipt"

run install android-sdk@99.0.0 > "$root/newer.log" 2>&1
before=$(install_count)
ANDROID_HOME="$MISE_DATA_DIR/android-sdk-tools" ANDROID_SDK_ROOT="$MISE_DATA_DIR/installs/android-sdk/99.0.0" \
    PATH="$MISE_DATA_DIR/installs/android-sdk/99.0.0/cmdline-tools/99.0.0/bin:$PATH" \
    run install --force android-sdkmanager:build-tools > "$root/force.log" 2>&1
[[ "$(install_count)" == "$before" ]] || die "healthy side-by-side package reinstalled"
assert_receipt "$(record_for android-sdkmanager:build-tools)" 'build-tools;36.0.0' 36.0.0 "$selected"
[[ ! -e "$MISE_DATA_DIR/installs/android-sdk/99.0.0/build-tools" ]] || die "unselected dependency modified"
pass "force-install reuses payload and ignores unselected newer dependency"

before=$(wc -l < "$SDK_TEST_LOG")
versions=$(SDK_TEST_HELP_STATUS=2 run ls-remote android-sdkmanager:platform-tools)
[[ "$versions" == 36.0.2 ]] || die "singleton listing included stale installed revision: $versions"
tail -n "+$((before + 1))" "$SDK_TEST_LOG" > "$root/help-status-2.log"
assert_contains "$root/help-status-2.log" "$selected|android|sdk list --all --all-versions"
if grep -Fq '|sdkmanager|' "$root/help-status-2.log"; then
    die "modern help status 2 incorrectly used sdkmanager fallback"
fi
before=$(wc -l < "$SDK_TEST_LOG")
versions=$(SDK_TEST_HELP_STATUS=23 run ls-remote android-sdkmanager:platforms 2> "$root/help-status-23.err")
[[ "$versions" == android-36 ]] || die "failed capability probe did not fall back to sdkmanager"
tail -n "+$((before + 1))" "$SDK_TEST_LOG" > "$root/help-status-23.log"
assert_contains "$root/help-status-23.log" "$selected|sdkmanager|--sdk_root=$sdk --list"
if grep -Fq '|android|sdk list' "$root/help-status-23.log"; then
    die "failed modern help status 23 incorrectly accepted"
fi
versions=$(SDK_TEST_LEGACY_ANDROID=1 SDK_TEST_HELP_STATUS=2 run ls-remote android-sdkmanager:emulator)
[[ "$versions" == 36.2.1 ]] || die "sdkmanager fallback listing failed: $versions"
assert_contains "$SDK_TEST_LOG" "--sdk_root=$sdk --list"
pass "help status 2 accepted, status 23 rejected; listing targets selected dependency root"

write_config '"android-sdkmanager:system-images/google_apis/arm64-v8a" = "android-36"
"android-sdkmanager:system-images/google_apis_playstore/x86_64" = "android-34"'
run install > "$root/images.log" 2>&1 || { cat "$root/images.log" >&2; exit 1; }
arm_record=$(record_for android-sdkmanager:system-images/google_apis/arm64-v8a)
x86_record=$(record_for android-sdkmanager:system-images/google_apis_playstore/x86_64)
[[ "$arm_record" != "$x86_record" ]] || die "image installation identities collided"
assert_receipt "$arm_record" 'system-images;android-36;google_apis;arm64-v8a' android-36 "$selected"
assert_receipt "$x86_record" 'system-images;android-34;google_apis_playstore;x86_64' android-34 "$selected"
arm_versions=$(run ls-remote android-sdkmanager:system-images/google_apis/arm64-v8a)
x86_versions=$(run ls-remote android-sdkmanager:system-images/google_apis_playstore/x86_64)
[[ "$arm_versions" == $'android-35\nandroid-36' && "$x86_versions" == android-34 ]] || die "image listing cache identities collided"
[[ "$(run ls-remote android-sdkmanager:system-images/google_apis/arm64-v8a)" == "$arm_versions" ]] || die "warm image cache changed"
pass "explicit image installation and version cache identities remain separate"

write_config '"android-sdkmanager:platform-tools" = { version = "35.0.0", cmdline_tools = "/old/cmdline-tools/20" }'
before=$(wc -l < "$SDK_TEST_LOG")
expect_failure "cmdline_tools has been removed" run install
[[ "$(wc -l < "$SDK_TEST_LOG")" == "$before" ]] || die "retired option executed installer"
write_config '"android-sdkmanager:platform-tools" = { version = "35.0.0", strict_revision = true }'
expect_failure strict_revision run install
[[ -z "$(find "$MISE_DATA_DIR/installs" -path '*platform-tools*/.mise-sdk-package.json' -print)" ]] || die "failed strict install wrote success receipt"
write_config '"android-sdkmanager:platform-tools" = { version = "35.0.0", strict_revision = false }'
run install > "$root/advisory.log" 2>&1
assert_contains "$root/advisory.log" "differs from mise"
pt_record=$(record_for android-sdkmanager:platform-tools)
assert_receipt "$pt_record" platform-tools 35.0.0 "$selected"
write_config '"android-sdkmanager:platform-tools" = { version = "35.0.0", strict_revision = true }'
before=$(install_count)
expect_failure strict_revision run install --force android-sdkmanager:platform-tools
[[ "$(install_count)" -gt "$before" ]] || die "singleton mismatch skipped installer attempt"
[[ ! -f "$pt_record/.mise-sdk-package.json" ]] || die "failed forced install retained success receipt"
assert_contains "$SDK_TEST_LOG" "$selected|android|sdk install platform-tools"
pass "removed option rejected, TOML booleans, strict mismatch, and force option retention"

write_config '"android-sdkmanager:platform-tools" = { version = "36.0.2", strict_revision = true }'
run install > "$root/matching.log" 2>&1
pt_record=$(record_for android-sdkmanager:platform-tools)
before=$(install_count)
printf 'Pkg.Path=platform-tools\nPkg.Revision=036.00.2\n' > "$sdk/platform-tools/source.properties"
run install --force android-sdkmanager:platform-tools > "$root/matching-force.log" 2>&1
[[ "$(install_count)" == "$before" ]] || die "matching singleton was reinstalled"
pass "matching singleton payload reused"

write_config '"android-sdkmanager:platform-tools" = "35.0.0"'
expect_failure "fixture installer stderr" env SDK_TEST_FAIL=1 "$mise_bin" install
assert_contains "$root/failure.log" "fixture installer stdout"
[[ -z "$(find "$MISE_DATA_DIR/installs" -path '*platform-tools/35.0.0/.mise-sdk-package.json' -print)" ]] || die "failed installer accepted existing payload"
write_config '"android-sdkmanager:cmake" = "3.22.1"'
expect_failure "validation failed" env SDK_TEST_INCOMPLETE=1 "$mise_bin" install
[[ -z "$(find "$MISE_DATA_DIR/installs" -path '*cmake*/.mise-sdk-package.json' -print)" ]] || die "incomplete install wrote success receipt"
SDK_TEST_ANDROID_FAIL=1 run install > "$root/fallback.log" 2>&1
assert_contains "$SDK_TEST_LOG" "$selected|sdkmanager|--sdk_root=$sdk --install cmake;3.22.1"
pass "failed installer cannot accept existing payload; incomplete and same-source fallback covered"

write_config '"android-sdkmanager:build-tools" = "36.0.0"'
record=$(record_for android-sdkmanager:build-tools)
rm "$record/.mise-sdk-package.json"
printf 'legacy\n' > "$record/.installed"
mkdir "$sdk/.mise-install-lock"
rm "$sdk/build-tools/36.0.0/aapt"
snapshot() {
    find "$sdk" "$record" -printf '%p|%y|%s|%T@|%l\n' | LC_ALL=C sort
}
snapshot > "$root/before"
before=$(wc -l < "$SDK_TEST_LOG")
MISE_ANDROID_SDK_LOCK_TIMEOUT=0 run exec -- sh -eu -c '
    test "$ANDROID_HOME" = "$MISE_DATA_DIR/installs/android-sdk/20.0.0"
    test "$ANDROID_HOME" = "$ANDROID_SDK_ROOT"
    case ":$PATH:" in *":$ANDROID_HOME/build-tools/36.0.0:"*) ;; *) exit 1 ;; esac
' > "$root/activation.log" 2>&1
assert_contains "$root/activation.log" "mise install --force"
MISE_ANDROID_SDK_LOCK_TIMEOUT=0 run exec -- sh -eu -c 'test "$ANDROID_HOME" = "$ANDROID_SDK_ROOT"' > "$root/cached.log" 2>&1
snapshot > "$root/after"
cmp "$root/before" "$root/after"
[[ "$(wc -l < "$SDK_TEST_LOG")" == "$before" ]] || die "activation called SDK commands"
[[ ! -f "$record/.mise-sdk-package.json" ]] || die "activation migrated legacy marker"
rmdir "$sdk/.mise-install-lock"
before=$(install_count)
run install --force android-sdkmanager:build-tools > "$root/recovery.log" 2>&1
[[ "$(install_count)" -gt "$before" ]] || die "recovery did not attempt missing payload"
assert_receipt "$(record_for android-sdkmanager:build-tools)" 'build-tools;36.0.0' 36.0.0 "$selected"
pass "legacy and cached activation are read-only despite missing payload and stale lock"

find "$sdk/cmdline-tools" -type f -exec sha256sum {} + | sort > "$root/tools-after"
cmp "$root/tools-before" "$root/tools-after"
[[ ! -e "$MISE_DATA_DIR/android-sdk-tools" ]] || die "plugin created old shared root"
pass "dependency tooling remains unchanged; no shared root or tooling copies created"

# Keep old shared data and legacy records to exercise migration without changing ownership.
old_shared="$MISE_DATA_DIR/android-sdk-tools"
mkdir -p "$old_shared/build-tools/36.0.0" "$old_shared/licenses"
printf 'old payload\n' > "$old_shared/build-tools/36.0.0/aapt"
printf 'old license\n' > "$old_shared/licenses/keep"
ln -s "$selected/.." "$old_shared/cmdline-tools"
find "$old_shared" -printf '%p|%y|%s|%T@|%l\n' | sort > "$root/old-before"
old_sdk=$sdk
sdk_version=99.0.0
write_config '"android-sdkmanager:build-tools" = "36.0.0"'
before=$(wc -l < "$SDK_TEST_LOG")
ANDROID_HOME="$old_shared" ANDROID_SDK_ROOT="$old_shared" run exec -- sh -eu -c '
    printf "ANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\nPATH=%s\n" "$ANDROID_HOME" "$ANDROID_SDK_ROOT" "$PATH"
' > "$root/switched-activation.log" 2>&1
assert_contains "$root/switched-activation.log" "ANDROID_HOME=$MISE_DATA_DIR/installs/android-sdk/99.0.0"
assert_contains "$root/switched-activation.log" "ANDROID_SDK_ROOT=$MISE_DATA_DIR/installs/android-sdk/99.0.0"
[[ "$(wc -l < "$SDK_TEST_LOG")" == "$before" ]] || die "SDK switch activation executed Android tools"
[[ ! -e "$MISE_DATA_DIR/installs/android-sdk/99.0.0/build-tools" ]] || die "activation repaired new SDK"
run install > "$root/switched-install.log" 2>&1
[[ ! -e "$MISE_DATA_DIR/installs/android-sdk/99.0.0/build-tools" ]] || die "plain install unexpectedly replaced existing record"
sdk="$MISE_DATA_DIR/installs/android-sdk/99.0.0"
selected="$sdk/cmdline-tools/99.0.0"
rm "$record/.mise-sdk-package.json"
printf 'legacy\n' > "$record/.installed"
ANDROID_HOME="$old_shared" ANDROID_SDK_ROOT="$old_shared" run install --force android-sdkmanager:build-tools \
    > "$root/switched-force.log" 2>&1 || { cat "$root/switched-force.log" >&2; exit 1; }
assert_receipt "$(record_for android-sdkmanager:build-tools)" 'build-tools;36.0.0' 36.0.0 "$selected"
run exec -- sh -eu -c '
    test "$ANDROID_HOME" = "$MISE_DATA_DIR/installs/android-sdk/99.0.0"
    test "$ANDROID_SDK_ROOT" = "$ANDROID_HOME"
    test -f "$ANDROID_HOME/build-tools/36.0.0/aapt"
    case ":$PATH:" in *":$ANDROID_HOME/build-tools/36.0.0:"*) ;; *) exit 1 ;; esac
' > "$root/switched-warm.log" 2>&1
[[ -f "$old_sdk/build-tools/36.0.0/aapt" ]] || die "previous SDK package removed"
find "$old_shared" -printf '%p|%y|%s|%T@|%l\n' | sort > "$root/old-after"
cmp "$root/old-before" "$root/old-after"
pass "SDK switch with existing records stays read-only; force-install targets new root and preserves old roots"

run plugin link jds-sdkmanager "$plugin" > "$root/renamed-link.log" 2>&1
write_config '"jds-sdkmanager:build-tools" = ["9.0.0", "36.0.0"]
"jds-sdkmanager:emulator" = { version = "36.2.1", strict_revision = true }
"jds-sdkmanager:ndk" = "28.2.13676358"
"jds-sdkmanager:platforms" = "android-36"'
run install > "$root/renamed-install.log" 2>&1 || { cat "$root/renamed-install.log" >&2; exit 1; }
for path in build-tools/9.0.0/aapt build-tools/36.0.0/aapt emulator/emulator ndk/28.2.13676358/ndk-build platforms/android-36/android.jar; do
    [[ -f "$sdk/$path" ]] || die "missing package family: $path"
done
rm "$sdk/build-tools/9.0.0/aapt" "$sdk/build-tools/36.0.0/aapt"
run cache clear > "$root/renamed-cache.log" 2>&1
before=$(wc -l < "$SDK_TEST_LOG")
run exec -- true > "$root/renamed-activation.log" 2>&1
assert_contains "$root/renamed-activation.log" "mise install --force 'jds-sdkmanager:build-tools'"
assert_contains "$root/renamed-activation.log" "$sdk"
[[ "$(wc -l < "$SDK_TEST_LOG")" == "$before" ]] || die "renamed activation executed installers"
run install --force jds-sdkmanager:build-tools > "$root/renamed-force.log" 2>&1
[[ -f "$sdk/build-tools/9.0.0/aapt" && -f "$sdk/build-tools/36.0.0/aapt" ]] || die "force-install lost configured versions"
pass "renamed plugin diagnostics and force-install preserve all configured versions; all package families covered"

sdk_version=21.0.0
java_version=21.0.0
write_config '"jds-sdkmanager:build-tools" = { version = "37.0.0", depends = ["android-sdk", "java"] }'
run install > "$root/cold-ordered.log" 2>&1 || { cat "$root/cold-ordered.log" >&2; exit 1; }
sdk="$MISE_DATA_DIR/installs/android-sdk/21.0.0"
selected="$sdk/cmdline-tools/21.0.0"
assert_receipt "$(record_for jds-sdkmanager:build-tools)" 'build-tools;37.0.0' 37.0.0 "$selected"
[[ -f "$sdk/build-tools/37.0.0/aapt" && -x "$MISE_DATA_DIR/installs/java/21.0.0/bin/java" ]] \
    || die "cold dependency ordering failed"
pass "single-command cold bootstrap respects explicit dependency ordering"
printf 'PASS: actual mise runtime contract suite\n'
