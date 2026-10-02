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
#   KERNEL_HZ
#   ENABLE_AUTOGROUP / ENABLE_THP_MADVISE

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

# Frequency is independent from the existing idle/full/periodic tickless profile.
kconfig_apply_tick_frequency() {
    local tree="$1"
    local hz="${KERNEL_HZ:-upstream}"
    local symbol choices

    case "$hz" in
        upstream) return 0 ;;
        100|250|300|1000) ;;
        *) echo "ERROR: Invalid KERNEL_HZ: $hz" >&2; return 1 ;;
    esac
    kconfig_require_symbol "$tree" "HZ_$hz" || return 1
    kconfig_require_symbol "$tree" HZ || return 1
    # Clear every exposed frequency choice, including variant-specific ones.
    choices="$(grep -RhsE '^[[:space:]]*(menu)?config[[:space:]]+HZ_[0-9]+([[:space:]]|$)' "$tree" |
        awk '{print $2}' | sort -u)"
    [[ -n "$choices" ]] || {
        echo "ERROR: No kernel HZ frequency choices found." >&2
        return 1
    }
    while read -r symbol; do
        kconfig_disable "$tree" "$symbol" || return 1
    done <<< "$choices"
    kconfig_enable "$tree" "HZ_$hz" || return 1
    # CONFIG_HZ is derived by Kconfig; olddefconfig must resolve it.
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

    # --- User-selected tick frequency (no unrelated latency changes) ---
    kconfig_apply_tick_frequency "$tree" || return 1
    kconfig_apply_optional_tuning "$tree" || return 1

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

# Probe dependencies with a separate config. The selected .config is untouched.
# Status 1 means unavailable; status 2 means a probe error, which must stop work.
kconfig_probe_tuning() (
    local tree="$1" feature="$2" probe
    probe="$(mktemp "$tree/.config.kernelforge-probe.XXXXXX")" || return 2
    trap 'rm -f -- "$probe" "$probe.old" "$probe.log"' EXIT
    cp "$tree/.config" "$probe" || return 2
    case "$feature" in
        autogroup)
            "$tree/scripts/config" --file "$probe" --enable SCHED_AUTOGROUP || return 2
            ;;
        thp)
            "$tree/scripts/config" --file "$probe" --enable TRANSPARENT_HUGEPAGE || return 2
            "$tree/scripts/config" --file "$probe" --disable TRANSPARENT_HUGEPAGE_ALWAYS || return 2
            "$tree/scripts/config" --file "$probe" --disable TRANSPARENT_HUGEPAGE_NEVER || return 2
            "$tree/scripts/config" --file "$probe" --enable TRANSPARENT_HUGEPAGE_MADVISE || return 2
            ;;
        *) return 2 ;;
    esac
    if ! make -C "$tree" KCONFIG_CONFIG="$probe" olddefconfig >"$probe.log" 2>&1; then
        printf 'ERROR: Could not check %s Kconfig support.\n' "$feature" >&2
        cat "$probe.log" >&2
        return 2
    fi
    case "$feature" in
        autogroup) [[ "$(kconfig_state "$probe" SCHED_AUTOGROUP)" == y ]] ;;
        thp)
            [[ "$(kconfig_state "$probe" TRANSPARENT_HUGEPAGE)" == y &&
               "$(kconfig_state "$probe" TRANSPARENT_HUGEPAGE_MADVISE)" == y ]]
            ;;
    esac
)

kconfig_detect_tuning_support() {
    local tree="$1" variant="$2" status
    AUTOGROUP_SUPPORTED="no"
    THP_SUPPORTED="no"
    # BMQ is explicitly excluded, even if its source contains the symbol.
    if [[ "$variant" != *bmq* && "$(kconfig_state "$tree/.config" SCHED_ALT)" != y ]] &&
       kconfig_symbol_exists "$tree" SCHED_AUTOGROUP; then
        if kconfig_probe_tuning "$tree" autogroup; then
            AUTOGROUP_SUPPORTED="yes"
        else
            status=$?
            [[ "$status" == 1 ]] || return "$status"
        fi
    fi
    # Guard both the selected RT variant and the resolved preemption mode.
    if [[ "$variant" != linux-cachyos-rt && "$variant" != linux-cachyos-rt-* &&
          "$(kconfig_state "$tree/.config" PREEMPT_RT)" != y ]] &&
       kconfig_symbol_exists "$tree" TRANSPARENT_HUGEPAGE &&
       kconfig_symbol_exists "$tree" TRANSPARENT_HUGEPAGE_MADVISE; then
        if kconfig_probe_tuning "$tree" thp; then
            THP_SUPPORTED="yes"
        else
            status=$?
            [[ "$status" == 1 ]] || return "$status"
        fi
    fi
}

kconfig_apply_optional_tuning() {
    local tree="$1"
    case "${ENABLE_AUTOGROUP:-no}" in
        no) ;;
        yes)
            [[ "${AUTOGROUP_SUPPORTED:-no}" == yes ]] || {
                echo 'ERROR: Autogrouping was requested without verified support.' >&2
                return 1
            }
            kconfig_enable "$tree" SCHED_AUTOGROUP || return 1
            ;;
        *) echo 'ERROR: Invalid autogrouping policy.' >&2; return 1 ;;
    esac
    case "${ENABLE_THP_MADVISE:-no}" in
        no) ;;
        yes)
            [[ "${THP_SUPPORTED:-no}" == yes &&
               "$(kconfig_state "$tree/.config" PREEMPT_RT)" != y ]] || {
                echo 'ERROR: THP was requested without verified non-RT support.' >&2
                return 1
            }
            kconfig_enable "$tree" TRANSPARENT_HUGEPAGE || return 1
            kconfig_disable "$tree" TRANSPARENT_HUGEPAGE_ALWAYS || return 1
            kconfig_disable "$tree" TRANSPARENT_HUGEPAGE_NEVER || return 1
            kconfig_enable "$tree" TRANSPARENT_HUGEPAGE_MADVISE || return 1
            ;;
        *) echo 'ERROR: Invalid transparent hugepage policy.' >&2; return 1 ;;
    esac
}
