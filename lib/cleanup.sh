#!/usr/bin/env bash
# KernelForge post-install cleanup. Sourced by builder.sh, never run directly.
# Only generated src/, pkg/ and TMPDIR contents are deleted. The checkout,
# PKGBUILD, patches, logs and packages are retained.

KERNELFORGE_CLEANUP_PERFORMED=0

_kf_cleanup_error() {
    printf 'WARNING: Cleanup refused: %s\n' "$*" >&2
    return 1
}

_kf_cleanup_validate() {
    local workdir="$1" variant="$2" tree="$3"
    local package_dir="$workdir/upstream/$variant"
    local expected_root='/var/tmp'
    local basename real_work real_package real_tree
    local manifest
    # ThinkPad and desktop Forge historically used different manifest names.
    if [[ -e "$package_dir/.kernelforge-built-packages" && -e "$package_dir/.seba-built-packages" ]]; then
        _kf_cleanup_error 'ambiguous package manifests'
        return 1
    elif [[ -e "$package_dir/.kernelforge-built-packages" ]]; then
        manifest="$package_dir/.kernelforge-built-packages"
    else
        manifest="$package_dir/.seba-built-packages"
    fi
    local package real_package_file path mountpoints mount target
    local -a candidates=("$package_dir/src" "$package_dir/pkg" "$workdir/tmp")

    # Use a narrow, builder-generated path and an ownership marker. No caller-
    # supplied path is ever accepted for deletion outside this workspace shape.
    [[ "$variant" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ && "$variant" != '.' && "$variant" != '..' ]] ||
        { _kf_cleanup_error 'invalid variant name'; return 1; }
    [[ "$workdir" == /var/tmp/cachyos-kernel-build.* && -d "$workdir" && ! -L "$workdir" ]] ||
        { _kf_cleanup_error 'not a real KernelForge workspace directory'; return 1; }
    basename="${workdir##*/}"
    [[ "$basename" =~ ^cachyos-kernel-build\.[[:alnum:]]{6,}$ ]] ||
        { _kf_cleanup_error 'workspace name does not match the mktemp pattern'; return 1; }
    real_work="$(realpath -e -- "$workdir")" || return 1
    [[ "$real_work" == "$expected_root/$basename" ]] ||
        { _kf_cleanup_error 'workspace resolves outside /var/tmp'; return 1; }
    [[ -f "$workdir/.kernelforge-workdir" && ! -L "$workdir/.kernelforge-workdir" ]] ||
        { _kf_cleanup_error 'workspace ownership marker is absent'; return 1; }
    [[ "$(<"$workdir/.kernelforge-workdir")" == 'kernelforge-workdir-v1' ]] ||
        { _kf_cleanup_error 'workspace marker is not recognized'; return 1; }
    [[ "$(stat -c %u -- "$workdir")" == "$EUID" ]] ||
        { _kf_cleanup_error 'workspace is not owned by the current user'; return 1; }
    [[ -d "$workdir/upstream" && ! -L "$workdir/upstream" && -d "$package_dir" && ! -L "$package_dir" ]] ||
        { _kf_cleanup_error 'upstream package directory is missing or symlinked'; return 1; }
    real_package="$(realpath -e -- "$package_dir")" || return 1
    [[ "$real_package" == "$real_work/upstream/$variant" ]] ||
        { _kf_cleanup_error 'package path escaped the workspace'; return 1; }
    [[ -d "$package_dir/src" && ! -L "$package_dir/src" && -f "$tree/.config" && ! -L "$tree/.config" ]] ||
        { _kf_cleanup_error 'prepared source tree or final .config is missing'; return 1; }
    real_tree="$(realpath -e -- "$tree")" || return 1
    [[ "$real_tree" == "$real_package/src/"* ]] ||
        { _kf_cleanup_error 'kernel configuration is outside the source tree'; return 1; }

    for path in "${candidates[@]}"; do
        [[ ! -L "$path" ]] || { _kf_cleanup_error "symlinked deletion target: $path"; return 1; }
        [[ ! -e "$path" || -d "$path" ]] ||
            { _kf_cleanup_error "deletion target is not a directory: $path"; return 1; }
    done

    [[ -f "$manifest" && ! -L "$manifest" && -s "$manifest" ]] ||
        { _kf_cleanup_error 'package manifest is missing or empty'; return 1; }
    local count=0
    while IFS= read -r package || [[ -n "$package" ]]; do
        [[ -n "$package" && -f "$package" && ! -L "$package" ]] ||
            { _kf_cleanup_error 'package manifest has a missing or invalid entry'; return 1; }
        real_package_file="$(realpath -e -- "$package")" || return 1
        for path in "${candidates[@]}"; do
            if [[ "$real_package_file" == "$path"/* ]]; then
                _kf_cleanup_error "built package would be deleted: $package"
                return 1
            fi
        done
        ((count+=1))
    done <"$manifest"
    (( count > 0 )) || { _kf_cleanup_error 'no built packages verified'; return 1; }

    command -v findmnt >/dev/null 2>&1 ||
        { _kf_cleanup_error 'findmnt is required for mount safety'; return 1; }
    mountpoints="$(findmnt --kernel -rn -o TARGET)" ||
        { _kf_cleanup_error 'could not enumerate mounts'; return 1; }
    while IFS= read -r mount; do
        for target in "${candidates[@]}"; do
            if [[ "$mount" == "$target" || "$mount" == "$target/"* ]]; then
                _kf_cleanup_error "mounted filesystem inside deletion target: $mount"
                return 1
            fi
        done
    done <<<"$mountpoints"
}

kernelforge_cleanup_workdir() {
    local workdir="$1" variant="$2" tree="$3"
    local package_dir="$workdir/upstream/$variant"
    local saved_configs="$workdir/artifacts/kernel-configs"
    local config_file destination filename path
    local -a candidates=("$package_dir/src" "$package_dir/pkg" "$workdir/tmp")

    _kf_cleanup_validate "$workdir" "$variant" "$tree" || return 1
    [[ ! -L "$workdir/artifacts" && ! -L "$saved_configs" ]] ||
        { _kf_cleanup_error 'artifact destination is symlinked'; return 1; }
    mkdir -p -m 700 -- "$saved_configs" || return 1
    [[ "$(realpath -e -- "$saved_configs")" == "$workdir/artifacts/kernel-configs" ]] ||
        { _kf_cleanup_error 'artifact destination escaped the workspace'; return 1; }

    # Preserve the final compiled Kconfig and any nearby baseline/backup configs.
    # Keep the package directory itself: build logs, PKGBUILD, patches,
    # source archives, package manifest and .pkg.tar.* outputs remain there.
    local saved=0
    for config_file in "$tree"/.config "$tree"/.config.*; do
        [[ -e "$config_file" ]] || continue
        [[ -f "$config_file" && ! -L "$config_file" ]] ||
            { _kf_cleanup_error "invalid configuration file: $config_file"; return 1; }
        filename="${config_file##*/}"
        destination="$saved_configs/${variant}${filename}"
        [[ ! -e "$destination" && ! -L "$destination" ]] ||
            { _kf_cleanup_error "configuration destination already exists: $destination"; return 1; }
        cp -p -- "$config_file" "$destination" || return 1
        cmp -s -- "$config_file" "$destination" ||
            { _kf_cleanup_error "configuration copy verification failed: $filename"; return 1; }
        ((saved+=1))
    done
    (( saved > 0 )) || { _kf_cleanup_error 'no configuration saved'; return 1; }

    # Revalidate immediately before removing directories; --one-file-system
    # protects against descending through mountpoints added between checks.
    _kf_cleanup_validate "$workdir" "$variant" "$tree" || return 1
    for path in "${candidates[@]}"; do
        if [[ -d "$path" ]]; then
            rm -rf --one-file-system -- "$path" || return 1
        fi
    done
    KERNELFORGE_CLEANUP_PERFORMED=1
    export TMPDIR=/var/tmp
    printf '==> Cleanup complete; retained package files, logs, patches and configs under: %s\n' "$workdir"
}

kernelforge_offer_postinstall_cleanup() {
    local workdir="$1" variant="$2" tree="$3"
    local answer size_kib path
    local package_dir="$workdir/upstream/$variant"
    local -a candidates=("$package_dir/src" "$package_dir/pkg" "$workdir/tmp")
    printf '\n==> Optional post-install build cleanup\n'
    if ! _kf_cleanup_validate "$workdir" "$variant" "$tree"; then
        printf '==> Build files kept; cleanup safety checks did not pass.\n'
        return 0
    fi
    size_kib=0
    for path in "${candidates[@]}"; do
        if [[ -d "$path" ]]; then
            size_kib=$((size_kib + $(du -sk -- "$path" | cut -f1)))
        fi
    done
    printf '==> Reclaimable build data: approximately %s MiB\n' "$((size_kib / 1024))"
    printf '==> Preserved: kernel packages, build logs, PKGBUILD, patches, source archives, .config.\n'
    if [[ ! -t 0 ]]; then
        printf '==> Noninteractive run: cleanup skipped (safe default).\n'
        return 0
    fi
    if ! read -r -p 'Remove generated src/, pkg/ and compiler temporary files? [y/N]: ' answer; then
        printf '\n==> Cleanup skipped; build files retained.\n'
        return 0
    fi
    case "$answer" in
        y|Y|yes|YES|Yes)
            if ! kernelforge_cleanup_workdir "$workdir" "$variant" "$tree"; then
                printf 'WARNING: Cleanup failed or was refused. Installation remains successful.\n' >&2
            fi
            ;;
        *) printf '==> Cleanup declined; build files retained.\n' ;;
    esac
    return 0
}
