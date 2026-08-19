#!/usr/bin/env bash

# Kernel Kconfig application and verification layer.
#
# Expected inputs:
#   KEEP_KVM
#   ENABLE_INTEL_TDX
#   ENABLE_AMD_SEV
#   KEEP_I915
#   KEEP_AMDGPU
#   KEEP_NOUVEAU
#   KEEP_IWLWIFI
#   KEEP_THUNDERBOLT
#   ENABLE_NVME_FABRICS
#   ENABLE_NVME_TARGET

kconfig_require_tree() {
    local tree="$1"

    [[ -d "$tree" ]] || {
        echo "ERROR: Kernel source tree does not exist: $tree" >&2
        return 1
    }

    [[ -x "$tree/scripts/config" ]] || {
        echo "ERROR: Kernel scripts/config not found or not executable." >&2
        return 1
    }

    [[ -f "$tree/Makefile" ]] || {
        echo "ERROR: Kernel Makefile not found." >&2
        return 1
    }

    [[ -f "$tree/.config" ]] || {
        echo "ERROR: Kernel .config not found." >&2
        return 1
    }

    return 0
}

kconfig_enable() {
    local tree="$1"
    local symbol="$2"

    "$tree/scripts/config" --file "$tree/.config" --enable "$symbol"
}

kconfig_module() {
    local tree="$1"
    local symbol="$2"

    "$tree/scripts/config" --file "$tree/.config" --module "$symbol"
}

kconfig_disable() {
    local tree="$1"
    local symbol="$2"

    "$tree/scripts/config" --file "$tree/.config" --disable "$symbol"
}

kconfig_state() {
    local config="$1"
    local symbol="$2"

    if grep -q "^CONFIG_${symbol}=y$" "$config"; then
        printf 'y'
    elif grep -q "^CONFIG_${symbol}=m$" "$config"; then
        printf 'm'
    elif grep -q "^# CONFIG_${symbol} is not set$" "$config"; then
        printf 'n'
    else
        printf 'absent'
    fi
}

kconfig_set_bool() {
    local tree="$1"
    local symbol="$2"
    local value="$3"

    case "$value" in
        yes)
            kconfig_enable "$tree" "$symbol"
            ;;
        no)
            kconfig_disable "$tree" "$symbol"
            ;;
        *)
            echo "ERROR: Invalid policy value for CONFIG_${symbol}: $value" >&2
            return 1
            ;;
    esac
}

kconfig_set_tristate() {
    local tree="$1"
    local symbol="$2"
    local value="$3"
    local state

    case "$value" in
        yes)
            state="$(kconfig_state "$tree/.config" "$symbol")"
            if [[ "$state" != "y" && "$state" != "m" ]]; then
                # Prefer a module for explicitly requested optional subsystems.
                kconfig_module "$tree" "$symbol"
            fi
            ;;
        no)
            kconfig_disable "$tree" "$symbol"
            ;;
        *)
            echo "ERROR: Invalid tristate policy value for CONFIG_${symbol}: $value" >&2
            return 1
            ;;
    esac
}

kconfig_symbol_exists() {
    local tree="$1"
    local symbol="$2"

    grep -RqsE \
        "^[[:space:]]*(menu)?config[[:space:]]+${symbol}([[:space:]]|$)" \
        "$tree"
}

kconfig_require_symbol() {
    local tree="$1"
    local symbol="$2"

    if ! kconfig_symbol_exists "$tree" "$symbol"; then
        echo "ERROR: CONFIG_${symbol} does not exist in this kernel source tree." >&2
        return 1
    fi

    return 0
}


kconfig_apply_profile() {
    local tree="$1"

    kconfig_require_tree "$tree" || return 1

    # --- Processor optimization profile ---

    case "${PROCESSOR_OPT:-}" in
        native)
            kconfig_require_symbol "$tree" X86_NATIVE_CPU || return 1
            kconfig_enable "$tree" X86_NATIVE_CPU || return 1
            ;;
        *)
            echo "ERROR: Unsupported PROCESSOR_OPT: ${PROCESSOR_OPT:-unset}" >&2
            return 1
            ;;
    esac

    # --- Scheduler tick profile ---

    case "${TICKRATE:-}" in
        idle)
            kconfig_require_symbol "$tree" NO_HZ_IDLE || return 1
            kconfig_require_symbol "$tree" NO_HZ_FULL || return 1
            kconfig_require_symbol "$tree" HZ_PERIODIC || return 1

            kconfig_enable "$tree" NO_HZ_IDLE || return 1
            kconfig_disable "$tree" NO_HZ_FULL || return 1
            kconfig_disable "$tree" HZ_PERIODIC || return 1
            ;;
        full)
            kconfig_require_symbol "$tree" NO_HZ_FULL || return 1
            kconfig_enable "$tree" NO_HZ_FULL || return 1
            ;;
        periodic)
            kconfig_require_symbol "$tree" HZ_PERIODIC || return 1
            kconfig_enable "$tree" HZ_PERIODIC || return 1
            ;;
        *)
            echo "ERROR: Invalid TICKRATE: ${TICKRATE:-unset}" >&2
            return 1
            ;;
    esac

    return 0
}

kconfig_apply_policy() {
    local tree="$1"

    kconfig_require_tree "$tree" || return 1

    # --- Standard virtualization ---

    if [[ "${KEEP_KVM:-no}" == "no" ]]; then
        case "${CPU_VENDOR:-unknown}" in
            intel)
                kconfig_require_symbol "$tree" KVM_INTEL || return 1
                kconfig_disable "$tree" KVM_INTEL
                ;;
            amd)
                kconfig_require_symbol "$tree" KVM_AMD || return 1
                kconfig_disable "$tree" KVM_AMD
                ;;
        esac
    fi

    # --- Advanced virtualization ---

    if [[ "${CPU_VENDOR:-unknown}" == "intel" ]]; then
        kconfig_require_symbol "$tree" KVM_INTEL_TDX || return 1
        kconfig_set_bool "$tree" KVM_INTEL_TDX "${ENABLE_INTEL_TDX:-no}"
    fi

    if [[ "${CPU_VENDOR:-unknown}" == "amd" ]]; then
        kconfig_require_symbol "$tree" KVM_AMD_SEV || return 1
        kconfig_set_bool "$tree" KVM_AMD_SEV "${ENABLE_AMD_SEV:-no}"
    fi

    # --- Graphics ---

    if [[ "${KEEP_I915:-yes}" == "no" ]]; then
        kconfig_require_symbol "$tree" DRM_I915 || return 1
        kconfig_disable "$tree" DRM_I915
    fi

    if [[ "${KEEP_AMDGPU:-yes}" == "no" ]]; then
        kconfig_require_symbol "$tree" DRM_AMDGPU || return 1
        kconfig_disable "$tree" DRM_AMDGPU
    fi

    if [[ "${KEEP_NOUVEAU:-yes}" == "no" ]]; then
        kconfig_require_symbol "$tree" DRM_NOUVEAU || return 1
        kconfig_disable "$tree" DRM_NOUVEAU
    fi

    # --- Intel Wi-Fi ---

    if [[ "${KEEP_IWLWIFI:-yes}" == "no" ]]; then
        kconfig_require_symbol "$tree" IWLWIFI || return 1
        kconfig_disable "$tree" IWLWIFI
    fi

    # --- Thunderbolt / USB4 ---

    kconfig_require_symbol "$tree" USB4 || return 1

    if [[ "${KEEP_THUNDERBOLT:-yes}" == "no" ]]; then
        kconfig_disable "$tree" USB4
    fi

    # --- Specialized NVMe functionality ---

    local symbol
    for symbol in NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP; do
        kconfig_require_symbol "$tree" "$symbol" || return 1
        kconfig_set_tristate "$tree" "$symbol" "${ENABLE_NVME_FABRICS:-no}" || return 1
    done

    kconfig_require_symbol "$tree" NVME_TARGET || return 1
    kconfig_set_tristate "$tree" NVME_TARGET "${ENABLE_NVME_TARGET:-no}" || return 1

    # Never touch CONFIG_BLK_DEV_NVME here.
    # Local NVMe support is independent from Fabrics/Target policy.

    return 0
}
