#!/usr/bin/env bash

set -euo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

load_profile() {
    local repo_root="$1"

    local desktop_conf="$repo_root/profiles/desktop.conf"
    local features_conf="$repo_root/profiles/features.conf"

    [[ -f "$desktop_conf" ]] ||
        die "Missing profile file: $desktop_conf"

    [[ -f "$features_conf" ]] ||
        die "Missing feature file: $features_conf"

    # shellcheck source=/dev/null
    source "$desktop_conf"

    # shellcheck source=/dev/null
    source "$features_conf"

    info "Loaded profile: ${PROFILE_NAME:-unknown} v${PROFILE_VERSION:-unknown}"
}

validate_profile() {
    [[ -n "${PROFILE_NAME:-}" ]] ||
        die "PROFILE_NAME must not be empty."

    [[ -n "${PROFILE_VERSION:-}" ]] ||
        die "PROFILE_VERSION must not be empty."

    [[ "${PROCESSOR_OPT:-}" == "native" ]] ||
        die "Unsupported PROCESSOR_OPT: ${PROCESSOR_OPT:-unset}"

    case "${TICKRATE:-}" in
        idle|full|periodic)
            ;;
        *)
            die "Invalid TICKRATE: ${TICKRATE:-unset}"
            ;;
    esac

    case "${DEFAULT_KEEP_KVM:-}" in
        yes|no)
            ;;
        *)
            die "DEFAULT_KEEP_KVM must be yes or no."
            ;;
    esac

    case "${DEFAULT_ENABLE_INTEL_TDX:-}" in
        yes|no)
            ;;
        *)
            die "DEFAULT_ENABLE_INTEL_TDX must be yes or no."
            ;;
    esac

    case "${DEFAULT_ENABLE_AMD_SEV:-}" in
        yes|no)
            ;;
        *)
            die "DEFAULT_ENABLE_AMD_SEV must be yes or no."
            ;;
    esac

    local auto_setting
    for auto_setting in \
        "${DEFAULT_KEEP_THUNDERBOLT:-}" \
        "${DEFAULT_KEEP_IWLWIFI:-}" \
        "${DEFAULT_KEEP_I915:-}"
    do
        case "$auto_setting" in
            yes|no|auto)
                ;;
            *)
                die "Hardware-related defaults must be yes, no, or auto."
                ;;
        esac
    done

    case "${DEFAULT_AGGRESSIVE_HARDWARE_PRUNING:-no}" in
        yes|no)
            ;;
        *)
            die "DEFAULT_AGGRESSIVE_HARDWARE_PRUNING must be yes or no when set."
            ;;
    esac

    case "${DEFAULT_ENABLE_NVME_FABRICS:-}" in
        yes|no)
            ;;
        *)
            die "DEFAULT_ENABLE_NVME_FABRICS must be yes or no."
            ;;
    esac

    case "${DEFAULT_ENABLE_NVME_TARGET:-}" in
        yes|no)
            ;;
        *)
            die "DEFAULT_ENABLE_NVME_TARGET must be yes or no."
            ;;
    esac

    # These are part of the portable profile contract and are consumed later
    # by the Kconfig/build validation layer.
    declare -p REQUIRE_ENABLED >/dev/null 2>&1 ||
        die "REQUIRE_ENABLED must be defined by desktop.conf."

    declare -p REQUIRE_DISABLED >/dev/null 2>&1 ||
        die "REQUIRE_DISABLED must be defined by desktop.conf."

    info "Profile values are valid."
}

detect_cpu_vendor() {
    local vendor

    vendor="$(awk -F ': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)"

    case "$vendor" in
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

    CPU_MODEL="$(awk -F ': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"

    info "CPU vendor: $CPU_VENDOR"
    info "CPU model: ${CPU_MODEL:-unknown}"
}
