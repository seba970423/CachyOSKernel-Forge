#!/usr/bin/env bash

set -euo pipefail

UPSTREAM_URL="https://github.com/CachyOS/linux-cachyos.git"
UPSTREAM_BRANCH="master"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

validate_upstream_repo() {
    local root="$1"

    info "Validating CachyOS upstream repository..."

    [[ -d "$root/.git" ]] ||
        die "Downloaded source is not a Git repository."

    info "Upstream repository looks valid."
}

discover_kernel_variants() {
    local root="$1"
    local dir

    [[ -d "$root" ]] ||
        die "Upstream root does not exist: $root"

    for dir in "$root"/linux-cachyos*; do
        [[ -d "$dir" ]] || continue
        [[ -f "$dir/PKGBUILD" ]] || continue
        [[ -f "$dir/config" ]] || continue
        basename "$dir"
    done | sort -V
}

select_kernel_variant() {
    local root="$1"
    local -a variants=()
    local variant
    local default_index=1
    local answer
    local i

    while IFS= read -r variant; do
        [[ -n "$variant" ]] && variants+=("$variant")
    done < <(discover_kernel_variants "$root")

    (( ${#variants[@]} > 0 )) ||
        die "No compatible-looking CachyOS kernel package directories were discovered."

    for i in "${!variants[@]}"; do
        if [[ "${variants[$i]}" == "linux-cachyos" ]]; then
            default_index=$((i + 1))
            break
        fi
    done

    printf 'Available CachyOS kernel variants:\n\n' >&2
    for i in "${!variants[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${variants[$i]}" >&2
    done
    printf '\n' >&2

    while true; do
        read -r -p "Select kernel variant [$default_index]: " answer
        answer="${answer:-$default_index}"

        if [[ "$answer" =~ ^[0-9]+$ ]] &&
           (( answer >= 1 && answer <= ${#variants[@]} )); then
            printf '%s\n' "${variants[$((answer - 1))]}"
            return 0
        fi

        printf 'Invalid selection. Choose a number from 1 to %d.\n' \
            "${#variants[@]}" >&2
    done
}

validate_kernel_variant() {
    local root="$1"
    local variant="$2"
    local kernel_dir="$root/$variant"
    local pkgbuild="$kernel_dir/PKGBUILD"

    info "Validating selected kernel variant: $variant"

    [[ "$variant" == linux-cachyos* ]] ||
        die "Refusing unexpected kernel variant name: $variant"

    [[ -d "$kernel_dir" ]] ||
        die "Selected kernel directory is missing: $variant"

    [[ -f "$pkgbuild" ]] ||
        die "Selected variant is missing PKGBUILD: $variant"

    [[ -f "$kernel_dir/config" ]] ||
        die "Selected variant is missing config: $variant"

    grep -q '_processor_opt' "$pkgbuild" ||
        die "$variant PKGBUILD no longer exposes _processor_opt."

    grep -q '_tickrate' "$pkgbuild" ||
        die "$variant PKGBUILD no longer exposes _tickrate."

    grep -q 'prepare()' "$pkgbuild" ||
        die "$variant PKGBUILD no longer contains prepare()."

    grep -q 'scripts/config' "$pkgbuild" ||
        die "$variant PKGBUILD no longer uses scripts/config as expected."

    grep -Eq '^[[:space:]]*cp[[:space:]]+\.\./config[[:space:]]+\.config[[:space:]]*$' "$pkgbuild" ||
        die "$variant PKGBUILD no longer copies ../config to .config as expected."

    info "Selected kernel variant looks compatible."
}

install_upstream_prepare_compat() {
    local root="$1"
    local variant="$2"
    local kernel_dir="$root/$variant"
    local pkgbuild="$kernel_dir/PKGBUILD"
    local config="$kernel_dir/config"
    local symbol="CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS"
    local tmp

    [[ -f "$pkgbuild" ]] ||
        die "Cannot install prepare compatibility hook: PKGBUILD is missing."

    [[ -f "$config" ]] ||
        die "Cannot install prepare compatibility hook: config is missing."

    # Do not touch the checksum-protected source config. If upstream still
    # carries the stale module value, inject a tiny prepare() hook that fixes
    # the copied kernel .config only after makepkg has verified all sources.
    if grep -qx "${symbol}=m" "$config"; then
        info "Installing prepare-time compatibility fix for stale ${symbol}=m..."

        tmp="${pkgbuild}.seba-tmp"

        if ! awk '
            {
                print
            }

            /^[[:space:]]*cp[[:space:]]+\.\.\/config[[:space:]]+\.config[[:space:]]*$/ && !inserted {
                print ""
                print "    # Seba builder: compatibility fix for a bool symbol that upstream"
                print "    # config may still carry as a module. Applied only to the copied"
                print "    # kernel .config, after makepkg source verification."
                print "    if grep -qx '\''CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS=m'\'' .config; then"
                print "        echo '\''Correcting stale CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS=m...'\''"
                print "        scripts/config --enable SND_SOC_ACPI_AMD_SDCA_QUIRKS"
                print "    fi"
                inserted=1
            }

            END {
                if (!inserted)
                    exit 42
            }
        ' "$pkgbuild" >"$tmp"; then
            rm -f "$tmp"
            die "Could not locate the expected 'cp ../config .config' line in $variant prepare()."
        fi

        mv "$tmp" "$pkgbuild"

        grep -q "Seba builder: compatibility fix" "$pkgbuild" ||
            die "Failed to install prepare-time compatibility hook."
    elif grep -Eq "^${symbol}=(y|n)$|^# ${symbol} is not set$" "$config"; then
        info "${symbol} already has a valid bool value; no compatibility hook needed."
    else
        info "${symbol} is absent from selected variant config; no compatibility hook needed."
    fi
}

fetch_upstream() {
    local destination="$1"

    if [[ -e "$destination" ]]; then
        die "Destination already exists: $destination"
    fi

    info "Fetching latest CachyOS kernel sources..."

    git clone \
        --branch "$UPSTREAM_BRANCH" \
        --single-branch \
        "$UPSTREAM_URL" \
        "$destination"

    validate_upstream_repo "$destination"

    info "Fetched upstream revision:"
    git -C "$destination" rev-parse --short HEAD
}
