#!/usr/bin/env bash

# PGP helpers for CachyOSKernel-Forge.
#
# makepkg verifies signed sources with the invoking user's GnuPG keyring.
# We inspect the selected upstream PKGBUILD's validpgpkeys entries before
# source preparation, then offer to retrieve only fingerprints explicitly
# pinned by that PKGBUILD. Signature verification itself is never bypassed.

pgp_info() {
    printf '==> %s\n' "$*" >&2
}

pgp_warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

pgp_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

upstream_valid_pgp_keys() {
    local package_dir="$1"

    (
        cd "$package_dir"
        makepkg --printsrcinfo
    ) 2>/dev/null |
        awk -F ' = ' '
            /^[[:space:]]*validpgpkeys[[:space:]]*=/ {
                key=$2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                key=toupper(key)
                if (key != "")
                    print key
            }
        ' |
        awk '!seen[$0]++'
}

pgp_key_state() {
    local fingerprint="$1"
    local listing

    if ! listing="$(gpg --batch --with-colons --list-keys "$fingerprint" 2>/dev/null)"; then
        printf 'missing\n'
        return 0
    fi

    if awk -F: '$1 == "pub" && $2 == "e" { expired=1 } END { exit !expired }' <<<"$listing"; then
        printf 'expired\n'
    else
        printf 'present\n'
    fi
}

pgp_key_has_fingerprint() {
    local fingerprint="$1"

    gpg --batch --with-colons --fingerprint "$fingerprint" 2>/dev/null |
        awk -F: '$1 == "fpr" { print toupper($10) }' |
        grep -Fxq "$fingerprint"
}

receive_pgp_key() {
    local fingerprint="$1"
    local keyserver

    # The keyserver is only a transport. The complete fingerprint comes from
    # the selected upstream PKGBUILD and is verified after retrieval.
    for keyserver in \
        "hkps://keyserver.ubuntu.com" \
        "hkps://keys.openpgp.org"
    do
        pgp_info "Retrieving $fingerprint from $keyserver..."

        if gpg --batch --keyserver "$keyserver" --recv-keys "$fingerprint" >&2; then
            if pgp_key_has_fingerprint "$fingerprint"; then
                return 0
            fi

            pgp_warn "A key was retrieved, but its fingerprint did not match $fingerprint."
        fi
    done

    return 1
}

ensure_upstream_pgp_keys() {
    local package_dir="$1"
    local -a required=()
    local -a needs_attention=()
    local fingerprint
    local state
    local answer

    pgp_info "Checking upstream PGP signing keys..."

    while IFS= read -r fingerprint; do
        [[ -n "$fingerprint" ]] && required+=("$fingerprint")
    done < <(upstream_valid_pgp_keys "$package_dir")

    if (( ${#required[@]} == 0 )); then
        pgp_info "Selected PKGBUILD declares no validpgpkeys; nothing to import."
        return 0
    fi

    for fingerprint in "${required[@]}"; do
        state="$(pgp_key_state "$fingerprint")"

        case "$state" in
            present)
                ;;
            missing)
                pgp_warn "Required upstream signing key is missing: $fingerprint"
                needs_attention+=("$fingerprint")
                ;;
            expired)
                pgp_warn "Required upstream signing key is expired locally: $fingerprint"
                needs_attention+=("$fingerprint")
                ;;
            *)
                pgp_error "Could not determine GPG state for $fingerprint."
                return 1
                ;;
        esac
    done

    if (( ${#needs_attention[@]} == 0 )); then
        pgp_info "Upstream PGP signing keys: OK"
        return 0
    fi

    printf '\n' >&2
    printf 'The selected upstream PKGBUILD explicitly trusts these full fingerprints:\n' >&2
    printf '  %s\n' "${needs_attention[@]}" >&2
    printf '\n' >&2
    printf 'Forge will retrieve only these pinned fingerprints and will keep makepkg\n' >&2
    printf 'signature verification enabled.\n' >&2

    read -r -p "Import/refresh the missing upstream signing key(s)? [Y/n]: " answer

    case "${answer:-y}" in
        n|N|no|NO|No)
            pgp_error "Required signing key import was declined."
            pgp_error "Signature verification has NOT been bypassed."
            return 1
            ;;
    esac

    for fingerprint in "${needs_attention[@]}"; do
        if ! receive_pgp_key "$fingerprint"; then
            pgp_error "Could not retrieve required upstream signing key: $fingerprint"
            pgp_error "Signature verification has NOT been bypassed."
            return 1
        fi

        state="$(pgp_key_state "$fingerprint")"
        if [[ "$state" != "present" ]]; then
            pgp_error "Signing key $fingerprint is still $state after refresh."
            pgp_error "Refusing to continue with an unusable signing key."
            return 1
        fi

        pgp_info "Signing key ready: $fingerprint"
    done

    pgp_info "Upstream PGP signing keys are ready."
}
