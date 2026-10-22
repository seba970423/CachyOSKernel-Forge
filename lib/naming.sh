#!/usr/bin/env bash

prompt_kernel_name() {
    local variant="$1"
    local default_name="${variant#linux-}"
    local answer
    local custom_name

    printf '\n' >&2
    printf '==> Selected kernel/package name: %s\n' "$variant" >&2
    printf '==> Press Enter to keep the upstream name unchanged.\n' >&2

    read -r -p "Rename selected kernel? [y/N]: " answer

    case "${answer:-n}" in
        y|Y|yes|YES|Yes)
            while true; do
                read -r -p "Custom kernel name (without 'linux-'): " custom_name
                custom_name="${custom_name#linux-}"

                if [[ "$custom_name" =~ ^[a-z0-9][a-z0-9._+-]{0,47}$ ]]; then
                    printf '%s\n' "$custom_name"
                    return 0
                fi

                printf 'Invalid kernel name. Use 1-48 lowercase letters, digits, ., _, + or -; start with a letter or digit.\n' >&2
            done
            ;;
        *)
            printf '%s\n' "$default_name"
            return 0
            ;;
    esac
}

apply_custom_kernel_name() {
    local checkout="$1"
    local variant="$2"
    local custom_name="$3"
    local default_name="${variant#linux-}"
    local pkgbuild="$checkout/$variant/PKGBUILD"
    local tmp="${pkgbuild}.name-tmp"

    if [[ "$custom_name" == "$default_name" ]]; then
        printf '==> Keeping upstream kernel/package name: %s\n' "$variant"
        return 0
    fi

    [[ -f "$pkgbuild" ]] || {
        printf 'ERROR: Cannot rename kernel: PKGBUILD is missing for %s.\n' "$variant" >&2
        return 1
    }

    if ! awk -v custom_name="$custom_name" '
        /^pkgbase="linux-\$_pkgsuffix"$/ && !inserted {
            print "# Custom kernel name selected by KernelForge"
            print "_pkgsuffix=\"" custom_name "\""
            inserted=1
        }
        { print }
        END { if (!inserted) exit 42 }
    ' "$pkgbuild" >"$tmp"; then
        rm -f "$tmp"
        printf 'ERROR: Could not locate expected pkgbase assignment in %s PKGBUILD.\n' "$variant" >&2
        return 1
    fi

    mv "$tmp" "$pkgbuild"

    grep -qx "_pkgsuffix=\"$custom_name\"" "$pkgbuild" || {
        printf 'ERROR: Failed to apply custom kernel name to %s PKGBUILD.\n' "$variant" >&2
        return 1
    }

    printf '==> Custom kernel package base: linux-%s\n' "$custom_name"
}
