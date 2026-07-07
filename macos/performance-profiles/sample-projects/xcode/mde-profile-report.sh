#!/bin/bash
# mde-profile-report.sh - MDE performance-profile "report card" for an Xcode build.
#
# This is the Xcode analog of the Android sample's Gradle init script. It is invoked by
# Xcode Scheme *Build* pre/post-actions (installed by ./xcode-report.sh), which bracket a
# build inside Xcode's process tree:
#
#   pre-action  ->  mde-profile-report.sh before   (snapshot MDE scan counters + time)
#   post-action ->  mde-profile-report.sh after    (snapshot again, print the report)
#
# It only READS mdatp state (performance-profiles list-applied + diagnostic
# real-time-protection-statistics). It never applies/removes profiles or changes
# protection, so it is safe to leave installed. Because Xcode buries pre/post-action
# output in the build log, `after` also writes REPORT to a file and fires a desktop
# notification so the result is visible.

set -uo pipefail

MODE="after"
DEBUG="0"
for arg in "$@"; do
    case "$arg" in
        before|after)
            MODE="$arg"
            ;;
        --debug)
            DEBUG=1
            ;;
        --no-debug)
            DEBUG=0
            ;;
        -h|--help)
            cat <<'EOF'
Usage: mde-profile-report.sh [before|after] [--debug]

  before       capture pre-build counter snapshot
  after        capture post-build snapshot and print report (default)
  --debug      include raw counter internals in report output
  --no-debug   disable debug output
EOF
            exit 0
            ;;
    esac
done
STATE="${MDE_REPORT_STATE:-${TMPDIR:-/tmp}/mde-xcode-report.state}"
REPORT_OUT="${MDE_REPORT_OUT:-${TMPDIR:-/tmp}/mde-xcode-report.txt}"
REPORT_DEBUG_OUT="${MDE_REPORT_DEBUG_OUT:-${TMPDIR:-/tmp}/mde-xcode-report-debug.txt}"

# Sum totalFilesScanned + totalScanTime(ns) across all per-process counters.
# Also return the counter count so callers can detect when statistics are unavailable.
scan_totals() {
    mdatp diagnostic real-time-protection-statistics --output json 2>/dev/null \
    | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("0 0 0"); sys.exit(0)
f = t = 0
count = 0
for c in d.get("counters", []):
    count += 1
    try: f += int(c.get("totalFilesScanned") or 0)
    except Exception: pass
    try: t += int(c.get("totalScanTime") or 0)
    except Exception: pass
print(f"{f} {t} {count}")
' 2>/dev/null || echo "0 0 0"
}

# Profiles listed between the ==== fences of `list-applied`.
applied_profiles() {
    mdatp performance-profiles list-applied 2>/dev/null | awk '
        /^====/ { inside = !inside; next }
        inside && $0 !~ /^---/ && NF {
            if ($0 ~ /^No applied performance profiles$/) next
            if ($0 ~ /^Merge policy:/) next
            print
        }
    ' | paste -sd',' - | sed 's/,/, /g'
}

# Walk the parent-process chain looking for the Xcode IDE.
under_xcode() {
    local pid=$PPID i line comm
    for ((i=0; i<30; i++)); do
        [ "${pid:-0}" -le 1 ] && break
        line=$(ps -o ppid=,comm= -p "$pid" 2>/dev/null) || break
        [ -z "$line" ] && break
        comm=$(printf '%s' "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
        case "$comm" in *Xcode*) return 0;; esac
        pid=$(printf '%s' "$line" | awk '{print $1}')
    done
    return 1
}

if [ "$MODE" = "before" ]; then
    read -r bf bt bcount < <(scan_totals)
    printf '%s %s %s %s\n' "${bf:-0}" "${bt:-0}" "${bcount:-0}" "$(date +%s)" > "$STATE"
    exit 0
fi

# ---- after: compute delta + render ----------------------------------------
bf=0; bt=0; bcount=0; bstart=$(date +%s)
if [ -f "$STATE" ]; then
    read -r bf bt third fourth < "$STATE"
    if [ -n "${fourth:-}" ]; then
        bcount=${third:-0}
        bstart=${fourth:-$(date +%s)}
    else
        bcount=0
        bstart=${third:-$(date +%s)}
    fi
fi
read -r af at acount < <(scan_totals)
raw_dfiles=$(( ${af:-0} - ${bf:-0} ))
raw_dns=$(( ${at:-0} - ${bt:-0} ))
dfiles=$raw_dfiles
dns=$raw_dns
neg=0
[ "$dfiles" -lt 0 ] && { dfiles=0; neg=1; }
[ "$dns" -lt 0 ] && { dns=0; neg=1; }
dms=$(awk -v n="$dns" 'BEGIN{printf "%.1f", n/1000000.0}')
elapsed=$(( $(date +%s) - ${bstart:-$(date +%s)} ))
profiles=$(applied_profiles)
ide="no / can't tell (daemon or terminal)"; under_xcode && ide="yes"

cover=""
case ",$profiles," in *,xcode,*) cover="xcode";; esac
treeapplied=0
case ",$profiles," in *,xcode-ide-tree,*) treeapplied=1;; esac

covering=0
if [ -n "$cover" ]; then
    covering=1
elif [ "$treeapplied" = 1 ] && [ "$ide" = "yes" ]; then
    covering=1
fi

stats_available=1
[ "${bcount:-0}" -eq 0 ] && [ "${acount:-0}" -eq 0 ] && stats_available=0

suppressed=0
[ "$covering" = 1 ] && [ "$stats_available" = 1 ] && [ "$dfiles" -lt 200 ] && suppressed=1

render() {
    printf '  ┌─ MDE performance-profile report ─────────────────────────────\n'
    printf '  │ Build wall time (pre→post action): %ss\n' "$elapsed"
    printf '  │ Launched inside Xcode process tree: %s\n' "$ide"
    printf '  │ Applied performance profiles: %s\n' "${profiles:-(none)}"
    if [ -n "$cover" ]; then
        printf "  │ ✅ Covered by toolchain profile '%s' (matches the Xcode toolchain).\n" "$cover"
    elif [ "$treeapplied" = 1 ]; then
        printf "  │ ℹ  'xcode-ide-tree' is applied — it covers builds run INSIDE Xcode.\n"
        printf "  │    (Trust the scan delta below as the real proof it's taking effect.)\n"
    elif [ -z "$profiles" ]; then
        printf "  │ ⚠  No profiles applied — MDE is scanning this build at full load.\n"
    else
        printf "  │ ⚠  No profile covers this build — apply 'xcode' (terminal) or 'xcode-ide-tree' (in-IDE).\n"
    fi
    printf '  │ MDE files scanned during build: %s%s\n' "$dfiles" "$([ "$neg" = 1 ] && printf ' (≈)')"
    printf '  │ MDE scan time during build:     %s ms%s\n' "$dms" "$([ "$neg" = 1 ] && printf ' (≈)')"
    if [ "$DEBUG" = "1" ]; then
        printf '  │ debug: before files=%s time_ns=%s counters=%s\n' "${bf:-0}" "${bt:-0}" "${bcount:-0}"
        printf '  │ debug: after  files=%s time_ns=%s counters=%s\n' "${af:-0}" "${at:-0}" "${acount:-0}"
        printf '  │ debug: raw deltas files=%s time_ns=%s\n' "$raw_dfiles" "$raw_dns"
    fi
    if [ "$stats_available" = 0 ]; then
        printf "  │    → ⚠ scan counters unavailable; cannot infer suppression from this build.\n"
    elif [ "$covering" = 0 ] && [ "$dfiles" -eq 0 ] && [ "$dns" -eq 0 ]; then
        printf "  │    → ⚠ zero scan delta without a covering profile — likely capture gap, not suppression.\n"
    elif [ "$suppressed" = 1 ]; then
        printf "  │    → ✅ scanning suppressed for this build (profile is working).\n"
    else
        printf "  │    → scanning active — a covering profile would drive this toward ≈0.\n"
    fi
    printf '  └──────────────────────────────────────────────────────────────\n'
    [ "$neg" = 1 ] && printf '  note: a negative raw delta (a busy process exited mid-build) clamped to ≈0.\n'
}

report="$(render)"
printf '%s\n' "$report"
printf '%s\n' "$report" > "$REPORT_OUT" 2>/dev/null || true
if [ "$DEBUG" = "1" ]; then
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] mode=$MODE"
        printf '%s\n' "$report"
        echo ""
    } >> "$REPORT_DEBUG_OUT" 2>/dev/null || true
    printf '  debug: wrote detail to %s\n' "$REPORT_DEBUG_OUT"
fi
osascript -e "display notification \"${dfiles} files scanned this build (see build log)\" with title \"MDE profile report\"" >/dev/null 2>&1 || true
rm -f "$STATE" 2>/dev/null || true
exit 0
