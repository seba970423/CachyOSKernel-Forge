#!/usr/bin/env bash

set -euo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

detect_cpu() {
    CPU_VENDOR_RAW="$(awk -F ': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)"
    CPU_MODEL="$(awk -F ': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"

    case "$CPU_VENDOR_RAW" in
        GenuineIntel)
            CPU_VENDOR="intel"
            ;;
        AuthenticAMD)
            CPU_VENDOR="amd"
            ;;
        *)
            CPU_VENDOR="unknown"
            ;;
    esac

    if grep -qw vmx /proc/cpuinfo; then
        CPU_HAS_VMX="yes"
    else
        CPU_HAS_VMX="no"
    fi

    if grep -qw svm /proc/cpuinfo; then
        CPU_HAS_SVM="yes"
    else
        CPU_HAS_SVM="no"
    fi

    return 0
}

detect_pci_hardware() {
    have_cmd lspci ||
        die "lspci is required for hardware detection."

    PCI_DUMP="$(lspci -nn)"

    GPU_INTEL="no"
    GPU_AMD="no"
    GPU_NVIDIA="no"
    WIFI_INTEL="no"
    THUNDERBOLT_PRESENT="no"
    NVME_PRESENT="no"

    # Scope GPU vendor detection strictly to display-class PCI devices.
    # This avoids false positives from Intel chipsets, SATA controllers, etc.
    GPU_DUMP="$(grep -Ei 'VGA compatible controller|3D controller|Display controller' <<<"$PCI_DUMP" || true)"

    if [[ -n "$GPU_DUMP" ]]; then
        grep -qi 'Intel' <<<"$GPU_DUMP" && GPU_INTEL="yes" || true
        grep -Eqi 'AMD|ATI' <<<"$GPU_DUMP" && GPU_AMD="yes" || true
        grep -qi 'NVIDIA' <<<"$GPU_DUMP" && GPU_NVIDIA="yes" || true
    fi

    if grep -Ei 'Network controller|Wireless' <<<"$PCI_DUMP" | grep -qi 'Intel'; then
        WIFI_INTEL="yes"
    fi

    # PCI descriptions vary across generations; accept both names.
    if grep -Eqi 'Thunderbolt|USB4' <<<"$PCI_DUMP"; then
        THUNDERBOLT_PRESENT="yes"
    fi

    # Prefer PCI-class detection, but also accept a populated sysfs NVMe class.
    if grep -qi 'Non-Volatile memory controller' <<<"$PCI_DUMP" ||
        compgen -G '/sys/class/nvme/nvme*' >/dev/null; then
        NVME_PRESENT="yes"
    fi

    return 0
}

detect_platform() {
    PLATFORM_VENDOR="unknown"
    PLATFORM_PRODUCT="unknown"
    PLATFORM_FAMILY="unknown"
    PLATFORM_THINKPAD="no"

    if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
        PLATFORM_VENDOR="$(< /sys/class/dmi/id/sys_vendor)"
    fi

    if [[ -r /sys/class/dmi/id/product_name ]]; then
        PLATFORM_PRODUCT="$(< /sys/class/dmi/id/product_name)"
    fi

    if [[ -r /sys/class/dmi/id/product_family ]]; then
        PLATFORM_FAMILY="$(< /sys/class/dmi/id/product_family)"
    fi

    # Lenovo makes many non-ThinkPad systems, so require an actual ThinkPad
    # product/family match instead of treating every Lenovo machine as one.
    if grep -qi 'Lenovo' <<<"$PLATFORM_VENDOR" &&
        grep -qi 'ThinkPad' <<<"$PLATFORM_PRODUCT $PLATFORM_FAMILY"; then
        PLATFORM_THINKPAD="yes"
    fi

    return 0
}

print_hardware_summary() {
    info "CPU vendor: ${CPU_VENDOR:-unknown}"
    info "CPU model: ${CPU_MODEL:-unknown}"
    info "Intel VT-x/VMX: ${CPU_HAS_VMX:-no}"
    info "AMD-V/SVM: ${CPU_HAS_SVM:-no}"

    info "Intel GPU detected: ${GPU_INTEL:-no}"
    info "AMD GPU detected: ${GPU_AMD:-no}"
    info "NVIDIA GPU detected: ${GPU_NVIDIA:-no}"

    info "Intel Wi-Fi detected: ${WIFI_INTEL:-no}"
    info "Thunderbolt/USB4 detected: ${THUNDERBOLT_PRESENT:-no}"
    info "NVMe controller detected: ${NVME_PRESENT:-no}"

    info "Platform vendor: ${PLATFORM_VENDOR:-unknown}"
    info "Platform product: ${PLATFORM_PRODUCT:-unknown}"
    info "Platform family: ${PLATFORM_FAMILY:-unknown}"
    info "ThinkPad detected: ${PLATFORM_THINKPAD:-no}"
}

detect_hardware() {
    detect_cpu
    detect_pci_hardware
    detect_platform

    return 0
}
