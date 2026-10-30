#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

source "$REPO_ROOT/lib/upstream.sh"
source "$REPO_ROOT/lib/pgp.sh"
source "$REPO_ROOT/lib/build.sh"
source "$REPO_ROOT/lib/bore-compat.sh"
source "$REPO_ROOT/lib/naming.sh"
source "$REPO_ROOT/lib/profile.sh"
source "$REPO_ROOT/lib/hardware.sh"
source "$REPO_ROOT/lib/policy.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
source "$REPO_ROOT/lib/debug-compression.sh"
source "$REPO_ROOT/lib/cleanup.sh"

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
    local tree="$3"
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

    kernelforge_preflight_bore_scheduler "$tree" "$package_dir/.seba-scheduler-preflight.log" || return 1

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
        printf '%s\n' '--- First compiler/linker errors ---' >&2
        grep -nE -m 12 '(fatal )?error:|undefined reference|No rule to make target|Error [0-9]+' "$log_file" >&2 || true
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

    # Post-build snapshot for same-config comparisons; not peak usage.
    if command -v du >/dev/null 2>&1; then
        local usage_report="$package_dir/.kernelforge-space-report.txt" path
        : >"$usage_report"
        for path in "$package_dir/src" "$package_dir/pkg" "$TMPDIR"; do
            [[ ! -d "$path" ]] || du -sh -- "$path" >>"$usage_report" 2>/dev/null || true
        done
        printf '==> Post-build disk usage snapshot (not peak):\n'
        cat "$usage_report"
        printf '==> Saved disk usage report: %s\n' "$usage_report"
    fi
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
    require_build_commands

    printf '==> Seba kernel builder\n'
    printf '==> Configuration is prepared and validated before any compilation starts.\n\n'

    load_profile "$REPO_ROOT"
    validate_profile

    detect_hardware
    print_hardware_summary
    printf '\n'

    resolve_policy
    printf '\n'

    local workdir
    local checkout
    local variant
    local custom_name
    local tree

    workdir="$(mktemp -d --tmpdir=/var/tmp cachyos-kernel-build.XXXXXX)"
    printf 'kernelforge-workdir-v1\n' >"$workdir/.kernelforge-workdir"
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

    configure_and_validate_kernel "$tree" "$variant" || return 1

    printf '\n'
    printf '==> CONFIGURATION VALIDATION PASSED.\n'
    printf '==> Kernel variant: %s\n' "$variant"
    printf '==> Final kernel/package name: linux-%s\n' "$custom_name"
    printf '==> Prepared work tree: %s\n' "$workdir"

    if ask_compile; then
        compile_selected_kernel "$checkout" "$variant" "$tree"

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
            kernelforge_offer_postinstall_cleanup "$workdir" "$variant" "$tree"
        else
            printf '==> Installation skipped.\n'
            printf '==> Packages remain available in the work tree.\n'
        fi

        if [[ "$KERNELFORGE_CLEANUP_PERFORMED" == 1 ]]; then
            printf '==> Retained kernel packages, logs, patches and configurations: %s\n' "$workdir"
        else
            printf '==> Work tree kept for inspection: %s\n' "$workdir"
        fi
    else
        printf '\n'
        printf '==> Compilation skipped.\n'
        printf '==> Nothing was installed.\n'
        printf '==> Work tree kept for inspection: %s\n' "$workdir"
    fi
}

main "$@"

