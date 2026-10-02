#!/usr/bin/env bash

set -euo pipefail

validation_error() {
    printf 'VALIDATION ERROR: %s\n' "$*" >&2
    return 1
}

config_state() {
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

validate_disabled() {
    local config="$1"
    local symbol="$2"
    local state

    state="$(config_state "$config" "$symbol")"

    if [[ "$state" != "n" && "$state" != "absent" ]]; then
        validation_error \
            "CONFIG_${symbol} should be disabled, but resolved to '${state}'."
        return 1
    fi

    printf '    OK  CONFIG_%s disabled (%s)\n' "$symbol" "$state"
}

validate_enabled_bool() {
    local config="$1"
    local symbol="$2"
    local state

    state="$(config_state "$config" "$symbol")"

    if [[ "$state" != "y" ]]; then
        validation_error \
            "CONFIG_${symbol} should be enabled, but resolved to '${state}'."
        return 1
    fi

    printf '    OK  CONFIG_%s = y\n' "$symbol"
}

validate_enabled_any() {
    local config="$1"
    local symbol="$2"
    local state

    state="$(config_state "$config" "$symbol")"

    if [[ "$state" != "y" && "$state" != "m" ]]; then
        validation_error \
            "CONFIG_${symbol} should be enabled, but resolved to '${state}'."
        return 1
    fi

    printf '    OK  CONFIG_%s enabled as %s\n' "$symbol" "$state"
}

validate_preserved() {
    local baseline="$1"
    local config="$2"
    local symbol="$3"
    local before
    local after

    before="$(config_state "$baseline" "$symbol")"
    after="$(config_state "$config" "$symbol")"

    if [[ "$before" != "$after" ]]; then
        validation_error \
            "CONFIG_${symbol} changed unexpectedly: '${before}' -> '${after}'."
        return 1
    fi

    printf '    OK  CONFIG_%s preserved as %s\n' "$symbol" "$after"
}

validate_profile_invariants() {
    local config="$1"

    if [[ "${PROCESSOR_OPT:-}" == "native" ]]; then
        validate_enabled_bool "$config" X86_NATIVE_CPU || return 1
    fi

    case "${TICKRATE:-}" in
        idle)
            validate_enabled_bool "$config" NO_HZ_IDLE || return 1
            validate_disabled "$config" NO_HZ_FULL || return 1
            validate_disabled "$config" HZ_PERIODIC || return 1
            ;;
        full)
            validate_enabled_bool "$config" NO_HZ_FULL || return 1
            ;;
        periodic)
            validate_enabled_bool "$config" HZ_PERIODIC || return 1
            ;;
    esac
}

# Compare complete symbol lines, including numeric values and choice members.
validate_config_group_preserved() {
    local baseline="$1" config="$2" pattern="$3" label="$4"
    local before after
    before="$(grep -E "$pattern" "$baseline" | LC_ALL=C sort || true)"
    after="$(grep -E "$pattern" "$config" | LC_ALL=C sort || true)"
    if [[ "$before" != "$after" ]]; then
        validation_error "$label changed unexpectedly."
        return 1
    fi
    printf '    OK  %s preserved\n' "$label"
}

validate_tick_frequency() {
    local baseline="$1" config="$2"
    local hz="${KERNEL_HZ:-upstream}"
    local line count=0

    case "$hz" in
        upstream)
            validate_config_group_preserved "$baseline" "$config" \
                '^(CONFIG_HZ(=[0-9]+|_[0-9]+=.*)|# CONFIG_HZ(_[0-9]+)? is not set)$' \
                'Upstream tick frequency' || return 1
            ;;
        100|250|300|1000)
            validate_enabled_bool "$config" "HZ_$hz" || return 1
            if ! grep -qx "CONFIG_HZ=$hz" "$config"; then
                validation_error "CONFIG_HZ did not resolve to requested frequency $hz."
                return 1
            fi
            while read -r line; do
                [[ -n "$line" ]] || continue
                count=$((count + 1))
            done < <(grep -E '^CONFIG_HZ_[0-9]+=y$' "$config" || true)
            if [[ "$count" != 1 ]]; then
                validation_error "Expected exactly one enabled HZ frequency choice, found $count."
                return 1
            fi
            printf '    OK  CONFIG_HZ = %s\n' "$hz"
            ;;
        *) validation_error "Invalid KERNEL_HZ: $hz"; return 1 ;;
    esac


    if [[ "${ENABLE_AUTOGROUP:-no}" == yes ]]; then
        validate_enabled_bool "$config" SCHED_AUTOGROUP || return 1
    else
        validate_config_group_preserved "$baseline" "$config" \
            '^(CONFIG_SCHED_AUTOGROUP=.*|# CONFIG_SCHED_AUTOGROUP is not set)$' \
            'Scheduler autogrouping' || return 1
    fi
    if [[ "${ENABLE_THP_MADVISE:-no}" == yes ]]; then
        validate_disabled "$config" PREEMPT_RT || return 1
        validate_enabled_bool "$config" TRANSPARENT_HUGEPAGE || return 1
        validate_enabled_bool "$config" TRANSPARENT_HUGEPAGE_MADVISE || return 1
        validate_disabled "$config" TRANSPARENT_HUGEPAGE_ALWAYS || return 1
        validate_disabled "$config" TRANSPARENT_HUGEPAGE_NEVER || return 1
    else
        validate_config_group_preserved "$baseline" "$config" \
            '^(CONFIG_TRANSPARENT_HUGEPAGE[A-Z0-9_]*=.*|# CONFIG_TRANSPARENT_HUGEPAGE[A-Z0-9_]* is not set)$' \
            'Transparent hugepage configuration' || return 1
    fi

}

validate_kernel_policy() {
    local tree="$1"
    local baseline="$2"
    local config="$tree/.config"

    [[ -f "$baseline" ]] || {
        validation_error "Baseline config does not exist: $baseline"
        return 1
    }

    [[ -f "$config" ]] || {
        validation_error "Resolved config does not exist: $config"
        return 1
    }

    printf '==> Validating resolved kernel configuration...\n'

    # Portable profile invariants.
    validate_profile_invariants "$config" || return 1

    # Standard virtualization: keep means preserve upstream state.
    if [[ "${KEEP_KVM:-no}" == "yes" ]]; then
        case "${CPU_VENDOR:-unknown}" in
            intel)
                validate_preserved "$baseline" "$config" KVM_INTEL || return 1
                ;;
            amd)
                validate_preserved "$baseline" "$config" KVM_AMD || return 1
                ;;
        esac
    else
        case "${CPU_VENDOR:-unknown}" in
            intel)
                validate_disabled "$config" KVM_INTEL || return 1
                ;;
            amd)
                validate_disabled "$config" KVM_AMD || return 1
                ;;
        esac
    fi

    # Advanced virtualization.
    if [[ "${CPU_VENDOR:-unknown}" == "intel" ]]; then
        if [[ "${ENABLE_INTEL_TDX:-no}" == "yes" ]]; then
            validate_enabled_bool "$config" KVM_INTEL_TDX || return 1
        else
            validate_disabled "$config" KVM_INTEL_TDX || return 1
        fi
    fi

    if [[ "${CPU_VENDOR:-unknown}" == "amd" ]]; then
        if [[ "${ENABLE_AMD_SEV:-no}" == "yes" ]]; then
            validate_enabled_bool "$config" KVM_AMD_SEV || return 1
        else
            validate_disabled "$config" KVM_AMD_SEV || return 1
        fi
    fi

    # Graphics.
    if [[ "${KEEP_I915:-yes}" == "yes" ]]; then
        validate_preserved "$baseline" "$config" DRM_I915 || return 1
    else
        validate_disabled "$config" DRM_I915 || return 1
    fi

    if [[ "${KEEP_AMDGPU:-yes}" == "yes" ]]; then
        validate_preserved "$baseline" "$config" DRM_AMDGPU || return 1
    else
        validate_disabled "$config" DRM_AMDGPU || return 1
    fi

    if [[ "${KEEP_NOUVEAU:-yes}" == "yes" ]]; then
        validate_preserved "$baseline" "$config" DRM_NOUVEAU || return 1
    else
        validate_disabled "$config" DRM_NOUVEAU || return 1
    fi

    # Intel Wi-Fi.
    if [[ "${KEEP_IWLWIFI:-yes}" == "yes" ]]; then
        validate_preserved "$baseline" "$config" IWLWIFI || return 1
    else
        validate_disabled "$config" IWLWIFI || return 1
    fi

    # Thunderbolt / USB4.
    if [[ "${KEEP_THUNDERBOLT:-yes}" == "yes" ]]; then
        validate_preserved "$baseline" "$config" USB4 || return 1
    else
        validate_disabled "$config" USB4 || return 1
    fi

    validate_tick_frequency "$baseline" "$config" || return 1

    # Specialized NVMe functionality.
    local symbol
    if [[ "${ENABLE_NVME_FABRICS:-no}" == "yes" ]]; then
        for symbol in NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP; do
            validate_enabled_any "$config" "$symbol" || return 1
        done
    else
        for symbol in NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP; do
            validate_disabled "$config" "$symbol" || return 1
        done
    fi

    if [[ "${ENABLE_NVME_TARGET:-no}" == "yes" ]]; then
        validate_enabled_any "$config" NVME_TARGET || return 1
    else
        validate_disabled "$config" NVME_TARGET || return 1
    fi

    # Ordinary local NVMe must never be altered by Fabrics/Target policy.
    validate_preserved "$baseline" "$config" BLK_DEV_NVME || return 1

    printf '==> Kernel policy validation passed.\n'
}
