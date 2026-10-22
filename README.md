# CachyOSKernel-Forge

A portable desktop kernel builder for Arch Linux and Arch-based distributions, using the CachyOS kernel packaging repository as upstream.

The project is designed around one rule:

> Preserve upstream behavior by default. Customize only when the user explicitly asks for it.

The builder detects the current machine, resolves a kernel policy, prepares a selected CachyOS kernel variant, applies the requested Kconfig changes, validates the resulting configuration, builds the packages, and optionally installs them.

It is meant to reduce the amount of manual PKGBUILD/Kconfig work required to create a focused custom kernel without turning the process into a long sequence of commands the user has to copy and paste.

## Current status

The earlier desktop workflow was tested end-to-end on CachyOS, including:

- upstream cloning
- dynamic kernel-variant discovery
- hardware detection
- profile validation
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

### Portable hardware policy

Hardware inventory is diagnostic. A missing device on the build host never
removes its kernel support. `pciutils`/`lspci` is optional; missing or inaccessible
PCI inventory is reported as unknown, and GPU detection uses PCI vendor IDs.

The desktop profile preserves upstream hardware and platform support across
manufacturers, including ASUS, Dell, HP, Lenovo/ThinkPad and others. Unlike the
separate ThinkPad edition, it has no manufacturer exclusion list. The former
current-machine hardware-pruning prompt has been removed.

General-capability prompts preserve the selected kernel's normalized upstream
state by default (`[Y/n]`):

- standard KVM virtualization;
- Intel TDX on Intel hosts, or AMD SEV on AMD hosts;
- NVMe-over-Fabrics;
- NVMe Target/server functionality.

**Keep means preserve, not force-enable.** An upstream disabled or absent
capability stays that way. The unprompted CPU vendor's confidential-VM support
is preserved too. Missing VMX/SVM flags do not authorize removing KVM.
An explicit No to KVM removes KVM and both vendor backends, including their
TDX/SEV dependencies; the dependent capability prompt is then skipped.

Ordinary local NVMe storage is independent of Fabrics/Target policy and remains
protected, as do SATA/AHCI, graphics, networking, USB/HID, audio, power management
and manufacturer platform drivers.

### Portable profile

The desktop profile applies the project's intended baseline kernel configuration while keeping the system broadly usable.

Important settings are validated after Kconfig dependency resolution, so the builder checks the configuration that will actually be compiled rather than assuming that requested values survived `olddefconfig`.

Hardware protection compares complete configuration lines for the families
listed in `profiles/desktop.conf`, including module/built-in choices, strings
and numeric settings. Newly added drivers under those prefixes are covered.
A selected variant may deliberately disable a facility; for example,
Hardened's disabled hibernation is preserved rather than overridden. This is
validation of the declared hardware families, not every Kconfig symbol.

The profile still deliberately applies native CPU optimization and tickless
idle (`NO_HZ_IDLE`). Build on the intended CPU: broad driver support does not
make a native-optimized kernel binary portable across unrelated processors.

### Safe custom naming

After choosing an upstream kernel variant, both the full builder and dry-run let the user keep its original package/kernel name or explicitly rename it.

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

### Upstream PGP signing-key handling

Before source preparation, Forge inspects the selected upstream PKGBUILD's
`validpgpkeys` fingerprints and checks the invoking user's GnuPG keyring.

If a required key is missing or locally expired, Forge explains the problem
and offers to retrieve or refresh only the full fingerprints explicitly pinned
by that upstream PKGBUILD. Retrieved keys are fingerprint-checked before use.

Signature verification is never disabled or bypassed. If a required key cannot
be retrieved or remains unusable, the build stops safely before the expensive
source/build stages.

### Checksum-pinned BORE compatibility

The affected CachyOS 7.3 recipe expects an older BORE patch while downloading
it from the moving `kernel-patches/master` URL. Forge recognizes the exact
7.3 BORE source URL and expected BLAKE2b checksum at the same source-array
index, and selects the immutable historical commit whose patch matches that
original checksum. The RT i915 patch, kernel archive, signing keys and source
checksums are preserved. Other URLs, versions or updated checksums retain
upstream behavior. Unknown checksum failures still stop source preparation.

### Dependency handling

Kernel PKGBUILD dependencies remain defined by the selected upstream CachyOS PKGBUILD.

During source preparation, `makepkg` is allowed to synchronize missing dependencies through pacman. This avoids maintaining a duplicated dependency list inside the project.

The user still controls the pacman transaction; dependency installation is not forced with `--noconfirm`.

### Disk-backed build workspace

Kernel builds can consume a large amount of temporary storage.

The full builder uses a disk-backed workspace under:

```text
/var/tmp/cachyos-kernel-build.XXXXXX
```

and assigns a dedicated `TMPDIR` inside that workspace.

The dry-run similarly uses `/var/tmp/kernelforge-desktop-dryrun.XXXXXX` with its own `TMPDIR`. Both entry points share source preparation, dependency handling, naming, configuration and validation through `lib/build.sh` and `lib/naming.sh`.

### Optional Zstandard-compressed DWARF

When a selected kernel enables DWARF debugging and its compiler/linker can
resolve `CONFIG_DEBUG_INFO_COMPRESSED_ZSTD`, both the full and dry-run builders
offer an optional Zstd-compression prompt. Enter or **No** preserves the
upstream configuration. The tool probes a disposable copy before offering the
setting; the final resolved configuration must still retain DWARF version,
BTF, and BTF module support. No driver pruning or removal of debug
information is involved.

The builder also retains `.kernelforge-space-report.txt` containing a
post-build `src/`, `pkg/`, and compiler-temp space snapshot. This report is
**not a measured peak**. To compare size, build identical sources/configuration
once with the upstream setting and once with Zstd, measuring actual peak disk
usage externally. Compression savings are toolchain- and kernel-dependent.
The separate post-install cleanup feature remains optional and unchanged.

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
- GnuPG (`gpg`)
- `makepkg`
- GNU Make
- pacman for dependency/package installation

Kernel-specific dependencies are resolved from the selected upstream PKGBUILD.

A normal Arch package-building environment is expected. On a minimal vanilla Arch installation, additional build tools may be required before the builder itself can run.

## Usage

### Kernel tick frequency

After variant selection and source preparation, both the full builder and
dry-run ask for `upstream`, `100`, `250`, `300`,
or `1000` Hz. Press Enter to preserve the selected variant's upstream
frequency. An explicit frequency is checked against the selected kernel
source; unavailable choices fail before compilation. After `olddefconfig`,
validation checks both the frequency choice and the numeric `CONFIG_HZ` value.

Tick frequency is independent of the other options. The existing
`TICKRATE=idle` profile controls tickless mode; it is not a frequency in Hz.

### Optional autogrouping and transparent hugepages

These independent prompts appear after selecting, preparing, and normalizing
the kernel. Support is checked by resolving a separate trial configuration;
the upstream baseline remains untouched.

- Autogrouping is offered only when Kconfig permits it, including RT variants.
  BMQ and other `SCHED_ALT` configurations never get this prompt.
- Transparent hugepages (THP) are offered only for non-RT variants where Kconfig
  permits THP and its `madvise` mode. RT variants never get this prompt.
- Each prompt defaults to **no**. `n`, Enter, or EOF preserves the selected
  kernel's upstream setting, whether enabled, disabled, or absent.
- `y` enables autogrouping, or enables THP with `madvise` as its kernel default.
  THP `madvise` uses hugepages for applications that explicitly request them.

After dependency resolution, validation checks the requested settings or exact
preservation of declined settings. These options do not write sysctl/sysfs
settings or modify userspace services.

The former combined latency-tuning toggle has been removed.


Clone the repository, enter it, and then launch builder.sh:

```bash
git clone https://github.com/seba970423/CachyOSKernel-Forge
cd CachyOSKernel-Forge/
./builder.sh
```

The builder will then:

1. load and validate the selected project profile
2. detect local hardware
3. resolve optional capability preservation/removal choices
4. create a disk-backed build workspace
5. clone the latest CachyOS kernel packaging repository
6. discover available compatible kernel variants
7. let the user select a variant
8. optionally rename the resulting kernel/package
9. synchronize missing PKGBUILD dependencies when necessary
10. prepare the upstream kernel source
11. normalize the upstream Kconfig baseline and ask for supported optional tuning
12. apply the project profile
13. apply the resolved capability policy
14. run `olddefconfig`
15. validate the final resolved Kconfig
16. optionally compile the kernel
17. optionally install the exact packages produced by the build

## Dry run

Local regression tests (no kernel compilation or installation):

```bash
./tests/run-tests.sh
```

Run source preparation and configuration validation without compiling or installing:

```bash
./builder-dry-run.sh
```

The dry-run can offer to install missing build dependencies through `pacman`,
just like the full builder; it does not build or install kernel packages.

The desktop v0.5 policy update has local regression coverage for detection,
prompt defaults and explicit removals, the captured desktop configuration,
manufacturer driver preservation, shared preparation/naming, failure handling,
tick frequency, optional tuning, cleanup and DWARF compression. These checks do
not constitute a new kernel compilation or boot test.

It is useful when changing profiles, hardware detection, policy logic, or Kconfig handling without waiting for a full kernel compilation.

A dry run should be used before expensive real builds when making substantial changes to the configuration architecture.

## Project layout

```text
.
├── builder.sh
├── builder-dry-run.sh
├── lib/
│   ├── build.sh
│   ├── naming.sh
│   ├── hardware.sh
│   ├── kconfig.sh
│   ├── pgp.sh
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

### `lib/pgp.sh`

Checks upstream `validpgpkeys`, offers safe retrieval/refresh of missing signing keys, and never bypasses makepkg signature verification.

### `lib/policy.sh`

Interactive capability preservation/removal choices; CPU vendor selects the applicable TDX/SEV prompt.

### `lib/kconfig.sh`

Kconfig modification helpers and profile/policy application.

### `lib/validate.sh`

Post-`olddefconfig` validation of important kernel configuration invariants.

### `lib/upstream.sh`

CachyOS upstream cloning, variant discovery, compatibility checks, and prepare-time compatibility handling.

### `lib/profile.sh`

Profile loading and profile-value validation.

### `profiles/`

Human-maintained desktop policy and a captured regression reference. The [ThinkPad edition](https://github.com/seba970423/CachyOSKernel-Forge-Thinkpad-Edition) maintains its own family-specific policy independently.

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

The desktop profile preserves support beyond the currently detected hardware. Explicitly removing KVM or specialized NVMe capabilities can still affect software that uses those features.

## Future work

Potential follow-up work includes:

- broader clean-install testing on vanilla Arch
- testing on additional Arch-based distributions
- expand hardware preservation coverage as upstream adds new driver families

The desktop profile should remain conservative and known-good while more specialized profiles are developed independently.

