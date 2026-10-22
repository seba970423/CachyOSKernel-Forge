#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$REPO_ROOT/lib/upstream.sh"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-source-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT
ROOT="$TEST_TMPDIR/source with spaces"
VARIANT=linux-cachyos-rt-bore
PACKAGE_DIR="$ROOT/$VARIANT"
PKGBUILD="$PACKAGE_DIR/PKGBUILD"
KNOWN_HASH=acaf7cab034098f8728089921ce7ccadd66157e28d6910063e62df59f1fec11546909c36b2cfbde5d3673529d937f40e0b7d38427e64d11dacc33e73c0e3b6d8
MUTABLE_URL=https://raw.githubusercontent.com/cachyos/kernel-patches/master/7.3/sched/0001-bore-cachy.patch
PINNED_URL=https://raw.githubusercontent.com/cachyos/kernel-patches/2b4e3ce8fbd987d83d55fb9aa36c305c68be088c/7.3/sched/0001-bore-cachy.patch
I915_URL=https://raw.githubusercontent.com/cachyos/kernel-patches/master/7.3/misc/0001-rt-i915.patch
mkdir -p "$PACKAGE_DIR"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

write_recipe() {
    local patch_url="${1:-$MUTABLE_URL}" patch_hash="${2:-$KNOWN_HASH}"
    printf 'source=(%q %q %q)\nb2sums=(%q %q %q)\nvalidpgpkeys=(%q)\n' \
        https://example.invalid/kernel.tar.gz "$patch_url" "$I915_URL" \
        kernel-checksum "$patch_hash" i915-checksum \
        E18447AC260021D31F3FF6C4C8A2A4774B8B63C4 >"$PKGBUILD"
    printf 'prepare() { printf "original prepare function\\n"; }\n' >>"$PKGBUILD"
    printf 'CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS=y\n' >"$PACKAGE_DIR/config"
}
snapshot_recipe() (
    source "$PKGBUILD"
    declare -p source b2sums validpgpkeys
    declare -f prepare
)

# Exercise the actual entry point used by both builders, with the BORE source
# between other sources. Only that URL changes; metadata and config survive.
write_recipe
expected="$(
    source "$PKGBUILD"
    source[1]="$PINNED_URL"
    declare -p source b2sums validpgpkeys
    declare -f prepare
)"
cp "$PACKAGE_DIR/config" "$TEST_TMPDIR/original-config"
install_upstream_prepare_compat "$ROOT" "$VARIANT" >/dev/null
[[ "$(snapshot_recipe)" == "$expected" ]] || fail 'Pin changed unrelated recipe settings.'
cmp "$TEST_TMPDIR/original-config" "$PACKAGE_DIR/config" || fail 'Source config was modified.'
cp "$PKGBUILD" "$TEST_TMPDIR/pinned-recipe"
install_upstream_prepare_compat "$ROOT" "$VARIANT" >/dev/null
cmp "$PKGBUILD" "$TEST_TMPDIR/pinned-recipe" || fail 'Repeated compatibility setup changed the recipe.'

# Future/upstream-corrected checksums do not acquire the override.
write_recipe "$MUTABLE_URL" updated-upstream-checksum
cp "$PKGBUILD" "$TEST_TMPDIR/original-recipe"
install_upstream_source_compat "$ROOT" "$VARIANT" >/dev/null
cmp "$PKGBUILD" "$TEST_TMPDIR/original-recipe" || fail 'Unknown checksum changed the recipe.'

# A familiar checksum appearing elsewhere must not authorize a mismatched
# URL/checksum pair, including an upstream SKIP policy.
for checksum in updated-upstream-checksum SKIP; do
    write_recipe "$MUTABLE_URL" "$checksum"
    printf '# Other historical checksum: %s\n' "$KNOWN_HASH" >>"$PKGBUILD"
    before="$(snapshot_recipe)"
    install_upstream_source_compat "$ROOT" "$VARIANT" >/dev/null
    [[ "$(snapshot_recipe)" == "$before" ]] || fail 'Comment checksum authorized a different source.'
done
write_recipe "$MUTABLE_URL" wrong-bore-checksum
printf 'b2sums[0]=%q\n' "$KNOWN_HASH" >>"$PKGBUILD"
before="$(snapshot_recipe)"
install_upstream_source_compat "$ROOT" "$VARIANT" >/dev/null
[[ "$(snapshot_recipe)" == "$before" ]] || fail 'Checksum at a different index authorized the pin.'

# Other versions, hosts, already-pinned URLs and filename aliases retain the
# original source and checksum metadata.
for patch_url in \
    "${MUTABLE_URL/7.3/7.4}" \
    "${MUTABLE_URL/raw.githubusercontent.com/example.invalid}" \
    "$PINNED_URL" \
    "custom.patch::$MUTABLE_URL"; do
    write_recipe "$patch_url"
    before="$(snapshot_recipe)"
    install_upstream_source_compat "$ROOT" "$VARIANT" >/dev/null
    [[ "$(snapshot_recipe)" == "$before" ]] || fail 'Unrelated URL was modified.'
done

# Source arrays expanded from variables are resolved by the hook, matching
# actual CachyOS recipes. The active patch index need not be fixed.
cat >"$PKGBUILD" <<'RECIPE'
_major=7.3
_patchsource="https://raw.githubusercontent.com/cachyos/kernel-patches/master/${_major}"
source=(config)
source+=("${_patchsource}/misc/0001-rt-i915.patch")
source+=("${_patchsource}/sched/0001-bore-cachy.patch")
b2sums=(config-checksum i915-checksum acaf7cab034098f8728089921ce7ccadd66157e28d6910063e62df59f1fec11546909c36b2cfbde5d3673529d937f40e0b7d38427e64d11dacc33e73c0e3b6d8)
validpgpkeys=(E18447AC260021D31F3FF6C4C8A2A4774B8B63C4)
prepare() { :; }
RECIPE
expected="$(
    source "$PKGBUILD"
    source[2]="$PINNED_URL"
    declare -p source b2sums validpgpkeys
    declare -f prepare
)"
install_upstream_source_compat "$ROOT" "$VARIANT" >/dev/null
[[ "$(snapshot_recipe)" == "$expected" ]] || fail 'Expanded source URLs were not pinned at the correct index.'

# Incomplete unrelated metadata must not turn an unset checksum into a pin.
write_recipe
printf 'b2sums=()\n' >>"$PKGBUILD"
before="$(snapshot_recipe)"
install_upstream_source_compat "$ROOT" "$VARIANT" >/dev/null
[[ "$(snapshot_recipe)" == "$before" ]] || fail 'An absent checksum authorized the pin.'

if ( install_upstream_source_compat "$TEST_TMPDIR/missing" "$VARIANT" ) >/dev/null 2>&1; then
    fail 'Missing PKGBUILD passed source compatibility setup.'
fi
printf 'Checksum-pinned upstream source tests passed.\n'
