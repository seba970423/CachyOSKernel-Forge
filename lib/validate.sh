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

    # Preserve exact hardware settings across every supported vendor. Disabled
    # or absent upstream features are legitimate (e.g. Hardened hibernation).
    local prefixes pattern symbol
    prefixes="$(IFS='|'; printf '%s' "${PRESERVE_HARDWARE_PREFIXES[*]}")"
    pattern="^(CONFIG_(${prefixes})[A-Z0-9_]*=.*|# CONFIG_(${prefixes})[A-Z0-9_]* is not set)$"
    validate_config_group_preserved "$baseline" "$config" "$pattern" \
        'Desktop hardware and platform support' || return 1

    for symbol in KVM KVM_INTEL KVM_AMD; do
        if [[ "${KEEP_KVM:-yes}" == yes ]]; then
            validate_preserved "$baseline" "$config" "$symbol" || return 1
        else
            validate_disabled "$config" "$symbol" || return 1
        fi
    done
    for symbol in KVM_INTEL_TDX KVM_AMD_SEV; do
        local keep="${KEEP_INTEL_TDX:-yes}"
        [[ "$symbol" != KVM_AMD_SEV ]] || keep="${KEEP_AMD_SEV:-yes}"
        if [[ "${KEEP_KVM:-yes}" == yes && "$keep" == yes ]]; then
            validate_preserved "$baseline" "$config" "$symbol" || return 1
        else
            validate_disabled "$config" "$symbol" || return 1
        fi
    done

    validate_tick_frequency "$baseline" "$config" || return 1

    if [[ "${KEEP_NVME_FABRICS:-yes}" == yes ]]; then
        validate_config_group_preserved "$baseline" "$config" \
            '^(CONFIG_NVME_(FABRICS|RDMA|FC|TCP)[A-Z0-9_]*=.*|# CONFIG_NVME_(FABRICS|RDMA|FC|TCP)[A-Z0-9_]* is not set)$' \
            'NVMe Fabrics support' || return 1
    else
        for symbol in NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP; do
            validate_disabled "$config" "$symbol" || return 1
        done
    fi
    if [[ "${KEEP_NVME_TARGET:-yes}" == yes ]]; then
        validate_config_group_preserved "$baseline" "$config" \
            '^(CONFIG_NVME_TARGET[A-Z0-9_]*=.*|# CONFIG_NVME_TARGET[A-Z0-9_]* is not set)$' \
            'NVMe Target support' || return 1
    else
        validate_disabled "$config" NVME_TARGET || return 1
    fi

    printf '==> Kernel policy validation passed.\n'
}
