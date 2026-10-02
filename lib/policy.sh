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
        yes|no)
            ;;
        *)
            die "Invalid yes/no default: $default"
            ;;
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
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                return 1
                ;;
            *)
                printf 'Please answer yes or no.\n'
                ;;
        esac
    done
}

resolve_virtualization_policy() {
    KEEP_KVM="$DEFAULT_KEEP_KVM"
    ENABLE_INTEL_TDX="no"
    ENABLE_AMD_SEV="no"

    if [[ "$CPU_VENDOR" == "intel" && "$CPU_HAS_VMX" == "yes" ]]; then
        if ask_yes_no \
            "Keep standard Intel KVM virtualization support?" \
            "$DEFAULT_KEEP_KVM"
        then
            KEEP_KVM="yes"

            if ask_yes_no \
                "Enable optional Intel TDX confidential-VM support?" \
                "$DEFAULT_ENABLE_INTEL_TDX"
            then
                ENABLE_INTEL_TDX="yes"
            fi
        else
            KEEP_KVM="no"
        fi

    elif [[ "$CPU_VENDOR" == "amd" && "$CPU_HAS_SVM" == "yes" ]]; then
        if ask_yes_no \
            "Keep standard AMD KVM virtualization support?" \
            "$DEFAULT_KEEP_KVM"
        then
            KEEP_KVM="yes"

            if ask_yes_no \
                "Enable optional AMD SEV confidential-VM support?" \
                "$DEFAULT_ENABLE_AMD_SEV"
            then
                ENABLE_AMD_SEV="yes"
            fi
        else
            KEEP_KVM="no"
        fi
    else
        KEEP_KVM="no"
        info "Hardware virtualization support was not detected."
    fi
}

resolve_hardware_policy() {
    KEEP_I915="yes"
    KEEP_AMDGPU="yes"
    KEEP_NOUVEAU="yes"
    KEEP_IWLWIFI="yes"
    KEEP_THUNDERBOLT="yes"
    PRUNE_ABSENT_HARDWARE="no"

    # Portability is the safe default: absence today does not mean the user
    # will never add/change hardware later.
    if ask_yes_no \
        "Prune support for currently absent i915, Intel Wi-Fi and Thunderbolt/USB4 hardware?" \
        "${DEFAULT_AGGRESSIVE_HARDWARE_PRUNING:-no}"
    then
        PRUNE_ABSENT_HARDWARE="yes"

        if [[ "$GPU_INTEL" == "no" ]]; then
            KEEP_I915="$DEFAULT_KEEP_I915"
        fi

        if [[ "$WIFI_INTEL" == "no" ]]; then
            KEEP_IWLWIFI="$DEFAULT_KEEP_IWLWIFI"
        fi

        if [[ "$THUNDERBOLT_PRESENT" == "no" ]]; then
            KEEP_THUNDERBOLT="$DEFAULT_KEEP_THUNDERBOLT"
        fi

        # "auto" means detected hardware decides.
        [[ "$KEEP_I915" == "auto" ]] && KEEP_I915="$GPU_INTEL"
        [[ "$KEEP_IWLWIFI" == "auto" ]] && KEEP_IWLWIFI="$WIFI_INTEL"
        [[ "$KEEP_THUNDERBOLT" == "auto" ]] && KEEP_THUNDERBOLT="$THUNDERBOLT_PRESENT"
    fi

    # Keep broad discrete-GPU support for portability.
    KEEP_AMDGPU="yes"
    KEEP_NOUVEAU="yes"
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
    ENABLE_NVME_FABRICS="$DEFAULT_ENABLE_NVME_FABRICS"
    ENABLE_NVME_TARGET="$DEFAULT_ENABLE_NVME_TARGET"

    if ask_yes_no \
        "Enable specialized NVMe-over-Fabrics support?" \
        "$DEFAULT_ENABLE_NVME_FABRICS"
    then
        ENABLE_NVME_FABRICS="yes"
    else
        ENABLE_NVME_FABRICS="no"
    fi

    if ask_yes_no \
        "Enable NVMe target/server functionality?" \
        "$DEFAULT_ENABLE_NVME_TARGET"
    then
        ENABLE_NVME_TARGET="yes"
    else
        ENABLE_NVME_TARGET="no"
    fi
}

resolve_policy() {
    resolve_virtualization_policy
    resolve_hardware_policy
    resolve_nvme_policy
}

print_policy_summary() {
    info "Resolved kernel policy:"
    printf '    Standard KVM:        %s\n' "$KEEP_KVM"
    printf '    Intel TDX:           %s\n' "$ENABLE_INTEL_TDX"
    printf '    AMD SEV:             %s\n' "$ENABLE_AMD_SEV"
    printf '    Prune absent HW:     %s\n' "$PRUNE_ABSENT_HARDWARE"
    printf '    Intel i915:          %s\n' "$KEEP_I915"
    printf '    AMDGPU:              %s\n' "$KEEP_AMDGPU"
    printf '    Nouveau:             %s\n' "$KEEP_NOUVEAU"
    printf '    Intel Wi-Fi:         %s\n' "$KEEP_IWLWIFI"
    printf '    Thunderbolt/USB4:    %s\n' "$KEEP_THUNDERBOLT"
    print_kernel_tuning_summary
    printf '    NVMe Fabrics:        %s\n' "$ENABLE_NVME_FABRICS"
    printf '    NVMe Target:         %s\n' "$ENABLE_NVME_TARGET"
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
