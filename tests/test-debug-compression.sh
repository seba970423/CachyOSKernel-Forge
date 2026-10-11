#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/debug-compression.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
TREE="$WORK/tree"
mkdir -p "$TREE/scripts"
cat > "$TREE/scripts/config" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
file="$2" op="$3" symbol="$4"
sed -i -E "/^(CONFIG_${symbol}=.*|# CONFIG_${symbol} is not set)$/d" "$file"
case "$op" in
    --enable) printf 'CONFIG_%s=y\n' "$symbol" >>"$file" ;;
    --disable) printf '# CONFIG_%s is not set\n' "$symbol" >>"$file" ;;
    *) exit 2 ;;
esac
SCRIPT
chmod +x "$TREE/scripts/config"
cat > "$TREE/.config" <<'CONFIG'
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF5=y
# CONFIG_DEBUG_INFO_DWARF4 is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_DEBUG_INFO_COMPRESSED_NONE=y
# CONFIG_DEBUG_INFO_COMPRESSED_ZLIB is not set
# CONFIG_DEBUG_INFO_COMPRESSED_ZSTD is not set
CONFIG_USB_HID=y
CONFIG
cp "$TREE/.config" "$WORK/baseline"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
reset() { cp "$WORK/baseline" "$TREE/.config"; unset BLOCK_ZSTD REMOVE_BTF MAKE_FAIL || true; }
# Only the external Kconfig resolver is mocked. All cleanup, prompts,
# state comparison, and scripts/config invocations run normally.
make() {
    local config='' arg
    for arg in "$@"; do
        [[ "$arg" != KCONFIG_CONFIG=* ]] || config="${arg#KCONFIG_CONFIG=}"
    done
    [[ -n "$config" ]] || config="$TREE/.config"
    [[ "${MAKE_FAIL:-no}" == no ]] || return 2
    if [[ "${BLOCK_ZSTD:-no}" == yes ]]; then
        "$TREE/scripts/config" --file "$config" --disable DEBUG_INFO_COMPRESSED_ZSTD
    fi
    if [[ "${REMOVE_BTF:-no}" == yes ]]; then
        "$TREE/scripts/config" --file "$config" --disable DEBUG_INFO_BTF
    fi
}
reset
kernelforge_choose_dwarf_zstd "$TREE" < /dev/null > /dev/null
[[ "$KERNELFORGE_DWARF_ZSTD" == no ]] || fail 'EOF selected compression'
cmp -s "$WORK/baseline" "$TREE/.config" || fail 'default changed selected config'
kernelforge_apply_dwarf_zstd "$TREE"
kernelforge_validate_dwarf_zstd "$WORK/baseline" "$TREE/.config" >/dev/null
reset
kernelforge_choose_dwarf_zstd "$TREE" <<< n >/dev/null
[[ "$KERNELFORGE_DWARF_ZSTD" == no ]] || fail 'no selected compression'
reset
kernelforge_choose_dwarf_zstd "$TREE" <<< y >/dev/null
[[ "$KERNELFORGE_DWARF_ZSTD" == yes ]] || fail 'yes did not select compression'
cmp -s "$WORK/baseline" "$TREE/.config" || fail 'probe changed real config'
kernelforge_apply_dwarf_zstd "$TREE"
make -C "$TREE" olddefconfig
kernelforge_validate_dwarf_zstd "$WORK/baseline" "$TREE/.config" >/dev/null
[[ "$(kernelforge_debug_state "$TREE/.config" DEBUG_INFO_BTF)" == y ]] || fail 'BTF removed'
[[ "$(kernelforge_debug_state "$TREE/.config" DEBUG_INFO_COMPRESSED_ZSTD)" == y ]] || fail 'Zstd not enabled'
reset
BLOCK_ZSTD=yes kernelforge_choose_dwarf_zstd "$TREE" <<< y >"$WORK/output"
[[ "$KERNELFORGE_DWARF_ZSTD" == no ]] || fail 'unsupported enabled compression'
! grep -q 'Compress DWARF' "$WORK/output" || fail 'unsupported offered prompt'
reset
REMOVE_BTF=yes kernelforge_choose_dwarf_zstd "$TREE" <<< y >"$WORK/output"
[[ "$KERNELFORGE_DWARF_ZSTD" == no ]] || fail 'BTF regression accepted'
reset
MAKE_FAIL=yes
if kernelforge_choose_dwarf_zstd "$TREE" <<< y >"$WORK/output" 2>&1; then
    fail 'probe error did not stop build'
fi
unset MAKE_FAIL
reset
sed -i 's/CONFIG_DEBUG_INFO=y/# CONFIG_DEBUG_INFO is not set/' "$TREE/.config"
kernelforge_choose_dwarf_zstd "$TREE" <<< y >"$WORK/output"
[[ "$KERNELFORGE_DWARF_ZSTD" == no ]] || fail 'no-debug case offered compression'
reset
"$TREE/scripts/config" --file "$TREE/.config" --enable DEBUG_INFO_COMPRESSED_ZSTD
kernelforge_choose_dwarf_zstd "$TREE" <<< y >"$WORK/output"
[[ "$KERNELFORGE_DWARF_ZSTD" == no ]] || fail 'already enabled case offered compression'
reset
KERNELFORGE_DWARF_ZSTD=yes
kernelforge_apply_dwarf_zstd "$TREE"
"$TREE/scripts/config" --file "$TREE/.config" --disable DEBUG_INFO_BTF
if kernelforge_validate_dwarf_zstd "$WORK/baseline" "$TREE/.config" >/dev/null 2>&1; then
    fail 'BTF regression passed validation'
fi
printf 'All optional DWARF Zstd tests passed.\n'
