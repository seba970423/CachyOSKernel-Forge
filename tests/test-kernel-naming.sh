#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-naming-test.XXXXXX)"
VARIANT="linux-cachyos-rt-bore"
PKGDIR="$TEST_TMPDIR/$VARIANT"

trap 'rm -rf -- "$TEST_TMPDIR"' EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/naming.sh"

mkdir -p "$PKGDIR"
printf '_pkgsuffix="cachyos-rt-bore"\npkgbase="linux-$_pkgsuffix"\n' >"$PKGDIR/PKGBUILD"

default_name="$(prompt_kernel_name "$VARIANT" </dev/null)"
[[ "$default_name" == "cachyos-rt-bore" ]] || {
    printf 'ERROR: Empty naming response did not preserve the upstream name.\n' >&2
    exit 1
}

custom_name="$(printf 'y\nlinux-seba-rt-bore\n' | prompt_kernel_name "$VARIANT")"
[[ "$custom_name" == "seba-rt-bore" ]] || {
    printf 'ERROR: Valid custom kernel name was not normalized correctly.\n' >&2
    exit 1
}

apply_custom_kernel_name "$TEST_TMPDIR" "$VARIANT" "$custom_name" >/dev/null
grep -qx '_pkgsuffix="seba-rt-bore"' "$PKGDIR/PKGBUILD" || {
    printf 'ERROR: Custom package suffix was not written to PKGBUILD.\n' >&2
    exit 1
}

printf 'Kernel naming tests passed.\n'
