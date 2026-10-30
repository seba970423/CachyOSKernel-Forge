#!/usr/bin/env bash
# Narrow fix for the CachyOS 7.3 BORE source mismatch seen in kernel/sched/fair.c.
# Runs after final Kconfig resolution. Never edits a non-BORE kernel.

kernelforge_fix_bore_protect_slice() {
    local tree="$1"
    local config="$tree/.config"
    local fair="$tree/kernel/sched/fair.c"
    local tmp
    local analysis

    [[ -f "$config" ]] || {
        printf 'ERROR: Kernel configuration missing for BORE source check: %s\n' "$config" >&2
        return 1
    }
    # Only the BORE build loses the normalized symbol's definition.
    grep -qx 'CONFIG_SCHED_BORE=y' "$config" || return 0
    [[ -f "$fair" && ! -L "$fair" ]] || {
        printf 'ERROR: Missing or symlinked BORE scheduler source: %s\n' "$fair" >&2
        return 1
    }

    if grep -Fq '/* KernelForge: BORE 7.3 update_protect_slice compatibility */' "$fair"; then
        printf '==> BORE scheduler compatibility already applied.\n'
        return 0
    fi

    # Count the exact failing statement inside update_protect_slice only.
    # If upstream changed the implementation, do not guess at a replacement.
    analysis="$(awk '
        /^static inline void update_protect_slice\(/ { inside=1; functions++ }
        inside && /^[[:space:]]*#(if|elif).*CONFIG_SCHED_BORE/ { guarded++ }
        inside && /^[[:space:]]*u64 slice = normalized_sysctl_sched_base_slice;[[:space:]]*$/ { hits++ }
        inside && /^[[:space:]]*\}/ { inside=0 }
        END { printf "%d %d %d", functions, hits, guarded }
    ' "$fair")" || return 1
    local functions hits guarded
    read -r functions hits guarded <<<"$analysis"

    if (( hits == 0 )); then
        printf '==> BORE scheduler source check passed; no compatibility edit needed.\n'
        return 0
    fi
    if (( functions != 1 || hits != 1 || guarded != 0 )) ||
       ! grep -Eq '^__read_mostly uint sysctl_sched_base_slice[[:space:]]*=' "$fair"; then
        printf 'ERROR: Unrecognized BORE scheduler source mismatch; refusing to rewrite %s\n' "$fair" >&2
        return 1
    fi

    tmp="$(mktemp "${fair}.kernelforge.XXXXXX")" || return 1
    if ! awk '
        /^static inline void update_protect_slice\(/ { inside=1 }
        inside && /^[[:space:]]*u64 slice = normalized_sysctl_sched_base_slice;[[:space:]]*$/ {
            print "/* KernelForge: BORE 7.3 update_protect_slice compatibility */"
            print "#ifdef CONFIG_SCHED_BORE"
            print "\tu64 slice = sysctl_sched_base_slice;"
            print "#else /* !CONFIG_SCHED_BORE */"
            print
            print "#endif /* CONFIG_SCHED_BORE */"
            changed++
            next
        }
        inside && /^[[:space:]]*\}/ { inside=0 }
        { print }
        END { if (changed != 1) exit 42 }
    ' "$fair" >"$tmp"; then
        rm -f -- "$tmp"
        printf 'ERROR: BORE scheduler source compatibility edit could not be verified.\n' >&2
        return 1
    fi
    chmod --reference="$fair" "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -- "$tmp" "$fair" || return 1
    printf '==> Corrected BORE-only update_protect_slice() base-slice reference before compilation.\n'
}

# Compile the affected scheduler object before makepkg starts a whole-kernel
# parallel build. This uses the final prepared .config and produces only the
# target object/dependencies in the same tree makepkg will later consume.
kernelforge_preflight_bore_scheduler() {
    local tree="$1"
    local log_file="$2"
    [[ -f "$tree/.config" ]] || return 1
    grep -qx 'CONFIG_SCHED_BORE=y' "$tree/.config" || return 0
    printf '==> Checking BORE scheduler compilation before the full kernel build...\n'
    # Discard the probe object and its command metadata: makepkg may select
    # different compiler flags, and must compile this object for itself.
    local result=0
    make -C "$tree" -j2 kernel/sched/fair.o >"$log_file" 2>&1 || result=$?
    rm -f -- "$tree/kernel/sched/fair.o" "$tree/kernel/sched/.fair.o.cmd" || return 1
    if (( result != 0 )); then
        printf 'ERROR: BORE scheduler preflight failed; full kernel compilation was NOT started.\n' >&2
        printf '==> Preflight log: %s\n' "$log_file" >&2
        grep -nE -m 10 '(^|[[:space:]])(fatal )?error:|Error [0-9]+' "$log_file" >&2 || true
        tail -n 35 "$log_file" >&2 || true
        return 1
    fi
    printf '==> BORE scheduler object compiled successfully.\n'
}
