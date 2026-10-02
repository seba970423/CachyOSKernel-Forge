#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$REPO_ROOT/lib/profile.sh"
source "$REPO_ROOT/lib/policy.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-hz-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() {
    if ( "$@" ) > /dev/null 2>&1; then fail "Unexpected success: $*"; fi
}
load_profile "$REPO_ROOT" > /dev/null
validate_profile > /dev/null
CPU_VENDOR=intel
CPU_HAS_VMX=yes
CPU_HAS_SVM=no
GPU_INTEL=yes
WIFI_INTEL=yes
THUNDERBOLT_PRESENT=yes
# General-policy prompts must not consume the later kernel tuning answers.
if [[ "$PROFILE_NAME" == "thinkpad" ]]; then
    resolve_policy <<< $'\n\nn\nn' > /dev/null
    [[ "$KEEP_NVME_FABRICS" == no && "$KEEP_NVME_TARGET" == no ]] ||
        fail "ThinkPad prompt flow shifted answers."
else
    resolve_policy <<< $'y\nn\nn\nn\nn' > /dev/null
    [[ "$ENABLE_NVME_FABRICS" == no && "$ENABLE_NVME_TARGET" == no ]] ||
        fail "Desktop prompt flow shifted answers."
fi
resolve_tick_frequency_policy <<< "" > /dev/null
[[ "$KERNEL_HZ" == upstream ]] || fail "Enter did not preserve upstream."
resolve_tick_frequency_policy < /dev/null > /dev/null
[[ "$KERNEL_HZ" == upstream ]] || fail "EOF did not preserve upstream."
resolve_tick_frequency_policy <<< $'y\n500\n250' > /dev/null
[[ "$KERNEL_HZ" == 250 ]] || fail "Invalid input was not retried."
for hz in upstream 100 250 300 1000; do
    resolve_tick_frequency_policy <<< "$hz" > /dev/null
    [[ "$KERNEL_HZ" == "$hz" ]] || fail "Prompt rejected $hz."
done
DEFAULT_KERNEL_HZ=300
resolve_tick_frequency_policy <<< "" > /dev/null
[[ "$KERNEL_HZ" == 300 ]] || fail "Configured default was ignored."
DEFAULT_KERNEL_HZ=500
expect_failure validate_profile
DEFAULT_KERNEL_HZ=upstream

TREE="$TEST_TMPDIR/tree"
mkdir -p "$TREE"
BASELINE="$TEST_TMPDIR/baseline.config"
# Fixtures model normalized config, including variant-specific HZ_500.
printf '%s\n' \
    '# CONFIG_HZ_100 is not set' '# CONFIG_HZ_250 is not set' \
    '# CONFIG_HZ_300 is not set' '# CONFIG_HZ_500 is not set' \
    'CONFIG_HZ_1000=y' 'CONFIG_HZ=1000' \
    'CONFIG_SCHED_AUTOGROUP=y' 'CONFIG_TRANSPARENT_HUGEPAGE=y' \
    'CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y' \
    '# CONFIG_TRANSPARENT_HUGEPAGE_MADVISE is not set' > "$BASELINE"
printf '%s\n' 'config HZ' '    int' \
    'config HZ_100' '    bool' 'config HZ_250' '    bool' \
    'config HZ_300' '    bool' 'config HZ_500' '    bool' \
    'config HZ_1000' '    bool' > "$TREE/Kconfig"
# Only scripts/config writes are mocked; discovery and application use
# production functions. Numeric HZ below models olddefconfig resolution.
kconfig_enable() {
    sed -i -E "s/^# CONFIG_$2 is not set$/CONFIG_$2=y/" "$1/.config"
}
kconfig_disable() {
    sed -i -E "s/^CONFIG_$2=[ym]$/# CONFIG_$2 is not set/" "$1/.config"
}
for hz in upstream 100 250 300 1000; do
    cp "$BASELINE" "$TREE/.config"
    KERNEL_HZ="$hz"
    kconfig_apply_tick_frequency "$TREE"
    if [[ "$hz" == upstream ]]; then
        cmp "$BASELINE" "$TREE/.config" || fail "Upstream application wrote config."
    else
        grep -qx "CONFIG_HZ_$hz=y" "$TREE/.config" || fail "Wrong choice selected."
        [[ "$(grep -Ec '^CONFIG_HZ_[0-9]+=y$' "$TREE/.config")" == 1 ]] ||
            fail "Competing HZ choices remain enabled."
        [[ "$hz" == 1000 ]] || expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
        sed -i -E "s/^CONFIG_HZ=[0-9]+$/CONFIG_HZ=$hz/" "$TREE/.config"
    fi
    validate_tick_frequency "$BASELINE" "$TREE/.config" > /dev/null
done
# Unavailable source choices fail without changing the config.
sed -i '/^config HZ_250$/d' "$TREE/Kconfig"
cp "$BASELINE" "$TREE/.config"
KERNEL_HZ=250
expect_failure kconfig_apply_tick_frequency "$TREE"
cmp "$BASELINE" "$TREE/.config" || fail "Unavailable selection mutated config."
KERNEL_HZ=500
expect_failure kconfig_apply_tick_frequency "$TREE"
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
KERNEL_HZ=upstream
sed -i 's/CONFIG_HZ=1000/CONFIG_HZ=300/' "$TREE/.config"
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
cp "$BASELINE" "$TREE/.config"
sed -i 's/CONFIG_SCHED_AUTOGROUP=y/# CONFIG_SCHED_AUTOGROUP is not set/' "$TREE/.config"
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
cp "$BASELINE" "$TREE/.config"
sed -i 's/CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y/# CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS is not set/' "$TREE/.config"
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
# Multiple enabled frequency choices must fail even with the right HZ value.
cp "$BASELINE" "$TREE/.config"
KERNEL_HZ=1000
sed -i 's/# CONFIG_HZ_100 is not set/CONFIG_HZ_100=y/' "$TREE/.config"
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
# RT-style absence and Hardened-style disabled THP both stay unchanged.
for mode in rt hardened; do
    cp "$BASELINE" "$TREE/.config"
    sed -i '/TRANSPARENT_HUGEPAGE/d' "$TREE/.config"
    if [[ "$mode" == rt ]]; then
        printf 'CONFIG_PREEMPT_RT=y\n' >> "$TREE/.config"
    else
        printf '# CONFIG_TRANSPARENT_HUGEPAGE is not set\n' >> "$TREE/.config"
    fi
    cp "$TREE/.config" "$TEST_TMPDIR/variant.config"
    KERNEL_HZ=upstream
    kconfig_apply_tick_frequency "$TREE"
    cmp "$TEST_TMPDIR/variant.config" "$TREE/.config" || fail "Variant baseline changed."
    validate_tick_frequency "$TEST_TMPDIR/variant.config" "$TREE/.config" > /dev/null
    KERNEL_HZ=300
    kconfig_apply_tick_frequency "$TREE"
    sed -i 's/CONFIG_HZ=1000/CONFIG_HZ=300/' "$TREE/.config"
    validate_tick_frequency "$TEST_TMPDIR/variant.config" "$TREE/.config" > /dev/null
done
printf 'Tick frequency tests passed (%s).\n' "$PROFILE_NAME"
