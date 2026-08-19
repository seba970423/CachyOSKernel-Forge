#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

source "$REPO_ROOT/lib/upstream.sh"
source "$REPO_ROOT/lib/pgp.sh"
source "$REPO_ROOT/lib/profile.sh"
source "$REPO_ROOT/lib/hardware.sh"
source "$REPO_ROOT/lib/policy.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: Required command not found: %s\n' "$cmd" >&2
        exit 1
    }
}

require_commands() {
    local cmd
    for cmd in git makepkg make find cp mktemp yes awk mv sort basename tail grep gpg mkdir; do
        require_command "$cmd"
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
    ensure_upstream_pgp_keys "$package_dir"

    printf '==> Checking dependencies for %s...\n' "$variant" >&2
    printf '==> Missing PKGBUILD dependencies, if any, will be offered through pacman.\n' >&2
    printf '==> Preparing %s sources (no compilation)...\n' "$variant" >&2
    printf '==> Kconfig prompts during upstream prepare will receive their default answer.\n' >&2
    printf '==> Detailed prepare log: %s\n' "$log_file" >&2

    if ! (
        cd "$package_dir"
        makepkg -s -o < <(yes '')
    ) >"$log_file" 2>&1; then
        printf 'ERROR: %s source preparation failed.\n' "$variant" >&2
        printf '%s\n' '--- Last 80 lines of prepare log ---' >&2
        tail -n 80 "$log_file" >&2 || true
        return 1
    fi

    printf '==> %s sources prepared successfully.\n' "$variant" >&2

    # The only stdout emitted by this function: the prepared tree path.
    find_kernel_tree "$package_dir"
}



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
            print "# Custom kernel name selected by builder"
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


ask_compile() {
    local answer

    printf '\n'
    read -r -p "Compile selected kernel now? [y/N]: " answer

    case "${answer:-n}" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

compile_selected_kernel() {
    local checkout="$1"
    local variant="$2"
    local package_dir="$checkout/$variant"
    local log_file="$package_dir/.seba-build.log"
    local package_list_file="$package_dir/.seba-built-packages"
    local build_pid
    local start_seconds=$SECONDS
    local elapsed
    local -a packages=()

    printf '==> Starting package build for %s...\n' "$variant"
    printf '==> Reusing the already-prepared and validated source tree.\n'
    printf '==> prepare() will NOT be run again.\n'
    printf '==> Detailed build log: %s\n' "$log_file"

    # --noextract (-e) is critical here: our final validated .config lives in
    # the existing src/ tree. Re-extracting or rerunning prepare() would
    # discard that validated state.
    (
        cd "$package_dir"
        makepkg --noextract
    ) >"$log_file" 2>&1 &
    build_pid=$!

    while kill -0 "$build_pid" 2>/dev/null; do
        sleep 30
        if kill -0 "$build_pid" 2>/dev/null; then
            elapsed=$((SECONDS - start_seconds))
            printf '==> Build still running... %dm %02ds elapsed\n' \
                "$((elapsed / 60))" "$((elapsed % 60))"
        fi
    done

    if ! wait "$build_pid"; then
        printf 'ERROR: Kernel package build failed.\n' >&2
        printf '%s\n' '--- Last 120 lines of build log ---' >&2
        tail -n 120 "$log_file" >&2 || true
        return 1
    fi

    elapsed=$((SECONDS - start_seconds))
    printf '==> Kernel package build completed in %dm %02ds.\n' \
        "$((elapsed / 60))" "$((elapsed % 60))"

    while IFS= read -r package; do
        [[ -n "$package" ]] && packages+=("$package")
    done < <(
        cd "$package_dir"
        makepkg --packagelist
    )

    (( ${#packages[@]} > 0 )) || {
        printf 'ERROR: Build succeeded but makepkg did not report package paths.\n' >&2
        return 1
    }

    : >"$package_list_file"
    local package
    for package in "${packages[@]}"; do
        [[ -f "$package" ]] || {
            printf 'ERROR: Expected built package is missing: %s\n' "$package" >&2
            return 1
        }
        printf '%s\n' "$package" >>"$package_list_file"
    done

    printf '==> Built package output:\n'
    printf '    %s\n' "${packages[@]}"
}

ask_install() {
    local answer

    printf '\n'
    read -r -p "Install the kernel packages built by this run? [y/N]: " answer

    case "${answer:-n}" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

install_built_kernel() {
    local checkout="$1"
    local variant="$2"
    local package_dir="$checkout/$variant"
    local package_list_file="$package_dir/.seba-built-packages"
    local -a packages=()
    local package

    require_command sudo
    require_command pacman

    [[ -s "$package_list_file" ]] || {
        printf 'ERROR: Built-package manifest is missing or empty: %s\n' \
            "$package_list_file" >&2
        return 1
    }

    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        [[ -f "$package" ]] || {
            printf 'ERROR: Refusing installation because package is missing: %s\n' \
                "$package" >&2
            return 1
        }
        packages+=("$package")
    done <"$package_list_file"

    (( ${#packages[@]} > 0 )) || {
        printf 'ERROR: No packages are available for installation.\n' >&2
        return 1
    }

    printf '==> Installing exactly the packages produced by this build:\n'
    printf '    %s\n' "${packages[@]}"

    sudo pacman -U -- "${packages[@]}"

    printf '==> Kernel packages installed successfully.\n'
    printf '==> No automatic reboot will be performed.\n'
}


main() {
    require_commands

    printf '==> Seba kernel builder\n'
    printf '==> Configuration is prepared and validated before any compilation starts.\n\n'

    load_profile "$REPO_ROOT"
    validate_profile

    detect_hardware
    print_hardware_summary
    printf '\n'

    resolve_policy
    printf '\n'
    print_policy_summary
    printf '\n'

    local workdir
    local checkout
    local variant
    local custom_name
    local tree
    local baseline

    workdir="$(mktemp -d --tmpdir=/var/tmp cachyos-kernel-build.XXXXXX)"
    checkout="$workdir/upstream"

    mkdir -p "$workdir/tmp"
    export TMPDIR="$workdir/tmp"

    printf '==> Work directory: %s\n' "$workdir"
    printf '==> Compiler temporary directory: %s\n' "$TMPDIR"

    fetch_upstream "$checkout"

    printf '\n'
    variant="$(select_kernel_variant "$checkout")"
    printf '==> Selected kernel variant: %s\n' "$variant"

    validate_kernel_variant "$checkout" "$variant"

    custom_name="$(prompt_kernel_name "$variant")"
    apply_custom_kernel_name "$checkout" "$variant" "$custom_name"

    install_upstream_prepare_compat "$checkout" "$variant"

    tree="$(prepare_upstream_source "$checkout" "$variant")"

    printf '==> Prepared kernel tree: %s\n' "$tree"

    kconfig_require_tree "$tree"

    printf '==> Normalizing upstream Kconfig baseline...\n'
    make -C "$tree" olddefconfig

    baseline="$tree/.config.seba-normalized-baseline"
    cp "$tree/.config" "$baseline"

    printf '==> Applying portable profile...\n'
    kconfig_apply_profile "$tree"

    printf '==> Applying resolved feature policy...\n'
    kconfig_apply_policy "$tree"

    printf '==> Resolving Kconfig dependencies...\n'
    make -C "$tree" olddefconfig

    validate_kernel_policy "$tree" "$baseline"

    printf '\n'
    printf '==> CONFIGURATION VALIDATION PASSED.\n'
    printf '==> Kernel variant: %s\n' "$variant"
    printf '==> Final kernel/package name: linux-%s\n' "$custom_name"
    printf '==> Prepared work tree: %s\n' "$workdir"

    if ask_compile; then
        compile_selected_kernel "$checkout" "$variant"

        printf '\n'
        printf '==> BUILD PASSED.\n'
        printf '==> Kernel variant: %s\n' "$variant"
        printf '==> Final kernel/package name: linux-%s\n' "$custom_name"

        if ask_install; then
            install_built_kernel "$checkout" "$variant"

            printf '\n'
            printf '==> INSTALLATION PASSED.\n'
            printf '==> Installed kernel/package name: linux-%s\n' "$custom_name"
            printf '==> Reboot manually when you are ready to boot the new kernel.\n'
        else
            printf '==> Installation skipped.\n'
            printf '==> Packages remain available in the work tree.\n'
        fi

        printf '==> Work tree kept for inspection: %s\n' "$workdir"
    else
        printf '\n'
        printf '==> Compilation skipped.\n'
        printf '==> Nothing was installed.\n'
        printf '==> Work tree kept for inspection: %s\n' "$workdir"
    fi
}

main "$@"
