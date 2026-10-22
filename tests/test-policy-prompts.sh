#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/profiles/features.conf"
source "$REPO_ROOT/lib/policy.sh"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# VMX/SVM flags may be hidden by firmware or a VM. They must not remove KVM.
CPU_HAS_VMX=no CPU_HAS_SVM=no
for CPU_VENDOR in intel amd unknown; do
    for input in '' $'\n\n\n\n' $'y\ny\ny\ny'; do
        resolve_policy <<< "$input" >/dev/null
        [[ "$KEEP_KVM" == yes && "$KEEP_INTEL_TDX" == yes && "$KEEP_AMD_SEV" == yes && "$KEEP_NVME_FABRICS" == yes && "$KEEP_NVME_TARGET" == yes ]] || fail "Defaults lost support on $CPU_VENDOR."
    done
    resolve_policy </dev/null >/dev/null
    [[ "$KEEP_KVM" == yes && "$KEEP_NVME_TARGET" == yes ]] || fail 'EOF changed defaults.'
    # Declining KVM skips the dependent prompt, preserving subsequent answers.
    exec 3<<< $'n\nn\ny\nsentinel'
    resolve_policy <&3 >/dev/null
    read -r remaining <&3
    exec 3<&-
    [[ "$KEEP_KVM" == no && "$KEEP_INTEL_TDX" == no && "$KEEP_AMD_SEV" == no && "$KEEP_NVME_FABRICS" == no && "$KEEP_NVME_TARGET" == yes && "$remaining" == sentinel ]] || fail 'KVM opt-out consumed the wrong answers.'
done
for CPU_VENDOR in intel amd; do
    resolve_policy <<< $'y\nn\ny\ny' >/dev/null
    [[ "$KEEP_KVM" == yes ]] || fail 'Advanced opt-out removed standard KVM.'
    if [[ "$CPU_VENDOR" == intel ]]; then
        [[ "$KEEP_INTEL_TDX" == no && "$KEEP_AMD_SEV" == yes ]] || fail 'TDX opt-out affected SEV.'
    else
        [[ "$KEEP_AMD_SEV" == no && "$KEEP_INTEL_TDX" == yes ]] || fail 'SEV opt-out affected TDX.'
    fi
done
printf 'Desktop capability prompt tests passed.\n'
