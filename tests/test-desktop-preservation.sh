#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/profile.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
load_profile "$REPO_ROOT" >/dev/null
validate_profile >/dev/null
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-desktop-preservation.XXXXXX)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT
TREE="$TEST_TMPDIR/tree" BASELINE="$TEST_TMPDIR/baseline"
mkdir -p "$TREE/scripts"
touch "$TREE/Makefile"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ( "$@" ) >/dev/null 2>&1; then fail "Unexpected success: $*"; fi; }
# Use the captured desktop config, then add a future driver and a string
# setting to prove prefix protection covers more than existing tristates.
cp "$REPO_ROOT/profiles/reference/seba-desktop-v0.4.config" "$BASELINE"
printf 'CONFIG_ASUS_FUTURE_DRIVER=m\nCONFIG_SND_FUTURE_NAME="desktop audio"\n' >>"$BASELINE"
cat >"$TREE/scripts/config" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
file="$2" operation="$3" symbol="$4"
sed -i -E "/^(CONFIG_${symbol}=.*|# CONFIG_${symbol} is not set)$/d" "$file"
case "$operation" in
    --enable) printf 'CONFIG_%s=y\n' "$symbol" >>"$file" ;;
    --disable) printf '# CONFIG_%s is not set\n' "$symbol" >>"$file" ;;
    *) exit 1 ;;
esac
SCRIPT
chmod +x "$TREE/scripts/config"
# Only the external Kconfig writer is substituted. Real profile/policy and
# final validation run against the captured config.
for symbol in X86_NATIVE_CPU NO_HZ_IDLE NO_HZ_FULL HZ_PERIODIC KVM KVM_INTEL KVM_AMD KVM_INTEL_TDX KVM_AMD_SEV NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP NVME_TARGET; do
    printf 'config %s\n    bool\n' "$symbol" >>"$TREE/Kconfig"
done
KEEP_KVM=yes KEEP_INTEL_TDX=yes KEEP_AMD_SEV=yes
KEEP_NVME_FABRICS=yes KEEP_NVME_TARGET=yes KERNEL_HZ=upstream
reset_config() {
    cp "$BASELINE" "$TREE/.config"
    kconfig_apply_profile "$TREE"
    kconfig_apply_policy "$TREE"
}
reset_config
validate_kernel_policy "$TREE" "$BASELINE" >/dev/null
cp "$TREE/.config" "$TEST_TMPDIR/good"
# Representative graphics, multi-vendor platform, input, audio, networking,
# storage, power and guest-independent hardware support must survive.
for symbol in DRM_I915 DRM_AMDGPU DRM_NOUVEAU ASUS_WMI DELL_WMI THINKPAD_ACPI HP_WMI USB_HID HID_PLAYSTATION SND_HDA_INTEL IWLWIFI USB4 SATA_AHCI BLK_DEV_NVME ACPI_BATTERY HIBERNATION ASUS_FUTURE_DRIVER; do
    cp "$TEST_TMPDIR/good" "$TREE/.config"
    state="$(config_state "$BASELINE" "$symbol")"
    if [[ "$state" == y ]]; then
        "$TREE/scripts/config" --file "$TREE/.config" --disable "$symbol"
    else
        "$TREE/scripts/config" --file "$TREE/.config" --enable "$symbol"
    fi
    expect_failure validate_kernel_policy "$TREE" "$BASELINE"
done
cp "$TEST_TMPDIR/good" "$TREE/.config"
sed -i 's/desktop audio/changed audio/' "$TREE/.config"
expect_failure validate_kernel_policy "$TREE" "$BASELINE"
# Variant-disabled hibernation is valid and cannot be forced on.
"$TREE/scripts/config" --file "$BASELINE" --disable HIBERNATION
reset_config
validate_kernel_policy "$TREE" "$BASELINE" >/dev/null
"$TREE/scripts/config" --file "$TREE/.config" --enable HIBERNATION
expect_failure validate_kernel_policy "$TREE" "$BASELINE"
# Explicit capability removals leave all the same hardware checks in force.
KEEP_KVM=no KEEP_INTEL_TDX=no KEEP_AMD_SEV=no
KEEP_NVME_FABRICS=no KEEP_NVME_TARGET=no
reset_config
validate_kernel_policy "$TREE" "$BASELINE" >/dev/null
for symbol in KVM KVM_INTEL KVM_AMD KVM_INTEL_TDX KVM_AMD_SEV NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP NVME_TARGET; do
    validate_disabled "$TREE/.config" "$symbol" >/dev/null
    cp "$TREE/.config" "$TEST_TMPDIR/optout"
    "$TREE/scripts/config" --file "$TREE/.config" --enable "$symbol"
    expect_failure validate_kernel_policy "$TREE" "$BASELINE"
    cp "$TEST_TMPDIR/optout" "$TREE/.config"
done
# Legacy sources with no optional capability declarations remain supported.
cp "$TREE/.config" "$TEST_TMPDIR/before-missing"
: >"$TREE/Kconfig"
kconfig_apply_policy "$TREE"
cmp "$TEST_TMPDIR/before-missing" "$TREE/.config" || fail 'Missing optional symbols were synthesized.'
# Keep is preservation even for disabled/absent upstream capabilities.
KEEP_KVM=yes KEEP_INTEL_TDX=yes KEEP_AMD_SEV=yes
KEEP_NVME_FABRICS=yes KEEP_NVME_TARGET=yes
cp "$TREE/.config" "$BASELINE"
kconfig_apply_policy "$TREE"
validate_kernel_policy "$TREE" "$BASELINE" >/dev/null
printf 'Desktop hardware preservation and opt-out tests passed.\n'
