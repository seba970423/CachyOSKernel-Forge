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
    for cmd in git makepkg make find cp mktemp yes awk mv sort basename tail grep gpg; do
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

    printf '==> Preparing %s sources (no compilation)...\n' "$variant" >&2
    printf '==> Kconfig prompts during upstream prepare will receive their default answer.\n' >&2
    printf '==> Detailed prepare log: %s\n' "$log_file" >&2

    if ! (
        cd "$package_dir"
        makepkg -o < <(yes '')
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

main() {
    require_commands

    printf '==> Seba kernel builder dry-run\n'
    printf '==> This run will NOT compile or install a kernel.\n\n'

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
    local tree
    local baseline

    workdir="$(mktemp -d --tmpdir seba-kernel-dryrun.XXXXXX)"
    checkout="$workdir/upstream"

    printf '==> Work directory: %s\n' "$workdir"

    fetch_upstream "$checkout"

    printf '\n'
    variant="$(select_kernel_variant "$checkout")"
    printf '==> Selected kernel variant: %s\n' "$variant"

    validate_kernel_variant "$checkout" "$variant"
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
    printf '==> DRY-RUN PASSED.\n'
    printf '==> Kernel variant: %s\n' "$variant"
    printf '==> No kernel was compiled or installed.\n'
    printf '==> Prepared work tree kept for inspection: %s\n' "$workdir"
}

main "$@"
