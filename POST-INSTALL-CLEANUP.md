# Optional post-install cleanup

After a **successful** kernel build and `pacman -U` installation, KernelForge
now offers an opt-in cleanup prompt:

```text
==> Optional post-install build cleanup
==> Reclaimable build data: approximately ... MiB
==> Preserved: kernel packages, build logs, PKGBUILD, patches, source archives, .config.
Remove generated src/, pkg/ and compiler temporary files? [y/N]:
```

Press Enter or `n` to preserve the entire work tree. The prompt never appears
if compilation is skipped, the build fails, or installation is skipped/failed.
When stdin is noninteractive, cleanup is **skipped** rather than assumed.

If confirmed, KernelForge:

1. Checks that the work directory is the one it just created under
   `/var/tmp/cachyos-kernel-build.XXXXXX` (including an ownership marker).
2. Checks the variant and source-tree paths, ownership, symlinks, installed
   package manifest, and package locations.
3. Refuses cleanup if a mount is present inside any deletion target.
4. Saves and verifies the final `src/<kernel>/.config` and adjacent `.config.*`
   files under `<workdir>/artifacts/kernel-configs/`.
5. Removes **only** `<workdir>/upstream/<variant>/src/`,
   `<workdir>/upstream/<variant>/pkg/`, and `<workdir>/tmp/`, using
   `rm --one-file-system`.

The upstream checkout, PKGBUILD, patches, original source archives, all
`makepkg`-produced `.pkg.tar.*` outputs, `.seba-*` / `.kernelforge-*` logs,
package manifest, and saved `.config` files remain in that workspace.
The original validated source *tree* is deleted if cleanup is confirmed, so
subsequent incremental builds need source preparation again. This is an
intentional trade-off, not an automatic clean of your source checkout.

A cleanup failure does **not** undo or relabel the successful kernel
installation; it leaves whatever build data has not yet been removed in place.
KernelForge never changes a system kernel or reboots as part of cleanup.

## Test without building a kernel

```bash
bash tests/test-postinstall-cleanup.sh
```

The tests create fake workspaces under `/var/tmp`, using fake package files.
They do not invoke `makepkg`, `pacman`, or `rm` on a real KernelForge build.
