#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$REPO_ROOT/lib/profile.sh"
source "$REPO_ROOT/lib/policy.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
source "$REPO_ROOT/lib/debug-compression.sh"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-tuning-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT
TREE="$TEST_TMPDIR/tree"
BASELINE="$TEST_TMPDIR/baseline"
OUTPUT="$TEST_TMPDIR/output"
mkdir -p "$TREE/scripts"
touch "$TREE/Makefile"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ( "$@" ) >/dev/null 2>&1; then fail "Unexpected success: $*"; fi; }
load_profile "$REPO_ROOT" >/dev/null

# Stand-in for the external kernel scripts/config command.
cat > "$TREE/scripts/config" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
file="$2" operation="$3" symbol="$4"
sed -i -E "/^(CONFIG_${symbol}=.*|# CONFIG_${symbol} is not set)$/d" "$file"
case "$operation" in
    --enable) printf 'CONFIG_%s=y\n' "$symbol" >> "$file" ;;
    --disable) printf '# CONFIG_%s is not set\n' "$symbol" >> "$file" ;;
    *) exit 1 ;;
esac
SCRIPT
chmod +x "$TREE/scripts/config"
cat > "$TREE/Kconfig" <<'KCONFIG'
config SCHED_AUTOGROUP
    bool
menuconfig TRANSPARENT_HUGEPAGE
    bool
config TRANSPARENT_HUGEPAGE_MADVISE
    bool
config TRANSPARENT_HUGEPAGE_ALWAYS
    bool
config TRANSPARENT_HUGEPAGE_NEVER
    bool
config HZ
    int
config HZ_1000
    bool
KCONFIG
cat > "$BASELINE" <<'CONFIG'
# CONFIG_PREEMPT_RT is not set
# CONFIG_SCHED_ALT is not set
# CONFIG_SCHED_AUTOGROUP is not set
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
# CONFIG_TRANSPARENT_HUGEPAGE_MADVISE is not set
# CONFIG_TRANSPARENT_HUGEPAGE_NEVER is not set
CONFIG_TRANSPARENT_HUGEPAGE_DEFERRED_SPLIT=y
CONFIG_HZ_1000=y
CONFIG_HZ=1000
CONFIG_HAVE_ARCH_TRANSPARENT_HUGEPAGE=y
CONFIG_USB_HID=y
CONFIG_DRM_I915=m
CONFIG_HIBERNATION=y
CONFIG_BLK_DEV_NVME=m

CONFIG

# Only the external olddefconfig command is mocked. It models a symbol whose
# dependencies are unsatisfied even though its declaration exists in Kconfig.
make() {
    local config="$TREE/.config" arg
    for arg in "$@"; do
        [[ "$arg" != KCONFIG_CONFIG=* ]] || config="${arg#KCONFIG_CONFIG=}"
    done
    [[ "${PROBE_FAIL:-no}" != yes ]] || return 2
    if [[ "${BLOCK_AUTOGROUP:-no}" == yes ]]; then
        "$TREE/scripts/config" --file "$config" --disable SCHED_AUTOGROUP
    fi
    if [[ "${BLOCK_THP:-no}" == yes || "$(kconfig_state "$config" PREEMPT_RT)" == y ]]; then
        "$TREE/scripts/config" --file "$config" --disable TRANSPARENT_HUGEPAGE
        "$TREE/scripts/config" --file "$config" --disable TRANSPARENT_HUGEPAGE_MADVISE
    fi
}
reset_config() { cp "$BASELINE" "$TREE/.config"; }
check_preserved() {
    cmp "$BASELINE" "$TREE/.config" || fail 'Declined tuning changed baseline.'
    validate_tick_frequency "$BASELINE" "$TREE/.config" >/dev/null
}

for answers in $'upstream\nn\nn' $'\n\n\n' ''; do
    reset_config
    resolve_kernel_tuning_policy "$TREE" linux-cachyos-bore <<< "$answers" > "$OUTPUT"
    [[ "$AUTOGROUP_SUPPORTED" == yes && "$THP_SUPPORTED" == yes ]] || fail 'Supported prompts missing.'
    [[ "$ENABLE_AUTOGROUP" == no && "$ENABLE_THP_MADVISE" == no ]] || fail 'Default enabled tuning.'
    kconfig_apply_optional_tuning "$TREE"
    check_preserved
done
resolve_kernel_tuning_policy "$TREE" linux-cachyos < /dev/null > "$OUTPUT"
kconfig_apply_optional_tuning "$TREE"
check_preserved

# Enabled baselines are preserved as well; no does not mean disable.
sed -i 's/# CONFIG_SCHED_AUTOGROUP is not set/CONFIG_SCHED_AUTOGROUP=y/' "$BASELINE"
reset_config
resolve_kernel_tuning_policy "$TREE" linux-cachyos <<< $'upstream\nn\nn' > "$OUTPUT"
kconfig_apply_optional_tuning "$TREE"
check_preserved
sed -i 's/CONFIG_SCHED_AUTOGROUP=y/# CONFIG_SCHED_AUTOGROUP is not set/' "$BASELINE"

# A supported but disabled THP baseline stays disabled on no/Enter.
cp "$BASELINE" "$TEST_TMPDIR/enabled-baseline"
sed -i '/TRANSPARENT_HUGEPAGE/d' "$BASELINE"
printf '# CONFIG_TRANSPARENT_HUGEPAGE is not set\n' >> "$BASELINE"
reset_config
resolve_kernel_tuning_policy "$TREE" linux-cachyos-hardened <<< $'upstream\nn\nn' > "$OUTPUT"
[[ "$THP_SUPPORTED" == yes ]] || fail 'Disabled baseline was mistaken for unsupported THP.'
kconfig_apply_optional_tuning "$TREE"
check_preserved
cp "$TEST_TMPDIR/enabled-baseline" "$BASELINE"

for answers in $'upstream\ny\nn' $'upstream\nn\ny' $'upstream\ny\ny'; do
    reset_config
    resolve_kernel_tuning_policy "$TREE" linux-cachyos <<< "$answers" > "$OUTPUT"
    cmp "$BASELINE" "$TREE/.config" || fail 'Support probing modified real config.'
    kconfig_apply_optional_tuning "$TREE"
    make -C "$TREE" olddefconfig
    validate_tick_frequency "$BASELINE" "$TREE/.config" >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" USB_HID >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" BLK_DEV_NVME >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" HIBERNATION >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" TRANSPARENT_HUGEPAGE_DEFERRED_SPLIT >/dev/null
done

# An unsupported prompt must not consume the next answer.
reset_config
printf 'upstream\ny\nsentinel\n' > "$TEST_TMPDIR/answers"
exec 3< "$TEST_TMPDIR/answers"
resolve_kernel_tuning_policy "$TREE" linux-cachyos-bmq <&3 > "$OUTPUT"
read -r remaining <&3
exec 3<&-
[[ "$AUTOGROUP_SUPPORTED" == no && "$ENABLE_AUTOGROUP" == no && "$ENABLE_THP_MADVISE" == yes && "$remaining" == sentinel ]] || fail 'BMQ prompt consumed wrong input.'
! grep -q 'Enable scheduler autogrouping?' "$OUTPUT" || fail 'BMQ showed autogroup prompt.'
kconfig_apply_optional_tuning "$TREE"
validate_tick_frequency "$BASELINE" "$TREE/.config" >/dev/null

for variant in linux-cachyos-rt linux-cachyos-rt-bore linux-cachyos; do
    reset_config
    "$TREE/scripts/config" --file "$TREE/.config" --enable PREEMPT_RT
    make -C "$TREE" olddefconfig
    cp "$TREE/.config" "$TEST_TMPDIR/rt-baseline"
    resolve_kernel_tuning_policy "$TREE" "$variant" <<< $'upstream\ny' > "$OUTPUT"
    [[ "$AUTOGROUP_SUPPORTED" == yes && "$THP_SUPPORTED" == no && "$ENABLE_AUTOGROUP" == yes && "$ENABLE_THP_MADVISE" == no ]] || fail 'RT support detection failed.'
    ! grep -q 'Enable transparent hugepages' "$OUTPUT" || fail 'RT showed THP prompt.'
    kconfig_apply_optional_tuning "$TREE"
    validate_tick_frequency "$TEST_TMPDIR/rt-baseline" "$TREE/.config" >/dev/null
done
# RT variant name also blocks THP when baseline preemption differs.
reset_config
kconfig_detect_tuning_support "$TREE" linux-cachyos-rt-bore
[[ "$THP_SUPPORTED" == no ]] || fail 'RT variant-name guard failed.'

# Alternative scheduling is excluded even under a renamed variant.
reset_config
"$TREE/scripts/config" --file "$TREE/.config" --enable SCHED_ALT
kconfig_detect_tuning_support "$TREE" linux-custom
[[ "$AUTOGROUP_SUPPORTED" == no ]] || fail 'Alternative scheduler guard failed.'

reset_config
BLOCK_AUTOGROUP=yes BLOCK_THP=yes resolve_kernel_tuning_policy "$TREE" linux-cachyos <<< 'upstream' > "$OUTPUT"
[[ "$AUTOGROUP_SUPPORTED" == no && "$THP_SUPPORTED" == no ]] || fail 'Dependency-blocked symbols were offered.'
! grep -q 'Enable scheduler\|Enable transparent' "$OUTPUT" || fail 'Unavailable prompt appeared.'
kconfig_apply_optional_tuning "$TREE"
check_preserved
PROBE_FAIL=yes expect_failure resolve_kernel_tuning_policy "$TREE" linux-cachyos
cmp "$BASELINE" "$TREE/.config" || fail 'Failed support probe modified config.'

# Missing declarations are skipped rather than synthesized.
mv "$TREE/Kconfig" "$TEST_TMPDIR/Kconfig"
printf 'config HZ\n    int\nconfig HZ_1000\n    bool\n' > "$TREE/Kconfig"
resolve_kernel_tuning_policy "$TREE" linux-cachyos <<< 'upstream' > "$OUTPUT"
[[ "$AUTOGROUP_SUPPORTED" == no && "$THP_SUPPORTED" == no ]] || fail 'Missing feature was offered.'
mv "$TEST_TMPDIR/Kconfig" "$TREE/Kconfig"

# Dependency resolution dropping a requested setting must fail validation.
reset_config
resolve_kernel_tuning_policy "$TREE" linux-cachyos <<< $'upstream\ny\ny' > "$OUTPUT"
kconfig_apply_optional_tuning "$TREE"
"$TREE/scripts/config" --file "$TREE/.config" --disable SCHED_AUTOGROUP
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
"$TREE/scripts/config" --file "$TREE/.config" --enable SCHED_AUTOGROUP
"$TREE/scripts/config" --file "$TREE/.config" --disable TRANSPARENT_HUGEPAGE_MADVISE
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"

# Run the production entry points with external fetching/building stubbed out.
# The real prompt resolver, support probe, tuning writes and validation run.
for entry in builder.sh builder-dry-run.sh; do
    for workflow_variant in linux-cachyos-bore linux-cachyos-rt-bore linux-cachyos-bmq; do
        (
            if [[ -f "$REPO_ROOT/lib/build.sh" ]]; then
                source "$REPO_ROOT/lib/build.sh"
            fi
            eval "$(awk '/^main\(\) \{/ {printing=1} /^main "\$@"$/ {printing=0} printing' "$REPO_ROOT/$entry")"
            require_commands() { :; }
            require_build_commands() { :; }
            detect_hardware() {
                CPU_VENDOR=intel CPU_HAS_VMX=yes CPU_HAS_SVM=no
                GPU_INTEL=yes WIFI_INTEL=yes THUNDERBOLT_PRESENT=yes
            }
            print_hardware_summary() { :; }
            fetch_upstream() { :; }
            select_kernel_variant() {
                printf 'TEST: kernel selected\n' >&2
                printf '%s\n' "$workflow_variant"
            }
            validate_kernel_variant() { :; }
            install_upstream_prepare_compat() { :; }
            prompt_kernel_name() { printf '%s\n' "${workflow_variant#linux-}"; }
            apply_custom_kernel_name() { :; }
            prepare_upstream_source() {
                printf 'TEST: sources prepared\n' >&2
                printf '%s\n' "$TREE"
            }
            ask_compile() { return 1; }
            mktemp() {
                if [[ "$*" == *--tmpdir* ]]; then
                    mkdir -p "$TEST_TMPDIR/work"
                    printf '%s\n' "$TEST_TMPDIR/work"
                else
                    command mktemp "$@"
                fi
            }
            kconfig_apply_profile() { :; }
            kconfig_apply_policy() {
                kconfig_apply_tick_frequency "$1"
                kconfig_apply_optional_tuning "$1"
            }
            validate_kernel_policy() { validate_tick_frequency "$2" "$1/.config"; }
            reset_config
            if [[ "$workflow_variant" == *-rt-* ]]; then
                "$TREE/scripts/config" --file "$TREE/.config" --enable PREEMPT_RT
            fi
            answers=$'y\ny\ny\ny\nupstream\ny\ny'
            main <<< "$answers" > "$OUTPUT" 2>&1
            selected=$(awk '/TEST: kernel selected/ {print NR; exit}' "$OUTPUT")
            prepared=$(awk '/TEST: sources prepared/ {print NR; exit}' "$OUTPUT")
            tuning=$(awk '/Optional tuning for/ {print NR; exit}' "$OUTPUT")
            [[ -n "$selected" && -n "$prepared" && -n "$tuning" && "$selected" -lt "$prepared" && "$prepared" -lt "$tuning" ]] || fail 'Tuning prompted before selected sources were prepared.'
            if [[ "$workflow_variant" == *bmq* ]]; then
                ! grep -q 'Enable scheduler autogrouping?' "$OUTPUT" || fail 'Workflow offered BMQ autogrouping.'
            elif [[ "$workflow_variant" == *-rt-* ]]; then
                ! grep -q 'Enable transparent hugepages' "$OUTPUT" || fail 'Workflow offered RT THP.'
            else
                grep -q 'Enable scheduler autogrouping?' "$OUTPUT" || fail 'Workflow missed autogrouping.'
                grep -q 'Enable transparent hugepages' "$OUTPUT" || fail 'Workflow missed THP.'
            fi
        )
    done
done
printf 'Optional tuning tests passed (%s).\n' "$PROFILE_NAME"

