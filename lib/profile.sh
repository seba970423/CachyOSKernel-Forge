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

    local setting
    for setting in DEFAULT_KEEP_INTEL_TDX DEFAULT_KEEP_AMD_SEV \
        DEFAULT_KEEP_NVME_FABRICS DEFAULT_KEEP_NVME_TARGET; do
        case "${!setting:-}" in
            yes|no) ;;
            *) die "$setting must be yes or no." ;;
        esac
    done

    case "${DEFAULT_KERNEL_HZ:-}" in
        upstream|100|250|300|1000)
            ;;
        *)
            die "DEFAULT_KERNEL_HZ must be upstream, 100, 250, 300 or 1000."
            ;;
    esac

    # These are part of the portable profile contract and are consumed later
    # by the Kconfig/build validation layer.
    declare -p REQUIRE_ENABLED >/dev/null 2>&1 ||
        die "REQUIRE_ENABLED must be defined by desktop.conf."

    declare -p REQUIRE_DISABLED >/dev/null 2>&1 ||
        die "REQUIRE_DISABLED must be defined by desktop.conf."

    declare -p PRESERVE_HARDWARE_PREFIXES >/dev/null 2>&1 ||
        die "PRESERVE_HARDWARE_PREFIXES must be defined by desktop.conf."
    (( ${#PRESERVE_HARDWARE_PREFIXES[@]} > 0 )) ||
        die "PRESERVE_HARDWARE_PREFIXES must not be empty."
    local prefix
    for prefix in "${PRESERVE_HARDWARE_PREFIXES[@]}"; do
        [[ "$prefix" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
            die "Invalid hardware preservation prefix: $prefix"
    done

    info "Profile values are valid."
}

