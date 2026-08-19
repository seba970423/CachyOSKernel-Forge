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

        read -r answer

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
    printf '    NVMe Fabrics:        %s\n' "$ENABLE_NVME_FABRICS"
    printf '    NVMe Target:         %s\n' "$ENABLE_NVME_TARGET"
}
