#!/usr/bin/env bash

set -euo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer

    case "$default" in
        yes|no) ;;
        *) die "Invalid yes/no default: $default" ;;
    esac

    while true; do
        if [[ "$default" == "yes" ]]; then
            printf '%s [Y/n]: ' "$prompt"
        else
            printf '%s [y/N]: ' "$prompt"
        fi

        read -r answer || answer=""

        if [[ -z "$answer" ]]; then
            [[ "$default" == "yes" ]]
            return
        fi

        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) printf 'Please answer yes or no.\n' ;;
        esac
    done
}

resolve_virtualization_policy() {
    KEEP_KVM="yes"
    KEEP_INTEL_TDX="yes"
    KEEP_AMD_SEV="yes"

    if ! ask_yes_no "Keep standard KVM virtualization support?" "$DEFAULT_KEEP_KVM"; then
        KEEP_KVM="no"
        # Confidential-VM support depends on KVM. Do not offer a contradictory
        # keep choice or later reject the intentional dependency removal.
        KEEP_INTEL_TDX="no"
        KEEP_AMD_SEV="no"
        info "KVM removal also removes dependent Intel TDX and AMD SEV support."
        return 0
    fi

    case "${CPU_VENDOR:-unknown}" in
        intel)
            if ! ask_yes_no "Keep Intel TDX support?" "$DEFAULT_KEEP_INTEL_TDX"; then
                KEEP_INTEL_TDX="no"
            fi
            ;;
        amd)
            if ! ask_yes_no "Keep AMD SEV support?" "$DEFAULT_KEEP_AMD_SEV"; then
                KEEP_AMD_SEV="no"
            fi
            ;;
    esac
}

resolve_tick_frequency_policy() {
    local answer
    case "${DEFAULT_KERNEL_HZ:-upstream}" in
        upstream|100|250|300|1000) ;;
        *) die "Invalid DEFAULT_KERNEL_HZ: ${DEFAULT_KERNEL_HZ:-unset}" ;;
    esac
    printf 'Kernel tick frequency: upstream (keep selected kernel default) / 100 / 250 / 300 / 1000 Hz.\n'
    printf 'This does not change tickless mode, scheduler autogrouping or transparent hugepages.\n'
    while true; do
        printf 'Choose tick frequency [%s]: ' "${DEFAULT_KERNEL_HZ:-upstream}"
        read -r answer || answer=""
        answer="${answer:-${DEFAULT_KERNEL_HZ:-upstream}}"
        case "$answer" in
            upstream|100|250|300|1000)
                KERNEL_HZ="$answer"
                return 0
                ;;
            *) printf 'Please enter upstream, 100, 250, 300 or 1000.\n' ;;
        esac
    done
}

resolve_nvme_policy() {
    if ask_yes_no \
        "Keep NVMe-over-Fabrics support?" \
        "$DEFAULT_KEEP_NVME_FABRICS"
    then
        KEEP_NVME_FABRICS="yes"
    else
        KEEP_NVME_FABRICS="no"
    fi

    if ask_yes_no \
        "Keep NVMe Target functionality?" \
        "$DEFAULT_KEEP_NVME_TARGET"
    then
        KEEP_NVME_TARGET="yes"
    else
        KEEP_NVME_TARGET="no"
    fi
}

resolve_policy() {
    resolve_virtualization_policy
    resolve_nvme_policy
}

print_policy_summary() {
    info "Resolved kernel policy:"
    printf '    Standard KVM:        %s\n' "$KEEP_KVM"
    printf '    Intel TDX:           %s\n' "$KEEP_INTEL_TDX"
    printf '    AMD SEV:             %s\n' "$KEEP_AMD_SEV"
    printf '    Hardware/platforms:  preserve upstream desktop support\n'
    print_kernel_tuning_summary
    printf '    NVMe Fabrics:        %s\n' "$KEEP_NVME_FABRICS"
    printf '    NVMe Target:         %s\n' "$KEEP_NVME_TARGET"
}

# Called only after selecting and preparing the kernel and saving its baseline.
resolve_kernel_tuning_policy() {
    local tree="$1" variant="$2"
    ENABLE_AUTOGROUP="no"
    ENABLE_THP_MADVISE="no"
    kconfig_detect_tuning_support "$tree" "$variant" || return 1

    printf '\n'
    info "Optional tuning for $variant (n or Enter keeps upstream settings)."
    resolve_tick_frequency_policy
    if [[ "$AUTOGROUP_SUPPORTED" == "yes" ]]; then
        if ask_yes_no "Enable scheduler autogrouping? (n keeps upstream)" no; then
            ENABLE_AUTOGROUP="yes"
        fi
    fi
    if [[ "$THP_SUPPORTED" == "yes" ]]; then
        if ask_yes_no "Enable transparent hugepages in madvise mode? (n keeps upstream)" no; then
            ENABLE_THP_MADVISE="yes"
        fi
    fi
}

print_kernel_tuning_summary() {
    printf '    Tick frequency:      %s\n' "${KERNEL_HZ:-upstream}"
    if [[ "${AUTOGROUP_SUPPORTED:-no}" == "yes" ]]; then
        if [[ "${ENABLE_AUTOGROUP:-no}" == "yes" ]]; then
            printf '    Autogrouping:        enable\n'
        else
            printf '    Autogrouping:        keep upstream\n'
        fi
    fi
    if [[ "${THP_SUPPORTED:-no}" == "yes" ]]; then
        if [[ "${ENABLE_THP_MADVISE:-no}" == "yes" ]]; then
            printf '    Transparent HP:      enable (madvise)\n'
        else
            printf '    Transparent HP:      keep upstream\n'
        fi
    fi
}

