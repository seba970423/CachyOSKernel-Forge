#!/usr/bin/env bash
# Optional DWARF compression: preserve upstream unless explicitly selected.

kernelforge_debug_state() {
    local config="$1" symbol="$2"
    if grep -qx "CONFIG_${symbol}=y" "$config"; then
        printf 'y'
    elif grep -qx "# CONFIG_${symbol} is not set" "$config"; then
        printf 'n'
    else
        printf 'absent'
    fi
}

kernelforge_debug_group() {
    local config="$1"
    grep -E '^(CONFIG_DEBUG_INFO($|_)|# CONFIG_DEBUG_INFO(_[A-Z0-9]+)* is not set$)' "$config" | LC_ALL=C sort || true
}

# Kconfig probe in a disposable file. Return 0=supported, 1=unavailable,
# 2=probe error (fail closed, never silently change the selected .config).
kernelforge_probe_dwarf_zstd() (
    local tree="$1" probe original="$tree/.config"
    [[ -f "$original" && -x "$tree/scripts/config" ]] || return 2
    [[ "$(kernelforge_debug_state "$original" DEBUG_INFO)" == y ]] || return 1
    [[ "$(kernelforge_debug_state "$original" DEBUG_INFO_COMPRESSED_ZSTD)" != y ]] || return 1

    probe="$(mktemp "$tree/.config.kernelforge-zstd-probe.XXXXXX")" || return 2
    trap 'rm -f -- "$probe" "$probe.old" "$probe.log"' EXIT
    cp -- "$original" "$probe" || return 2
    "$tree/scripts/config" --file "$probe" --disable DEBUG_INFO_COMPRESSED_NONE || return 2
    "$tree/scripts/config" --file "$probe" --disable DEBUG_INFO_COMPRESSED_ZLIB || return 2
    "$tree/scripts/config" --file "$probe" --enable DEBUG_INFO_COMPRESSED_ZSTD || return 2

    if ! make -C "$tree" KCONFIG_CONFIG="$probe" olddefconfig >"$probe.log" 2>&1; then
        printf 'ERROR: DWARF Zstd compatibility probe failed.\n' >&2
        cat "$probe.log" >&2
        return 2
    fi
    [[ "$(kernelforge_debug_state "$probe" DEBUG_INFO_COMPRESSED_ZSTD)" == y ]] || return 1
    [[ "$(kernelforge_debug_state "$probe" DEBUG_INFO)" == y ]] || return 1
    local symbol
    for symbol in DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES DEBUG_INFO_DWARF4 DEBUG_INFO_DWARF5; do
        [[ "$(kernelforge_debug_state "$probe" "$symbol")" == \
           "$(kernelforge_debug_state "$original" "$symbol")" ]] || return 1
    done
    return 0
)

kernelforge_choose_dwarf_zstd() {
    local tree="$1" status answer=''
    KERNELFORGE_DWARF_ZSTD='no'
    if [[ "$(kernelforge_debug_state "$tree/.config" DEBUG_INFO)" != y ]]; then
        printf '==> Space-saving DWARF compression: not applicable (debug information disabled).\n'
        return 0
    fi
    if [[ "$(kernelforge_debug_state "$tree/.config" DEBUG_INFO_COMPRESSED_ZSTD)" == y ]]; then
        printf '==> Space-saving DWARF compression: already enabled upstream.\n'
        return 0
    fi
    if kernelforge_probe_dwarf_zstd "$tree"; then
        :
    else
        status=$?
        if [[ "$status" == 1 ]]; then
            printf '==> Space-saving DWARF compression unavailable; keeping upstream configuration.\n'
            return 0
        fi
        return "$status"
    fi
    printf '\n'
    if IFS= read -r -p 'Compress DWARF debug information with Zstandard to reduce build size? [y/N]: ' answer; then
        :
    else
        answer=''
    fi
    case "$answer" in
        y|Y|yes|YES|Yes) KERNELFORGE_DWARF_ZSTD='yes' ;;
        *) KERNELFORGE_DWARF_ZSTD='no' ;;
    esac
}

kernelforge_apply_dwarf_zstd() {
    local tree="$1"
    case "${KERNELFORGE_DWARF_ZSTD:-no}" in
        no) return 0 ;;
        yes)
            "$tree/scripts/config" --file "$tree/.config" --disable DEBUG_INFO_COMPRESSED_NONE || return 1
            "$tree/scripts/config" --file "$tree/.config" --disable DEBUG_INFO_COMPRESSED_ZLIB || return 1
            "$tree/scripts/config" --file "$tree/.config" --enable DEBUG_INFO_COMPRESSED_ZSTD || return 1
            ;;
        *) printf 'ERROR: Invalid DWARF compression selection.\n' >&2; return 1 ;;
    esac
}

kernelforge_validate_dwarf_zstd() {
    local baseline="$1" config="$2" before after
    [[ -f "$baseline" && -f "$config" ]] || return 1
    case "${KERNELFORGE_DWARF_ZSTD:-no}" in
        no)
            before="$(kernelforge_debug_group "$baseline")"
            after="$(kernelforge_debug_group "$config")"
            if [[ "$before" != "$after" ]]; then
                printf 'ERROR: Upstream DWARF/BTF configuration unexpectedly changed.\n' >&2
                return 1
            fi
            printf '    OK  DWARF/BTF debug settings preserved from upstream.\n'
            ;;
        yes)
            [[ "$(kernelforge_debug_state "$config" DEBUG_INFO_COMPRESSED_ZSTD)" == y ]] || {
                printf 'ERROR: Requested DWARF Zstd compression did not resolve.\n' >&2
                return 1
            }
            [[ "$(kernelforge_debug_state "$config" DEBUG_INFO_COMPRESSED_NONE)" != y &&
               "$(kernelforge_debug_state "$config" DEBUG_INFO_COMPRESSED_ZLIB)" != y ]] || {
                printf 'ERROR: Multiple DWARF compression modes enabled.\n' >&2
                return 1
            }
            local symbol
            for symbol in DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES DEBUG_INFO_DWARF4 DEBUG_INFO_DWARF5; do
                [[ "$(kernelforge_debug_state "$baseline" "$symbol")" == \
                   "$(kernelforge_debug_state "$config" "$symbol")" ]] || {
                    printf 'ERROR: CONFIG_%s changed while enabling DWARF compression.\n' "$symbol" >&2
                    return 1
                }
            done
            printf '    OK  DWARF Zstd enabled; BTF and DWARF version preserved.\n'
            ;;
        *) printf 'ERROR: Invalid DWARF compression selection.\n' >&2; return 1 ;;
    esac
}
