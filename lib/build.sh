#!/usr/bin/env bash

# Shared source-preparation layer used by both the dry-run and full builder.
# Keeping this path in one file prevents a dry-run from validating behavior
# that differs from the eventual compilation path.

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: Required command not found: %s\n' "$cmd" >&2
        return 1
    }
}

require_build_commands() {
    local cmd
    for cmd in git makepkg make find cp mktemp yes awk mv sort basename tail grep gpg mkdir; do
        require_command "$cmd" || return 1
    done
}

find_kernel_tree() {
    local package_dir="$1"
    local -a matches=()
    local scripts_config

    while IFS= read -r scripts_config; do
        matches+=("$scripts_config")
    done < <(
        find "$package_dir/src" -maxdepth 4 -type f -path '*/scripts/config' -print
    )

    if (( ${#matches[@]} == 0 )); then
        printf 'ERROR: Could not locate a prepared kernel scripts/config under %s/src\n' \
            "$package_dir" >&2
        return 1
    fi

    if (( ${#matches[@]} > 1 )); then
        printf 'ERROR: Multiple prepared kernel trees were found; refusing to guess:\n' >&2
        printf '  %s\n' "${matches[@]}" >&2
        return 1
    fi

    dirname "$(dirname "${matches[0]}")"
}

prepare_upstream_source() {
    local checkout="$1"
    local variant="$2"
    local package_dir="$checkout/$variant"
    local log_file="$package_dir/.seba-prepare.log"

    # This function is used in command substitution. Keep stdout reserved
    # exclusively for the final kernel-tree path.
    ensure_upstream_pgp_keys "$package_dir" || return 1

    printf '==> Checking dependencies for %s...\n' "$variant" >&2
    printf '==> Missing PKGBUILD dependencies, if any, will be offered through pacman.\n' >&2
    printf '==> Preparing %s sources (no compilation)...\n' "$variant" >&2
    printf '==> Kconfig prompts during upstream prepare will receive their default answer.\n' >&2
    printf '==> Detailed prepare log: %s\n' "$log_file" >&2

    if ! (
        cd "$package_dir" || exit 1
        makepkg -s -o < <(yes '')
    ) >"$log_file" 2>&1; then
        printf 'ERROR: %s source preparation failed.\n' "$variant" >&2
        printf '%s\n' '--- Last 80 lines of prepare log ---' >&2
        tail -n 80 "$log_file" >&2 || true
        return 1
    fi

    printf '==> %s sources prepared successfully.\n' "$variant" >&2
    find_kernel_tree "$package_dir"
}

configure_and_validate_kernel() {
    local tree="$1" variant="$2"
    local baseline="$tree/.config.seba-normalized-baseline"

    kconfig_require_tree "$tree" || return 1

    printf '==> Normalizing upstream Kconfig baseline...\n'
    make -C "$tree" olddefconfig || return 1
    cp "$tree/.config" "$baseline" || return 1

    resolve_kernel_tuning_policy "$tree" "$variant" || return 1
    kernelforge_choose_dwarf_zstd "$tree" || return 1
    print_policy_summary
    printf '==> Optional DWARF Zstd compression selected: %s\n' "${KERNELFORGE_DWARF_ZSTD:-no}"
    printf '\n'

    printf '==> Applying portable desktop profile...\n'
    kconfig_apply_profile "$tree" || return 1

    printf '==> Applying resolved feature policy...\n'
    kconfig_apply_policy "$tree" || return 1
    kernelforge_apply_dwarf_zstd "$tree" || return 1

    printf '==> Resolving Kconfig dependencies...\n'
    make -C "$tree" olddefconfig || return 1

    validate_kernel_policy "$tree" "$baseline" || return 1
    kernelforge_validate_dwarf_zstd "$baseline" "$tree/.config" || return 1
}
