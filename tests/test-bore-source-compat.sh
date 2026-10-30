#!/usr/bin/env bash
set -euo pipefail
ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
source "$(dirname "$0")/../lib/bore-compat.sh"
mkdir -p "$ROOT/kernel/sched"
FAIR="$ROOT/kernel/sched/fair.c"
CONFIG="$ROOT/.config"
cat > "$FAIR" <<'SRC'
#ifdef CONFIG_SCHED_BORE
__read_mostly uint sysctl_sched_base_slice     = nsecs_per_tick;
#else
static unsigned int normalized_sysctl_sched_base_slice = 700000ULL;
#endif
static inline void set_protect_slice(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
#ifdef CONFIG_SCHED_BORE
    u64 slice = sysctl_sched_base_slice;
#else
    u64 slice = normalized_sysctl_sched_base_slice;
#endif
}
static inline void update_protect_slice(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    u64 slice = normalized_sysctl_sched_base_slice;
    se->vprot = slice;
}
SRC
cp "$FAIR" "$ROOT/original"
printf '# CONFIG_SCHED_BORE is not set\n' > "$CONFIG"
kernelforge_fix_bore_protect_slice "$ROOT" >/dev/null
cmp -s "$FAIR" "$ROOT/original" || { echo 'ERROR: non-BORE source modified.'; exit 1; }
printf 'CONFIG_SCHED_BORE=y\n' > "$CONFIG"
kernelforge_fix_bore_protect_slice "$ROOT" >/dev/null
grep -q 'u64 slice = sysctl_sched_base_slice' "$FAIR" || exit 1
[[ $(grep -c '^#ifdef CONFIG_SCHED_BORE' "$FAIR") == 3 ]] || exit 1
cp "$FAIR" "$ROOT/patched"
kernelforge_fix_bore_protect_slice "$ROOT" >/dev/null
cmp -s "$FAIR" "$ROOT/patched" || { echo 'ERROR: source patch not idempotent.'; exit 1; }

# Unknown upstream changes must fail closed without rewriting the source.
cp "$ROOT/original" "$FAIR"
sed -i 's/__read_mostly uint sysctl_sched_base_slice/unsigned int sysctl_sched_base_slice/' "$FAIR"
cp "$FAIR" "$ROOT/unrecognized"
if kernelforge_fix_bore_protect_slice "$ROOT" >/dev/null 2>&1; then
    echo 'ERROR: unrecognized source passed guard.'; exit 1
fi
cmp -s "$FAIR" "$ROOT/unrecognized" || { echo 'ERROR: unrecognized source changed.'; exit 1; }

# A failed focused compile must block the expensive full-kernel build.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/make" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_MAKE_LOG"
exit "$MOCK_MAKE_EXIT"
MOCK
chmod +x "$ROOT/bin/make"
printf 'CONFIG_SCHED_BORE=y\n' > "$CONFIG"
export MOCK_MAKE_LOG="$ROOT/make-calls"
export MOCK_MAKE_EXIT=0
PATH="$ROOT/bin:$PATH" kernelforge_preflight_bore_scheduler "$ROOT" "$ROOT/preflight.log" >/dev/null
[[ "$(cat "$MOCK_MAKE_LOG")" == "-C $ROOT -j2 kernel/sched/fair.o" ]] || exit 1
if MOCK_MAKE_EXIT=2 PATH="$ROOT/bin:$PATH" kernelforge_preflight_bore_scheduler "$ROOT" "$ROOT/preflight.log" >/dev/null 2>&1; then
    echo 'ERROR: preflight did not block a failed scheduler build.'; exit 1
fi
printf '# CONFIG_SCHED_BORE is not set\n' > "$CONFIG"
count="$(wc -l <"$MOCK_MAKE_LOG")"
PATH="$ROOT/bin:$PATH" kernelforge_preflight_bore_scheduler "$ROOT" "$ROOT/preflight.log" >/dev/null
[[ "$(wc -l <"$MOCK_MAKE_LOG")" == "$count" ]] || { echo 'ERROR: non-BORE variant invoked preflight.'; exit 1; }
printf 'BORE scheduler compatibility tests passed.\n'
