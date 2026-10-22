#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/build.sh"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-shared-build.XXXXXX)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT
TREE="$TEST_TMPDIR/tree"
mkdir -p "$TREE"
printf 'CONFIG_TEST=y\n' >"$TREE/.config"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Check explicit failure propagation when the helper itself runs inside an if;
# Bash disables implicit errexit in that context.
for failed_stage in tree normalize tuning choose profile policy apply resolve validate debug; do
    (
        calls=0
        kconfig_require_tree() { [[ "$failed_stage" != tree ]]; }
        make() { calls=$((calls+1)); [[ "$failed_stage" != normalize && ( "$failed_stage" != resolve || "$calls" != 2 ) ]]; }
        resolve_kernel_tuning_policy() { [[ "$failed_stage" != tuning ]]; }
        kernelforge_choose_dwarf_zstd() { [[ "$failed_stage" != choose ]]; }
        print_policy_summary() { :; }
        kconfig_apply_profile() { [[ "$failed_stage" != profile ]]; }
        kconfig_apply_policy() { [[ "$failed_stage" != policy ]]; }
        kernelforge_apply_dwarf_zstd() { [[ "$failed_stage" != apply ]]; }
        validate_kernel_policy() { [[ "$failed_stage" != validate ]]; }
        kernelforge_validate_dwarf_zstd() { [[ "$failed_stage" != debug ]]; }
        if configure_and_validate_kernel "$TREE" linux-cachyos >/dev/null 2>&1; then
            fail "Shared pipeline ignored $failed_stage failure."
        fi
    )
done
# Both entry points execute actual shared preparation and naming through main.
# Only external command checks, hardware probing and upstream access are mocked.
for entry in builder.sh builder-dry-run.sh; do
    (
        source "$REPO_ROOT/lib/profile.sh"
        source "$REPO_ROOT/lib/policy.sh"
        source "$REPO_ROOT/lib/naming.sh"
        eval "$(awk '/^main\(\) \{/ {printing=1} /^main "\$@"$/ {printing=0} printing' "$REPO_ROOT/$entry")"
        require_build_commands() { :; }
        detect_hardware() { CPU_VENDOR=intel; }
        print_hardware_summary() { :; }
        fetch_upstream() {
            mkdir -p "$1/linux-cachyos"
            printf '_pkgsuffix=cachyos\npkgbase="linux-$_pkgsuffix"\n' >"$1/linux-cachyos/PKGBUILD"
        }
        select_kernel_variant() { printf 'linux-cachyos\n'; }
        validate_kernel_variant() { :; }
        install_upstream_prepare_compat() { :; }
        ensure_upstream_pgp_keys() { :; }
        makepkg() {
            [[ "$*" == '-s -o' ]] || fail 'Preparation did not request dependencies.'
            mkdir -p src/linux/scripts
            printf '#!/usr/bin/env bash\n' >src/linux/scripts/config
            printf '%s\n' "$TMPDIR" >"$TEST_TMPDIR/$entry.tmpdir"
        }
        configure_and_validate_kernel() {
            grep -qx '_pkgsuffix="desktop-test"' "$(dirname "$(dirname "$1")")/PKGBUILD" || fail 'Dry/full naming was not applied before configuration.'
        }
        ask_compile() { return 1; }
        mktemp() {
            [[ "$*" == *--tmpdir=/var/tmp* ]] || fail 'Workflow used the default temp mount.'
            mkdir -p "$TEST_TMPDIR/$entry-work"
            printf '%s\n' "$TEST_TMPDIR/$entry-work"
        }
        main <<< $'y\ny\ny\ny\ny\ndesktop-test' >"$TEST_TMPDIR/$entry.log" 2>&1
        [[ "$(cat "$TEST_TMPDIR/$entry.tmpdir")" == "$TEST_TMPDIR/$entry-work/tmp" ]] || fail 'Preparation did not receive the workspace TMPDIR.'
    )
done
# Failures in verification/preparation and ambiguous prepared trees stop work.
for preparation_failure in pgp makepkg missing ambiguous; do
    (
        package="$TEST_TMPDIR/failure-$preparation_failure/linux-cachyos"
        mkdir -p "$package/src"
        ensure_upstream_pgp_keys() { [[ "$preparation_failure" != pgp ]]; }
        makepkg() {
            [[ "$preparation_failure" != makepkg ]] || return 1
            if [[ "$preparation_failure" == ambiguous ]]; then
                mkdir -p src/one/scripts src/two/scripts
                touch src/one/scripts/config src/two/scripts/config
            fi
        }
        if prepare_upstream_source "$(dirname "$package")" linux-cachyos >/dev/null 2>&1; then
            fail "Preparation ignored $preparation_failure failure."
        fi
    )
done
printf 'Shared preparation, naming and failure propagation tests passed.\n'
