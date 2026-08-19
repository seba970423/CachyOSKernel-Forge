# CachyOS Hardware-Aware Kernel Builder

A hardware-aware custom kernel builder for Arch Linux and Arch-based distributions, using the CachyOS kernel packaging repository as upstream.

The project is designed around one rule:

> Preserve upstream behavior by default. Customize only when the user explicitly asks for it.

The builder detects the current machine, resolves a kernel policy, prepares a selected CachyOS kernel variant, applies the requested Kconfig changes, validates the resulting configuration, builds the packages, and optionally installs them.

It is meant to reduce the amount of manual PKGBUILD/Kconfig work required to create a focused custom kernel without turning the process into a long sequence of commands the user has to copy and paste.

## Current status

The desktop workflow has been tested end-to-end on CachyOS, including:

- upstream cloning
- dynamic kernel-variant discovery
- hardware detection
- profile validation
- optional hardware pruning
- Kconfig modification
- Kconfig dependency resolution
- post-resolution validation
- custom kernel/package naming
- full package compilation
- package installation
- initramfs generation
- Limine boot-entry update
- successful boot of the resulting kernel

A tested example was built from `linux-cachyos-rt-bore`, renamed to `linux-seba-rt-bore`, installed, and successfully booted with PREEMPT_RT active.

Vanilla Arch and other Arch-based distributions are intended targets as well, but should be considered less tested than CachyOS until more clean-system testing is completed.

## Features

### Dynamic CachyOS kernel selection

The builder clones the current CachyOS kernel packaging repository and discovers compatible kernel variants dynamically instead of relying on a hard-coded list.

Examples include:

- `linux-cachyos`
- `linux-cachyos-bore`
- `linux-cachyos-bmq`
- `linux-cachyos-eevdf`
- `linux-cachyos-hardened`
- `linux-cachyos-lts`
- `linux-cachyos-rc`
- `linux-cachyos-rt-bore`
- `linux-cachyos-server`

If upstream adds or removes compatible variants, the menu can adapt automatically.

### Hardware-aware policy

The project detects relevant hardware before resolving the final kernel policy.

Current policy areas include:

- Intel KVM
- Intel TDX
- AMD SEV
- Intel i915
- AMDGPU
- Nouveau
- Intel Wi-Fi
- Thunderbolt / USB4
- NVMe-over-Fabrics
- NVMe target/server support

Hardware pruning is opt-in. By default, hardware support is preserved for portability.

### Portable profile

The desktop profile applies the project's intended baseline kernel configuration while keeping the system broadly usable.

Important settings are validated after Kconfig dependency resolution, so the builder checks the configuration that will actually be compiled rather than assuming that requested values survived `olddefconfig`.

### Safe custom naming

After choosing an upstream kernel variant, the user can keep its original package/kernel name or explicitly rename it.

Example:

```text
Selected kernel/package name: linux-cachyos-rt-bore
Press Enter to keep the upstream name unchanged.
Rename selected kernel? [y/N]:
```

If the user does nothing, upstream naming is preserved.

If the user chooses to rename it, for example to:

```text
seba-rt-bore
```

the resulting package base becomes:

```text
linux-seba-rt-bore
```

A leading `linux-` entered by the user is handled automatically.

### Dependency handling

Kernel PKGBUILD dependencies remain defined by the selected upstream CachyOS PKGBUILD.

During source preparation, `makepkg` is allowed to synchronize missing dependencies through pacman. This avoids maintaining a duplicated dependency list inside the project.

The user still controls the pacman transaction; dependency installation is not forced with `--noconfirm`.

### Disk-backed build workspace

Kernel builds can consume a large amount of temporary storage.

The builder therefore uses a disk-backed workspace under:

```text
/var/tmp/cachyos-kernel-build.XXXXXX
```

and assigns a dedicated `TMPDIR` inside that workspace.

This avoids placing a full kernel build inside a potentially size-limited `/tmp` tmpfs.

### Build validation before compilation

The expensive build does not begin until the resolved kernel configuration passes validation.

Typical output:

```text
==> Kernel policy validation passed.
==> CONFIGURATION VALIDATION PASSED.
```

Only then is the user asked:

```text
Compile selected kernel now? [y/N]:
```

### Build progress timer

The compiler output is written to a build log while the terminal receives a lightweight heartbeat every 30 seconds:

```text
==> Build still running... 12m 30s elapsed
```

On failure, the builder prints the tail of the build log for quick debugging.

### Optional installation

A successful build does not imply installation.

The user is explicitly asked:

```text
Install the kernel packages built by this run? [y/N]:
```

The default is No.

If accepted, the builder installs exactly the package paths produced by the current build with `pacman -U`. It does not install arbitrary package files found in the directory.

The builder does not reboot automatically.

## Requirements

The project is intended for Arch Linux and Arch-based distributions.

The builder itself expects common Arch build tooling such as:

- Bash
- Git
- `makepkg`
- GNU Make
- pacman for dependency/package installation

Kernel-specific dependencies are resolved from the selected upstream PKGBUILD.

A normal Arch package-building environment is expected. On a minimal vanilla Arch installation, additional build tools may be required before the builder itself can run.

## Usage

Clone the repository, enter it and then launch build.sh:

```bash
git clone https://github.com/seba970423/CachyOSKernel-Forge
cd cd CachyOSKernel-Forge/
./builder.sh
```

The builder will then:

1. load and validate the selected project profile
2. detect local hardware
3. resolve optional kernel policy
4. create a disk-backed build workspace
5. clone the latest CachyOS kernel packaging repository
6. discover available compatible kernel variants
7. let the user select a variant
8. optionally rename the resulting kernel/package
9. synchronize missing PKGBUILD dependencies when necessary
10. prepare the upstream kernel source
11. normalize the upstream Kconfig baseline
12. apply the project profile
13. apply the resolved hardware/feature policy
14. run `olddefconfig`
15. validate the final resolved Kconfig
16. optionally compile the kernel
17. optionally install the exact packages produced by the build

## Dry run

`builder-dry-run.sh` is retained as a development and validation tool.

It is useful when changing profiles, hardware detection, policy logic, or Kconfig handling without waiting for a full kernel compilation.

A dry run should be used before expensive real builds when making substantial changes to the configuration architecture.

## Project layout

```text
.
├── builder.sh
├── builder-dry-run.sh
├── lib/
│   ├── hardware.sh
│   ├── kconfig.sh
│   ├── policy.sh
│   ├── profile.sh
│   ├── upstream.sh
│   └── validate.sh
└── profiles/
    └── ...
```

### `builder.sh`

Main end-to-end orchestrator.

### `builder-dry-run.sh`

Safe configuration/preparation test path without a real kernel compile/install.

### `lib/hardware.sh`

Hardware detection and hardware summary.

### `lib/policy.sh`

Interactive policy resolution based on detected hardware and user choices.

### `lib/kconfig.sh`

Kconfig modification helpers and profile/policy application.

### `lib/validate.sh`

Post-`olddefconfig` validation of important kernel configuration invariants.

### `lib/upstream.sh`

CachyOS upstream cloning, variant discovery, compatibility checks, and prepare-time compatibility handling.

### `lib/profile.sh`

Profile loading and profile-value validation.

### `profiles/`

Human-maintained project profiles. The desktop profile is the current known-good baseline. A more aggressively stripped ThinkPad-oriented profile can be developed separately without destabilizing the desktop profile.

## Design principles

This project deliberately favors predictable behavior over clever surprises.

- Do not silently rename kernels.
- Do not silently prune hardware support.
- Do not compile before validating the resolved configuration.
- Do not install a built kernel without asking.
- Do not reboot the machine automatically.
- Do not maintain redundant dependency lists when the upstream PKGBUILD already defines them.
- Do not make users copy and paste a long list of commands just to achieve the normal workflow.
- Preserve upstream behavior when the user has not explicitly chosen otherwise.
- Fail clearly when an upstream packaging change makes the selected variant incompatible.

## Logs and debugging

Preparation log:

```text
<selected-package>/.seba-prepare.log
```

Build log:

```text
<selected-package>/.seba-build.log
```

On build failure, the builder prints the last part of the build log automatically.

The complete work tree is intentionally retained after a build so packages and logs can be inspected.

## Safety notes

A custom kernel can fail to boot even when compilation succeeds.

Keep at least one known-good kernel installed until the new kernel has been boot-tested successfully.

Do not aggressively strip hardware support unless you understand the portability trade-off. A configuration optimized only for currently detected hardware may fail after hardware changes, docking, adapter changes, Wi-Fi replacement, or use on another machine.

## Future work

Potential follow-up work includes:

- a dedicated ThinkPad profile
- broader clean-install testing on vanilla Arch
- testing on additional Arch-based distributions
- more hardware-policy coverage
- optional aggressive current-machine pruning while retaining the portable profile as the default

The desktop profile should remain conservative and known-good while more specialized profiles are developed independently.
