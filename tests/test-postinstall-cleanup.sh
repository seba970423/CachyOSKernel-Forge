#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Adjusted to match the repository layout after applying the patch.
source "$SCRIPT_DIR/../lib/cleanup.sh"

new_fixture() {
    local root variant='linux-cachyos-rt-bore'
    root="$(mktemp -d --tmpdir=/var/tmp cachyos-kernel-build.XXXXXX)"
    printf 'kernelforge-workdir-v1\n' >"$root/.kernelforge-workdir"
    mkdir -p "$root/upstream/$variant/src/linux-7.2" "$root/upstream/$variant/pkg" "$root/tmp"
    printf 'CONFIG_PREEMPT_RT=y\n' >"$root/upstream/$variant/src/linux-7.2/.config"
    printf '# baseline\n' >"$root/upstream/$variant/src/linux-7.2/.config.test-baseline"
    printf '# PKGBUILD\n' >"$root/upstream/$variant/PKGBUILD"
    printf 'compile diagnostics\n' >"$root/upstream/$variant/.kernelforge-build.log"
    printf 'package bytes\n' >"$root/upstream/$variant/linux-sample.pkg.tar.zst"
    printf '%s\n' "$root/upstream/$variant/linux-sample.pkg.tar.zst" >"$root/upstream/$variant/.kernelforge-built-packages"
    printf 'build data\n' >"$root/upstream/$variant/src/linux-7.2/kernel.o"
    printf 'package staging\n' >"$root/upstream/$variant/pkg/temp"
    printf 'scratch\n' >"$root/tmp/scratch"
    printf '%s\n' "$root"
}

fail() { printf 'TEST FAILURE: %s\n' "$*" >&2; exit 1; }
assert_exists() { [[ -e "$1" ]] || fail "expected: $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected: $1"; }
variant='linux-cachyos-rt-bore'

# Successfully installed run: cleanup generated data only, keep all artifacts.
root="$(new_fixture)"
trap '[[ -n "${root:-}" ]] && rm -rf --one-file-system -- "$root"' EXIT
config="$root/upstream/$variant/src/linux-7.2"
kernelforge_cleanup_workdir "$root" "$variant" "$config"
[[ "$KERNELFORGE_CLEANUP_PERFORMED" == 1 ]] || fail 'success state not set'
assert_absent "$root/upstream/$variant/src"
assert_absent "$root/upstream/$variant/pkg"
assert_absent "$root/tmp"
assert_exists "$root/upstream/$variant/linux-sample.pkg.tar.zst"
assert_exists "$root/upstream/$variant/.kernelforge-built-packages"
assert_exists "$root/upstream/$variant/.kernelforge-build.log"
assert_exists "$root/upstream/$variant/PKGBUILD"
assert_exists "$root/artifacts/kernel-configs/$variant.config"
assert_exists "$root/artifacts/kernel-configs/$variant.config.test-baseline"
grep -q '^CONFIG_PREEMPT_RT=y$' "$root/artifacts/kernel-configs/$variant.config" || fail 'final config was changed'
rm -rf --one-file-system -- "$root"
root=''

# Desktop Forge's historical .seba-built-packages manifest is supported too.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
mv "$root/upstream/$variant/.kernelforge-built-packages" "$root/upstream/$variant/.seba-built-packages"
kernelforge_cleanup_workdir "$root" "$variant" "$config"
assert_absent "$root/upstream/$variant/src"
assert_exists "$root/upstream/$variant/.seba-built-packages"
assert_exists "$root/upstream/$variant/linux-sample.pkg.tar.zst"
rm -rf --one-file-system -- "$root"
root=''

# Noninteractive post-install invocation never deletes without consent.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
kernelforge_offer_postinstall_cleanup "$root" "$variant" "$config" </dev/null
assert_exists "$config/kernel.o"
rm -rf --one-file-system -- "$root"
root=''

# Missing marker must refuse deletion.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
rm "$root/.kernelforge-workdir"
if kernelforge_cleanup_workdir "$root" "$variant" "$config"; then fail 'unmarked directory accepted'; fi
assert_exists "$root/upstream/$variant/src/linux-7.2/kernel.o"
rm -rf --one-file-system -- "$root"
root=''

# Symlinked src cannot be cleaned, even when it points to an unrelated tree.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
mkdir "$root/outside"
mv "$root/upstream/$variant/src" "$root/outside/real-src"
ln -s "$root/outside/real-src" "$root/upstream/$variant/src"
if kernelforge_cleanup_workdir "$root" "$variant" "$config"; then fail 'symlink target accepted'; fi
assert_exists "$root/outside/real-src/linux-7.2/kernel.o"
rm -rf --one-file-system -- "$root"
root=''

# Package outputs underneath src must never be deleted.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
printf 'package\n' >"$config/linux-sample.pkg.tar.zst"
printf '%s\n' "$config/linux-sample.pkg.tar.zst" >"$root/upstream/$variant/.kernelforge-built-packages"
if kernelforge_cleanup_workdir "$root" "$variant" "$config"; then fail 'package in deletion tree accepted'; fi
assert_exists "$config/linux-sample.pkg.tar.zst"
rm -rf --one-file-system -- "$root"
root=''

# A mounted subdirectory must block cleanup. Mock findmnt: no root privileges.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
mkdir -p "$root/mockbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$MOCK_MOUNT"\n' >"$root/mockbin/findmnt"
chmod +x "$root/mockbin/findmnt"
if MOCK_MOUNT="$root/upstream/$variant/src/linux-7.2/loop-mount" PATH="$root/mockbin:$PATH" \
    kernelforge_cleanup_workdir "$root" "$variant" "$config"; then
    fail 'mounted source accepted'
fi
assert_exists "$config/kernel.o"
rm -rf --one-file-system -- "$root"
root=''

# A symlink in the config archive destination must not be followed.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
mkdir -p "$root/artifacts/kernel-configs"
printf 'do not overwrite\n' >"$root/untouched"
ln -s "$root/untouched" "$root/artifacts/kernel-configs/$variant.config"
if kernelforge_cleanup_workdir "$root" "$variant" "$config"; then fail 'symlinked archive file accepted'; fi
assert_exists "$config/kernel.o"
grep -q 'do not overwrite' "$root/untouched" || fail 'symlink was followed'
rm -rf --one-file-system -- "$root"
root=''

# Path traversal must not be accepted as a kernel variant.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
if kernelforge_cleanup_workdir "$root" '../other' "$config"; then fail 'traversal accepted'; fi
assert_exists "$config/kernel.o"
rm -rf --one-file-system -- "$root"
root=''

# Never clean if package manifest is missing.
root="$(new_fixture)"
config="$root/upstream/$variant/src/linux-7.2"
rm "$root/upstream/$variant/.kernelforge-built-packages"
if kernelforge_cleanup_workdir "$root" "$variant" "$config"; then fail 'missing manifest accepted'; fi
assert_exists "$config/kernel.o"
rm -rf --one-file-system -- "$root"
root=''

printf 'All post-install cleanup tests passed.\n'
