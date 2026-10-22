#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/hardware.sh"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Mock the relevant T590-style Intel display line. "VGA compatible" must not
# trigger the old false-positive ATI substring match.
lspci() {
    printf '%s\n' \
        '00:02.0 VGA compatible controller [0300]: Intel Corporation WhiskeyLake-U GT2 [UHD Graphics 620] [8086:3ea0] (rev 02)' \
        '00:14.3 Network controller [0280]: Intel Corporation Cannon Point-LP CNVi [Wireless-AC] [8086:9df0]' \
        '3d:00.0 Non-Volatile memory controller [0108]: Intel Corporation NVMe Controller [8086:f1a6]'
}

detect_pci_hardware
[[ "$GPU_INTEL" == "yes" ]] || fail "Intel GPU was not detected."
[[ "$GPU_AMD" == "no" ]] || fail "Intel VGA line produced a false AMD GPU."
[[ "$GPU_NVIDIA" == "no" ]] || fail "Intel VGA line produced a false NVIDIA GPU."

lspci() {
    printf '%s\n' \
        '04:00.0 Display controller [0380]: Advanced Micro Devices, Inc. [AMD/ATI] Device [1002:1681]' \
        '05:00.0 3D controller [0302]: NVIDIA Corporation Device [10de:25a2]'
}

detect_pci_hardware
[[ "$GPU_INTEL" == "no" ]] || fail "AMD/NVIDIA layout produced a false Intel GPU."
[[ "$GPU_AMD" == "yes" ]] || fail "AMD PCI vendor ID was not detected."
[[ "$GPU_NVIDIA" == "yes" ]] || fail "NVIDIA PCI vendor ID was not detected."

printf 'Hardware detection tests passed.\n'


# Missing pciutils and inaccessible PCI inventory are diagnostic-only cases.
have_cmd() { return 1; }
detect_pci_hardware
[[ "$GPU_INTEL" == unknown && "$GPU_AMD" == unknown && "$NVME_PRESENT" == unknown ]] || fail 'Missing lspci reused stale detection.'
have_cmd() { return 0; }
lspci() { return 1; }
detect_pci_hardware 2>/dev/null
[[ "$GPU_INTEL" == unknown && "$WIFI_INTEL" == unknown && "$THUNDERBOLT_PRESENT" == unknown ]] || fail 'Failed lspci changed policy or retained stale detection.'
