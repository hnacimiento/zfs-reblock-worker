#!/usr/bin/env bash
# =============================================================================
# zfs-reblock-worker.sh - V4.4.14
#
# Rewrites large files in place (same dataset) so their blocks adopt the
# recordsize the dataset is already configured with. Built for TrueNAS SCALE.
#
# SAFETY CONTRACT - invariants, not options. Nothing on the CLI disables these:
#   1. Snapshot inventory: a job never grows by itself.
#   2. Copy to a job-scoped temporary in the SAME directory (same dataset).
#   3. Source identity (size+inode+mtime) checked before, during and right
#      before the commit.
#   4. Cryptographic hash source <-> temp before commit; re-read after commit.
#      Default is BLAKE2b (b2), same guarantee as SHA-256, ~3x faster;
#      cascades to BLAKE3 then SHA-256 if b2sum is missing (see --hash).
#   5. atime/mtime captured BEFORE any read and restored explicitly.
#   6. Commit is a same-directory rename, nothing else.
#   7. A hardlink rollback anchor keeps the original inode alive across the
#      commit, so a failed post-commit check is reversible at zero space cost.
#   8. State persisted (and fsynced) around every meaningful boundary.
#   9. Recovery is conservative: an orphan temp is never promoted nor deleted.
#  10. The dataset recordsize is NEVER modified.
#
# zdb is ADVISORY ONLY. Its textual output is a debug interface, not an API,
# and a block-size hint never authorizes skipping a file.
#
# LAYOUT - sections are ordered so a reader can follow one concern at a time:
#   [1] Constants          [8]  Job lifecycle    [15] Reblock pipeline
#   [2] Globals            [9]  Inventory        [16] Recovery
#   [3] Output             [10] State machine    [17] Reporting
#   [4] Units              [11] Metrics          [18] Wizard / browser
#   [5] Exit codes         [12] Governor         [19] CLI
#   [6] Preflight          [13] UI               [20] Main
#   [7] Dataset            [14] File primitives
# =============================================================================

set -uo pipefail

VERSION="4.4.14"

# -----------------------------------------------------------------------------
# [1] Constants and defaults. The first block is the V2 contract: running with
#     only a directory must behave exactly like V2 did.
# -----------------------------------------------------------------------------
readonly D_BW="35M" D_NICE=19 D_IONICE=3 D_COOLDOWN=30 D_RECORDSIZE="1M"
readonly D_THRESHOLD=$((2*1024*1024*1024))
readonly D_BW_MIN="10M" D_BW_MAX="80M" D_RETRIES=2 D_HEALTH_INTERVAL=10
readonly D_MARGIN_PCT=20 D_MARGIN_MIN=$((1024*1024*1024))
readonly D_ADAPTIVE="auto" D_INTEGRITY="strict" D_PROFILE="default" D_WORKERS=1
readonly D_HASH="b2"
readonly D_NICE_MIN=10 D_IONICE_MIN=2
# Overridable so tests can point it at a fixture instead of the real kernel
# stats file; on a non-ZFS host this simply never exists, and read_cpu_mem()
# treats that as a silent no-op.
ARCSTATS_FILE="${ZRW_ARCSTATS_FILE:-/proc/spl/kstat/zfs/arcstats}"
readonly BASELINE_SECONDS=15 BASELINE_SAMPLES=3 EMERGENCY_SAMPLES=3

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P)"
STATE_ROOT="${ZRW_STATE_ROOT:-${SCRIPT_DIR}/jobs}"
RUNTIME_DIR="${STATE_ROOT}/.runtime"
PREFS_FILE="${RUNTIME_DIR}/preferences.conf"
PROFILES_FILE="${ZRW_PROFILES:-${SCRIPT_DIR}/examples/profiles.conf}"

# -----------------------------------------------------------------------------
# [5] Exit codes. Semantic on purpose: automation must be able to tell a missing
#     dependency from a recordsize mismatch without parsing text.
# -----------------------------------------------------------------------------
readonly EX_OK=0            # success, or job paused cleanly
readonly EX_USAGE=1         # bad arguments or invalid configuration
readonly EX_NOT_ROOT=10     # UID 0 required
readonly EX_LOCKED=11       # another worker owns this job
readonly EX_FAILED=12       # job completed with FAILED files
readonly EX_PAUSED=13       # job stopped early (space, operator, governor)
readonly EX_INTERNAL=14     # unexpected internal condition
readonly EX_DEP_MISSING=20  # critical command absent
readonly EX_DEP_BROKEN=21   # command present but not functional
readonly EX_NOT_ZFS=22      # target is not inside an identifiable ZFS dataset
readonly EX_RECORDSIZE=23   # dataset recordsize differs from the expected one

# -----------------------------------------------------------------------------
# [2] Globals. Grouped by lifetime: configuration, job identity, per-file,
#     counters, health. Everything is initialized so `set -u` stays useful.
# -----------------------------------------------------------------------------
# -- configuration (CLI/wizard/profile resolve into exactly these) ------------
BW_TARGET="$D_BW" BW_MIN="$D_BW_MIN" BW_MAX="$D_BW_MAX"
NICE_VALUE="$D_NICE" IONICE_CLASS="$D_IONICE" COOLDOWN="$D_COOLDOWN"
NICE_MIN="$D_NICE_MIN" IONICE_MIN="$D_IONICE_MIN"
THRESHOLD_BYTES="$D_THRESHOLD" EXPECTED_RECORDSIZE="$D_RECORDSIZE"
# Frozen the instant this run's config is settled (new job saved, or resumed
# job loaded) -- see main(), right after that point. EXPECTED_RECORDSIZE and
# THRESHOLD_BYTES stay live-mutable after that (the operator's [C] menu,
# options 8/9, change them "for the next job"), which is fine for staging a
# future run but wrong for anything judging THIS one: env_sane()'s safety
# check compared the real dataset against the live EXPECTED_RECORDSIZE and,
# once the operator changed it mid-run, concluded the dataset itself had
# changed and aborted a job that was never actually at risk -- found live,
# by exactly that operator action. RUN_RECORDSIZE/RUN_THRESHOLD are what
# env_sane() and every current-job display (dashboard header, completion
# summary) should read instead.
RUN_RECORDSIZE="" RUN_THRESHOLD=0
MARGIN_PCT="$D_MARGIN_PCT" MARGIN_MIN="$D_MARGIN_MIN" RETRIES="$D_RETRIES"
HEALTH_INTERVAL="$D_HEALTH_INTERVAL" ADAPTIVE="$D_ADAPTIVE"
INTEGRITY="$D_INTEGRITY" PROFILE="$D_PROFILE" WORKERS="$D_WORKERS"
COOLDOWN_MODE="fixed" ADAPTIVE_PRIORITY="off"
TARGET_DIR="" BROWSER="bash"
CROSS_DATASET="skip" ONE_DATASET=0 HASH_ALGO="$D_HASH" HASH_CMD="${D_HASH}sum"
STALE_POLICY="auto"
SHOW_ESTIMATE=0
DS_HIT_NAME="" DS_HIT_RS="" DS_HIT_MOUNT=""
FILE_DS="" FILE_DS_RS="" DS_SKIP_WHY=""
TREE_DATASETS=1 TREE_RS_OK=1 TREE_RS_BAD=0
TREE_ACL_OK=0 TREE_ACL_BAD=0 TREE_ACL_REPORT=""
R_OTHER_DS=0 R_RECORDSIZE=0 N_HINT_1M=0

# -- modes --------------------------------------------------------------------
DRY_RUN=0 DRY_SAMPLE=0 STATUS_ONLY=0 CHECK_ONLY=0 RESUME=0
RETRY_FAILED=0 RETRY_STALE=0 REFRESH_INV=0 EXPLAIN_PATH="" JSON_OUT=0
UI_MODE="auto" LOG_FILE=""

# -- job identity -------------------------------------------------------------
JOB_ID="" JOB_SHORT="" JOB_DIR="" JOB_MODE="NEW"
ZFS_DATASET="" ZFS_MOUNT=""
INVENTORY="" STATE_DIR="" ANCHOR_DIR="" EVENT_LOG="" JOURNAL=""
SUMMARY_TSV="" SUMMARY_JSON="" CONFIG_FILE="" LOCK_FILE="" CONTROL_FILE=""
RESULTS_FILE="" STATE_LOCK="" PID_FILE="" WORKER_ID=0

# -- per-file scratch ---------------------------------------------------------
F_SIZE=0 F_INODE=0 F_MTIME="" F_ATIME="" F_MODE="" F_UID="" F_GID="" F_NLINK=1
CUR_TMP="" CUR_ANCHOR="" CUR_FILE="" CUR_SIZE=0 CUR_DONE=0 CUR_START=0
CUR_ATTEMPT=0 CUR_STATUS="idle" RSYNC_PID="" COOLDOWN_LEFT=0
ST_STATUS="PENDING" ST_ATTEMPT=0 ST_SIZE="" ST_INODE="" ST_MTIME="" ST_PATH=""
QPATH=""

# Which config.env fields the operator explicitly set on THIS invocation's
# command line. load_config() (below `[8] Job lifecycle`) skips these when
# resuming, so a flag typed on `--resume` actually takes effect instead of
# being silently overwritten by whatever the job was first created with.
declare -A CLI_SET

# -- counters -----------------------------------------------------------------
N_DONE=0 N_SKIP=0 N_FAIL=0 N_STALE=0 N_MISS=0 N_RECOV=0 N_FOREIGN=0 N_WARN=0
N_TOTAL=0 N_INDEX=0 BYTES_DONE=0 BYTES_PLANNED=0 BYTES_SEEN=0 JOB_START=0
R_HARDLINK=0 R_CHANGED=0 R_MISSING=0 R_SPACE=0 R_ROLLBACK=0
LAST_EVENTS=()

# -- control / health ---------------------------------------------------------
PAUSE_REQ=0 EXIT_REQ=0 AUTO_PAUSED=0 SPACE_PAUSE=0 ENV_ABORT=0
# Opt-in: without --auto-resume, a protective pause behaves exactly as always
# (exit 13, operator issues --resume by hand). With it, the SAME run waits out
# the pressure and keeps going on its own -- bounded by PAUSE_TIMEOUT_MIN, so
# it can never hang silently forever. Only the governor's own pause is
# eligible; an operator [P]/[Q] or a full disk always stop for real.
AUTO_RESUME_PRESSURE=0 PAUSE_TIMEOUT_MIN=120
# SPACE_PAUSE distinguishes "paused because the disk filled up" from every other
# pause, so the exit banner can tell the operator what to free instead of just
# reporting a pause.
STOP_AFTER=0 STOP_AT="" JOB_START_HM=""
BW_BPS=0 BW_CEIL_BPS=0 BW_MANUAL=0 COOLDOWN_BASE=0
HEALTH="UNKNOWN" HEALTH_WHY="not measured" HEALTH_SCORE=0
CPU=0 IOWAIT=0 LOAD1="0.00" MEM=0 DISK_UTIL=0 DISK_WAIT=0
PSI_IO=0 PSI_CPU=0 PSI_MEM=0 SWAP_USED=0 BASE_PSI=0 GOODPUT_BPS=0
BASE_LOAD="0" BASE_IOWAIT=0 BASE_MEM=0 BASE_DISK=0
AUTO_ACTION="HOLD" AUTO_WHY="startup" AUTO_UNTIL=0 AUTO_NEXT=0 CRIT_COUNT=0 LAST_CRIT_TS=0

TTY=0; [[ -t 1 && -t 0 ]] && TTY=1
COLOR=1; [[ -n "${NO_COLOR:-}" ]] && COLOR=0

# Colour exists to help a tired operator find things at 3am after ten hours of
# console. It is never load-bearing: every colour carries a word too, and the
# log file on disk is always plain text.
set_palette() {
    if (( TTY && COLOR )); then
        C_OFF=$'\033[0m'  C_B=$'\033[1m'    C_D=$'\033[2m'
        C_R=$'\033[31m'   C_G=$'\033[32m'   C_Y=$'\033[33m'
        C_BL=$'\033[34m'  C_M=$'\033[35m'   C_C=$'\033[36m'
        C_HDR=$'\033[1;37m' C_OKB=$'\033[1;32m' C_ERB=$'\033[1;31m' C_WRB=$'\033[1;33m'
    else
        C_OFF="" C_B="" C_D="" C_R="" C_G="" C_Y="" C_BL="" C_M="" C_C=""
        C_HDR="" C_OKB="" C_ERB="" C_WRB=""
    fi
}
set_palette

# Paints the [TAG] prefix of a log line. The eye finds the colour first and
# reads the word second, so a monochrome terminal loses nothing.
paint() {
    local m="$1" t c
    (( TTY && COLOR )) || { printf '%s' "$m"; return 0; }
    for t in OK:"$C_OKB" FAILED:"$C_ERB" ERROR:"$C_ERB" WARN:"$C_WRB" STALE:"$C_Y" \
             SKIP:"$C_D" MISSING:"$C_D" PAUSE:"$C_M" STOP:"$C_M" ROLLBACK:"$C_ERB" \
             RECOVERY:"$C_C" CRITICAL:"$C_ERB" AUTO:"$C_BL" OPERATOR:"$C_M" \
             VERIFY:"$C_G" PROCESS:"$C_B" ZFS:"$C_C" SPACE:"$C_Y" DRY-RUN:"$C_C" \
             AUTO-BASELINE:"$C_BL" RETRY:"$C_Y" QUARANTINE:"$C_Y" DATASET:"$C_C"; do
        c="${t#*:}"; t="${t%%:*}"
        [[ "$m" == *"[$t]"* ]] && { printf '%s' "${m/\[$t\]/${c}[$t]${C_OFF}}"; return 0; }
    done
    printf '%s' "$m"
}

# Section rule for human-readable output.
rule() { printf '%s%s%s\n' "$C_D" "──────────────────────────────────────────────────────────────────" "$C_OFF"; }
head_rule() { printf '%s%s%s\n' "$C_HDR" "══════════════════════════════════════════════════════════════════" "$C_OFF"; }

# -----------------------------------------------------------------------------
# [3] Output. One rule: the console view is a projection, the log is the record.
#     UI_MODE decides the projection; EVENT_LOG always gets everything.
#       dash  full-screen dashboard (needs a TTY)
#       plain timestamped lines
#       quiet warnings/errors plus the final summary only
#       json  one JSON event per line, nothing else on stdout
# -----------------------------------------------------------------------------
say() { [[ "$UI_MODE" == quiet || "$UI_MODE" == json ]] || printf '%s\n' "$*"; }
raw() { printf '%s\n' "$*"; }

jesc() { printf '%s' "${1-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g'; }

to_log() { [[ -n "$EVENT_LOG" ]] && printf '%s\n' "$*" >>"$EVENT_LOG"; return 0; }

log() {
    local ts msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"; msg="[$ts] $*"
    to_log "$msg"                      # the file is always plain text
    case "$UI_MODE" in
        json)  printf '{"ts":"%s","level":"info","msg":"%s"}\n' "$ts" "$(jesc "$*")" ;;
        quiet|dash) : ;;
        *)     printf '%s%s%s %s\n' "$C_D" "[$ts]" "$C_OFF" "$(paint "$*")" ;;
    esac
    return 0
}

err() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    to_log "[$ts] [ERROR] $*"
    if [[ "$UI_MODE" == json ]]; then
        printf '{"ts":"%s","level":"error","msg":"%s"}\n' "$ts" "$(jesc "$*")" >&2
    else
        printf '%s\n' "${C_R}[ERROR]${C_OFF} $*" >&2
    fi
    return 0
}

# Warnings are counted: "the worker must never degrade silently" means the run
# has to be able to say afterwards under what conditions it actually ran.
warn() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    N_WARN=$((N_WARN+1)); to_log "[$ts] [WARN] $*"
    if [[ "$UI_MODE" == json ]]; then
        printf '{"ts":"%s","level":"warn","msg":"%s"}\n' "$ts" "$(jesc "$*")" >&2
    else
        printf '%s\n' "${C_Y}[WARN]${C_OFF} $*" >&2
    fi
    return 0
}

# die CODE MESSAGE... - every fatal path carries a semantic exit code.
die() { local c="$1"; shift; err "$*"; exit "$c"; }

have() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# [4] Units and validation.
# -----------------------------------------------------------------------------
human() {
    awk -v n="${1:-0}" 'BEGIN{
        split("B KiB MiB GiB TiB PiB",u," "); i=1
        while (n>=1024 && i<6) { n/=1024; i++ }
        if (i==1) printf "%d %s", n, u[i]; else printf "%.2f %s", n, u[i] }'
}

hms() { local s="${1:-0}"; (( s<0 )) && s=0; printf '%02dh %02dm %02ds' $((s/3600)) $(((s%3600)/60)) $((s%60)); }

# Accepts 12345, 512K, 35M, 35MB, 35MiB, 2G, 1T. Base 1024, like V2 and rsync.
to_bytes() {
    local v="${1-}" n u
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s\n' "$v"; return 0; }
    [[ "$v" =~ ^([0-9]+)([KkMmGgTt])([Ii]?[Bb])?$ ]] || return 1
    n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]^^}"
    case "$u" in
        K) printf '%s\n' "$((n*1024))" ;;
        M) printf '%s\n' "$((n*1024*1024))" ;;
        G) printf '%s\n' "$((n*1024*1024*1024))" ;;
        T) printf '%s\n' "$((n*1024*1024*1024*1024))" ;;
    esac
}

# rsync reads a bare --bwlimit number as KiB/s. Normalizing to KiB avoids
# emitting suffixes rsync may not accept and keeps the value re-parseable.
bw_rate() { local k=$(( ${1:-0}/1024 )); (( k<1 )) && k=1; printf '%sK\n' "$k"; }
bw_label() { awk -v n="${1:-0}" 'BEGIN{printf "%.1fM", n/1048576}'; }

is_int() { [[ "${1-}" =~ ^[0-9]+$ ]]; }
is_bw()  { to_bytes "${1-}" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# [6] Preflight. Existing is not enough: critical tools must actually answer.
#     Critical missing -> stop. Optional missing -> announced fallback.
# -----------------------------------------------------------------------------
# Every external command the worker really runs, auxiliaries included.
readonly CRIT_CMDS=(bash awk find sort grep sed head tail uniq stat df date
                    sleep touch mv rm mkdir dirname basename ln rsync flock
                    zfs sync sha256sum id kill)
readonly OPT_CMDS=(zdb nice renice ionice getfacl getfattr realpath readlink
                   whiptail dialog fzf nproc b2sum b3sum md5sum tmux timeout)

detect_browser() {
    BROWSER="bash"
    (( TTY )) || return 0
    for b in whiptail dialog fzf; do have "$b" && { BROWSER="$b"; return 0; }; done
    return 0
}

preflight() {
    local c missing=()
    say "=============================================================="
    say "  SYSTEM PREFLIGHT"
    say "=============================================================="
    for c in "${CRIT_CMDS[@]}"; do
        if have "$c"; then say "  $(printf '%-10s' "$c") ${C_G}OK${C_OFF}"
        else say "  $(printf '%-10s' "$c") ${C_R}MISSING (CRITICAL)${C_OFF}"; missing+=("$c"); fi
    done
    for c in "${OPT_CMDS[@]}"; do
        if have "$c"; then say "  $(printf '%-10s' "$c") ${C_G}OK${C_OFF} (opcional)"
        else say "  $(printf '%-10s' "$c") ${C_Y}--${C_OFF} no disponible; se usara fallback"; fi
    done
    (( ${#missing[@]} )) && die "$EX_DEP_MISSING" "Dependencias criticas ausentes: ${missing[*]}. No se modifico nada."

    if [[ "$(id -u)" != 0 ]]; then
        # ZRW_TEST_MODE exists only for tests/. Without root there is no
        # guarantee of preserving foreign ownership, ACLs or xattrs.
        [[ "${ZRW_TEST_MODE:-0}" == 1 ]] || die "$EX_NOT_ROOT" \
            "Se requiere UID 0 (root) para preservar ownership/ACL/xattr con garantias."
        warn "ZRW_TEST_MODE: sin root. SOLO para pruebas; nunca sobre datos reales."
    fi
    zfs version >/dev/null 2>&1 || die "$EX_DEP_BROKEN" "'zfs' existe pero no responde."
    zfs list -H -o name >/dev/null 2>&1 || die "$EX_DEP_BROKEN" "'zfs list' no puede consultar datasets."
    # zdb printing "cannot open /etc/zfs/zpool.cache" is normal on TrueNAS and
    # harmless here, because the inspection is advisory in the first place.
    have zdb || warn "zdb ausente; la inspeccion ZFS advisory quedara en UNKNOWN."
    # No pipeline here on purpose: under `pipefail`, grep -q closes its end of
    # the pipe the instant it finds "ACLs", and rsync's Capabilities line often
    # sits early in a longer --version block. If rsync is still trying to write
    # the lines after it when that happens, it gets SIGPIPE and exits 141, which
    # pipefail then reports as the pipeline's exit code -- indistinguishable
    # from "no match". Confirmed on the reference NAS: 5/5 runs, deterministic
    # false WARN even though that rsync build fully supports ACLs.
    [[ "$(rsync --version 2>/dev/null)" == *ACLs* ]] \
        || warn "rsync sin soporte ACL declarado; -A podria degradarse."
    have renice || warn "renice ausente: no se podra bajar la prioridad de CPU."
    have ionice || warn "ionice ausente: no se podra bajar la prioridad de I/O."
    [[ -r /proc/diskstats ]] || warn "/proc/diskstats no legible: el governor no vera presion de disco."

    case "$HASH_ALGO" in
        b2)     # Default. BLAKE2b (RFC 7693) is a cryptographic hash with the
                # same guarantee this contract needs -- collision/preimage
                # resistant, immune to the length-extension weakness SHA-256
                # has -- and measured ~3x faster on the reference NAS (b2sum
                # 482 MB/s vs sha256sum 167 MB/s). Falls back through BLAKE3
                # (b3sum, not yet installed anywhere we have tested) and only
                # then to SHA-256, which stays a critical dependency so this
                # fallback can never come up empty.
                if have b2sum; then HASH_CMD=b2sum
                elif have b3sum; then
                    warn "b2sum no disponible; se usa b3 (BLAKE3), misma garantia criptografica."
                    HASH_ALGO=b3; HASH_CMD=b3sum
                else
                    warn "ni b2sum ni b3sum disponibles; se usa sha256."
                    HASH_ALGO=sha256; HASH_CMD=sha256sum
                fi ;;
        b3)     if have b3sum; then HASH_CMD=b3sum
                else warn "b3sum no disponible; se usa sha256."; HASH_ALGO=sha256; HASH_CMD=sha256sum; fi ;;
        sha256) HASH_CMD=sha256sum
                have b2sum && [[ "$INTEGRITY" != standard ]] \
                    && say "  $(printf '%-10s' hash) ${C_B}i${C_OFF}  b2sum disponible: --hash b2 es ~3x mas rapido con la misma garantia" ;;
        md5)    if have md5sum; then HASH_CMD=md5sum
                    warn "hash=md5: mas rapido, pero NO es resistente a colisiones. Sirve para detectar corrupcion accidental, no manipulacion."
                else warn "md5sum no disponible; se usara sha256."; HASH_ALGO=sha256; HASH_CMD=sha256sum; fi ;;
    esac
    # Capabilities only. Which verifier actually runs is decided per dataset,
    # once its acltype is known -- see acl_verifier_for.
    probe_acl_capabilities
    say ""
    say "  VERIFICACION DE ACL / XATTR (capacidades de este host)"
    say "  $( (( CAP_NFS4 ))  && printf '[OK]' || printf '[--]') acltype=nfsv4  -> nfs4xdr_getfacl + jq"
    say "  $( (( CAP_POSIX )) && printf '[OK]' || printf '[--]') acltype=posix  -> getfacl + getfattr"
    say "  $( (( CAP_XATTR )) && printf '[OK]' || printf '[--]') acltype=off    -> getfattr"
    if (( CAP_NFS4 == 0 && CAP_POSIX == 0 && CAP_XATTR == 0 )); then
        die "$EX_DEP_MISSING" "Este host no puede verificar ACL ni xattr de ninguna forma. No se modifico nada."
    fi

    detect_browser
    say ""
    say "  DIRECTORY BROWSER"
    say "  [OK] selector Bash integrado    siempre disponible"
    for c in whiptail dialog fzf; do
        if have "$c"; then say "  [OK] $(printf '%-24s' "$c") opcional / instalado"
        else say "  [--] $(printf '%-24s' "$c") opcional / no instalado"; fi
    done
    say "  Se usara: $BROWSER"
    say "=============================================================="
    say "  Resultado: READY   (verificador por dataset, segun su acltype)"
    say "=============================================================="
    return 0
}

# -----------------------------------------------------------------------------
# [7] Dataset resolution. Longest-prefix over `zfs list` rather than df: finds
#     the most specific child dataset and does not depend on df's formatting.
# -----------------------------------------------------------------------------
resolve_dir() {
    local in="${1-}"
    [[ -n "$in" ]] || return 1
    if have realpath;   then TARGET_DIR="$(realpath -- "$in" 2>/dev/null)" || return 1
    elif have readlink; then TARGET_DIR="$(readlink -f -- "$in" 2>/dev/null)" || return 1
    else TARGET_DIR="$(cd -- "$in" 2>/dev/null && pwd -P)" || return 1; fi
    [[ -d "$TARGET_DIR" ]]
}

discover_dataset() {
    local ds mp
    ZFS_DATASET="" ZFS_MOUNT=""
    while IFS=$'\t' read -r ds mp; do
        case "$mp" in -|legacy|none) continue ;; esac
        if [[ "$TARGET_DIR" == "$mp" || "$TARGET_DIR" == "$mp/"* ]]; then
            [[ -z "$ZFS_MOUNT" || ${#mp} -gt ${#ZFS_MOUNT} ]] && { ZFS_DATASET="$ds"; ZFS_MOUNT="$mp"; }
        fi
    done < <(zfs list -H -o name,mountpoint 2>/dev/null)
    [[ -n "$ZFS_DATASET" ]]
}

dataset_recordsize() { zfs get -H -o value recordsize "$1" 2>/dev/null; }

# Advisory only: a USB-attached disk (especially a lone one, no mirror/raidz)
# tends to have a much lower sustained-write ceiling than an internal disk of
# the same size, and the governor has no way to know that in advance -- it
# only finds the real ceiling by throttling into it. Confirmed live: on a
# single-USB-disk pool, BW kept overshooting into CRITICAL every file until it
# settled near the disk's real ~10-15MB/s limit, several files in. Telling the
# operator this up front, so --bw-max can start near the real number instead
# of being discovered by trial and error, doesn't touch the hash, the commit
# path or the governor itself -- those stay exactly as strict as they are.
usb_advisory() {
    local pool="${ZFS_DATASET%%/*}" dev name parent sysfs
    have lsblk || return 0
    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        name="${dev#/dev/}"
        parent="$(lsblk -no pkname -- "$dev" 2>/dev/null | head -1)"
        parent="${parent:-$name}"
        sysfs="$(readlink -f -- "/sys/class/block/$parent/device" 2>/dev/null)"
        if [[ "$sysfs" == */usb*/* ]]; then
            warn "El dataset '$ZFS_DATASET' vive en el pool '$pool', respaldado por un disco USB ($parent). Un disco USB, sobre todo si es unico y sin mirror/raidz, suele tener un techo de escritura sostenida bien por debajo de lo que sugiere su velocidad nominal -- considera medirlo con --dry-run --dry-sample y fijar --bwlimit/--bw-max cerca de ese numero, en vez de dejar que el governor lo descubra probando y retrocediendo."
            return 0
        fi
    done < <(zpool status -PL "$pool" 2>/dev/null | awk '/\/dev\// {print $1}')
    return 0
}

# -----------------------------------------------------------------------------
# Dataset map.
#
# A path like /mnt/toolbox is not one filesystem. Underneath it there can be
# child datasets, other pools, non-ZFS mounts and .zfs snapshot directories,
# each with its own recordsize and its own free space. Treating the whole tree
# as "the dataset of the top directory" would mean checking the wrong
# recordsize and the wrong free space for most of the files, which is a design
# fault on our side, not an operator mistake.
#
# So the map is built once and every file is resolved against it individually.
# DS_MOUNT/DS_NAME/DS_RS are parallel arrays sorted by mountpoint length
# descending, which makes the first prefix match the longest one.
# -----------------------------------------------------------------------------
DS_MOUNT=() DS_NAME=() DS_RS=() DS_ACL=()

# acltype comes from the same query as recordsize: it is a property of the
# dataset, so asking once per dataset here replaces a `zfs get` per file.
map_datasets() {
    local ds mp rs at
    DS_MOUNT=() DS_NAME=() DS_RS=() DS_ACL=()
    while IFS=$'\t' read -r mp ds rs at; do
        [[ -n "$mp" ]] || continue
        DS_MOUNT+=("$mp"); DS_NAME+=("$ds"); DS_RS+=("$rs"); DS_ACL+=("$at")
    done < <(
        zfs list -H -o mountpoint,name,recordsize,acltype 2>/dev/null \
        | awk -F'\t' '$1 != "-" && $1 != "legacy" && $1 != "none" { print length($1) "\t" $0 }' \
        | sort -rn | cut -f2-
    )
    (( ${#DS_MOUNT[@]} )) || return 1
    return 0
}

# Longest-prefix lookup. Fills DS_HIT_NAME / DS_HIT_RS / DS_HIT_MOUNT.
dataset_for() {
    local p="$1" i
    DS_HIT_NAME="" DS_HIT_RS="" DS_HIT_MOUNT="" DS_HIT_ACL=""
    for (( i=0; i<${#DS_MOUNT[@]}; i++ )); do
        if [[ "$p" == "${DS_MOUNT[$i]}" || "$p" == "${DS_MOUNT[$i]}/"* ]]; then
            DS_HIT_MOUNT="${DS_MOUNT[$i]}"; DS_HIT_NAME="${DS_NAME[$i]}"
            DS_HIT_RS="${DS_RS[$i]}"; DS_HIT_ACL="${DS_ACL[$i]}"
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Capabilities, dataset policy, effective verifier.
#
# Three separate questions that used to be collapsed into one global
# ACL_METHOD, which is why the preflight could report READY and every file
# still fail:
#
#   CAPABILITIES       what this host can do        -> probed once, in preflight
#   DATASET POLICY     what each dataset requires   -> acltype, from the map
#   EFFECTIVE VERIFIER what ran for THIS file       -> policy x capabilities
#
# A dataset whose policy has no matching capability is refused before any data
# is touched, instead of failing once per file after a full copy and hash.
# -----------------------------------------------------------------------------
CAP_NFS4=0 CAP_POSIX=0 CAP_XATTR=0

probe_acl_capabilities() {
    CAP_NFS4=0 CAP_POSIX=0 CAP_XATTR=0
    have nfs4xdr_getfacl && have jq && CAP_NFS4=1
    have getfacl && have getfattr && CAP_POSIX=1
    have getfattr && CAP_XATTR=1
    return 0
}

# Maps a dataset acltype to the verifier that can actually check it here.
# Echoes the verifier name, or nothing when this host cannot verify that
# policy -- the caller decides, and the answer is always the same one whether
# it is asked by --check, --dry-run, --explain or the run itself.
acl_verifier_for() {
    case "${1:-}" in
        nfsv4)          (( CAP_NFS4 ))  && printf 'nfs4xdr+jq\n' ;;
        posix|posixacl) (( CAP_POSIX )) && printf 'getfacl+getfattr\n' ;;
        off)            (( CAP_XATTR )) && printf 'getfattr\n' ;;   # no ACLs: xattrs are the whole story
        *)              : ;;                                        # unknown policy: fail closed
    esac
    return 0
}

# Human-readable reason a policy cannot be served, for messages that name the
# missing tool instead of a stale global label.
acl_missing_for() {
    case "${1:-}" in
        nfsv4)          printf 'faltan nfs4xdr_getfacl y/o jq\n' ;;
        posix|posixacl) printf 'faltan getfacl y/o getfattr\n' ;;
        off)            printf 'falta getfattr\n' ;;
        '')             printf 'el dataset no reporta acltype\n' ;;
        *)              printf 'acltype no soportado por este worker\n' ;;
    esac
}

# Surveys every dataset the target tree spans and answers, before a single
# byte is touched, the two questions that can make a whole subtree unusable:
# does its recordsize match, and can this host verify its ACL policy.
#
# The target's own dataset is always part of the survey even when no dataset is
# mounted *under* TARGET_DIR -- pointing the worker at a plain subdirectory is
# the common case, and it used to report zero datasets in the tree.
#
# Returns 1 when not one dataset in the tree is verifiable, so callers can stop
# before copying and hashing files that could never pass the ACL check.
survey_tree() {
    local i mp count=0 ok=0 bad=0 aok=0 abad=0 names=() seen_target=0
    for (( i=0; i<${#DS_MOUNT[@]}; i++ )); do
        mp="${DS_MOUNT[$i]}"
        if [[ "$mp" == "$TARGET_DIR" || "$mp" == "$TARGET_DIR/"* ]]; then :
        elif [[ "${DS_NAME[$i]}" == "$ZFS_DATASET" ]] && (( ! seen_target )); then seen_target=1
        else continue; fi
        count=$((count+1)); names+=("${DS_NAME[$i]}|${DS_RS[$i]}|${DS_ACL[$i]}|$mp")
        [[ "${DS_RS[$i]}" == "$EXPECTED_RECORDSIZE" ]] && ok=$((ok+1)) || bad=$((bad+1))
        [[ -n "$(acl_verifier_for "${DS_ACL[$i]}")" ]] && aok=$((aok+1)) || abad=$((abad+1))
    done
    TREE_DATASETS="$count" TREE_RS_OK="$ok" TREE_RS_BAD="$bad"
    TREE_ACL_OK="$aok" TREE_ACL_BAD="$abad" TREE_ACL_REPORT=""

    # Separate assignments on purpose: bash expands every word of a `local`
    # command before assigning any of them, so "local a=x b=${a}" sees an unset a.
    local n dn rest drs dacl dmp v verdict
    for n in "${names[@]}"; do
        dn="${n%%|*}"; rest="${n#*|}"
        drs="${rest%%|*}"; rest="${rest#*|}"
        dacl="${rest%%|*}"; dmp="${rest#*|}"
        v="$(acl_verifier_for "$dacl")"
        if [[ "$drs" != "$EXPECTED_RECORDSIZE" ]]; then verdict="OMITE (recordsize=$drs)"
        elif [[ -z "$v" ]]; then verdict="OMITE ($(acl_missing_for "$dacl"))"
        else verdict="OK"; fi
        TREE_ACL_REPORT+="${TREE_ACL_REPORT:+, }${dn}:${dacl:-?}"
        log "$(printf '[DATASET]   %-34s %-26s recordsize=%-6s acltype=%-8s verificador=%-18s %s' \
            "$verdict" "$dn" "$drs" "${dacl:-<vacio>}" "${v:-<ninguno>}" "$dmp")"
    done

    (( count > 1 )) && log "[DATASET] El arbol abarca $count datasets ($ok con recordsize=$EXPECTED_RECORDSIZE, $bad con otro; $aok verificables, $abad no)."
    (( bad ))  && warn "$bad dataset(s) bajo '$TARGET_DIR' tienen otro recordsize; sus archivos se omitiran ($CROSS_DATASET)."
    (( abad )) && warn "$abad dataset(s) bajo '$TARGET_DIR' usan un acltype que este host no puede verificar; sus archivos se omitiran."
    if (( count > 0 && aok == 0 )); then
        err "Ningun dataset del arbol tiene un verificador de ACL/xattr disponible en este host ($TREE_ACL_REPORT)."
        err "Instalar las herramientas que falten antes de continuar; no se copio ni se modifico ningun archivo."
        return 1
    fi
    return 0
}

# Per-file gate. Returns 0 when the file may be processed, 1 when it must be
# skipped, and fills FILE_DS / FILE_DS_RS / DS_SKIP_WHY.
file_dataset_ok() {
    local f="$1"
    FILE_DS="" FILE_DS_RS="" FILE_DS_ACL="" FILE_VERIFIER="" DS_SKIP_WHY=""
    # Snapshot directories are read-only and must never be walked into.
    case "$f" in */.zfs/*) DS_SKIP_WHY="dentro de .zfs (snapshots)"; return 1 ;; esac
    if ! dataset_for "$f"; then
        DS_SKIP_WHY="no pertenece a ningun dataset ZFS montado"
        return 1
    fi
    FILE_DS="$DS_HIT_NAME"; FILE_DS_RS="$DS_HIT_RS"; FILE_DS_ACL="$DS_HIT_ACL"
    if [[ "$FILE_DS" != "$ZFS_DATASET" ]]; then
        case "$CROSS_DATASET" in
            stop)    DS_SKIP_WHY="pertenece a otro dataset ($FILE_DS) y --cross-dataset=stop"; ENV_ABORT=1; return 1 ;;
            skip)    DS_SKIP_WHY="pertenece a otro dataset ($FILE_DS)"; return 1 ;;
            process) : ;;   # allowed, but the checks below still apply
        esac
    fi
    if [[ "$FILE_DS_RS" != "$EXPECTED_RECORDSIZE" ]]; then
        DS_SKIP_WHY="su dataset $FILE_DS tiene recordsize=$FILE_DS_RS (se esperaba $EXPECTED_RECORDSIZE)"
        return 1
    fi
    # The guarantee has to be provable BEFORE the file is copied and hashed.
    # Deciding it here means the inventory, the dry-run and the run all reach
    # the same verdict, and a file we cannot verify never costs a copy.
    FILE_VERIFIER="$(acl_verifier_for "$FILE_DS_ACL")"
    if [[ -z "$FILE_VERIFIER" ]]; then
        DS_SKIP_WHY="su dataset $FILE_DS usa acltype=${FILE_DS_ACL:-<vacio>} y $(acl_missing_for "$FILE_DS_ACL")"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# [8] Job lifecycle.
# -----------------------------------------------------------------------------
# Timestamp + nanoseconds + PID + hash(path, recordsize, threshold).
make_job_id() {
    local key ns
    key="$(printf '%s\0%s\0%s' "$TARGET_DIR" "$EXPECTED_RECORDSIZE" "$THRESHOLD_BYTES" | sha256sum | cut -c1-10)"
    ns="$(date '+%N' 2>/dev/null)"; [[ "$ns" =~ ^[0-9]+$ ]] || ns="000000"
    printf 'ZRW-%s-%s-%s-%s\n' "$(date '+%Y%m%d-%H%M%S')" "${ns:0:6}" "$$" "$key"
}

short_of() { printf '%s' "$1" | sha256sum | cut -c1-10; }

init_job() {
    JOB_DIR="$STATE_ROOT/$JOB_ID"; JOB_SHORT="$(short_of "$JOB_ID")"
    mkdir -p -- "$JOB_DIR"/{state,anchors,quarantine,workers} \
        || die "$EX_INTERNAL" "No se pudo crear $JOB_DIR"
    INVENTORY="$JOB_DIR/inventory.tsv"; STATE_DIR="$JOB_DIR/state"
    ANCHOR_DIR="$JOB_DIR/anchors";     EVENT_LOG="$JOB_DIR/events.log"
    JOURNAL="$JOB_DIR/journal.tsv";    SUMMARY_TSV="$JOB_DIR/summary.tsv"
    SUMMARY_JSON="$JOB_DIR/summary.json"; CONFIG_FILE="$JOB_DIR/config.env"
    LOCK_FILE="$JOB_DIR/job.lock";     CONTROL_FILE="$JOB_DIR/control"
    RESULTS_FILE="$JOB_DIR/results.tsv"; STATE_LOCK="$JOB_DIR/state.lock"
    PID_FILE="$JOB_DIR/job.pid"
    touch "$EVENT_LOG" "$JOURNAL" "$RESULTS_FILE" "$STATE_LOCK"
    [[ -s "$JOURNAL" ]] || printf 'timestamp\tstate\tinode\tsize\tresult\tpath\n' >"$JOURNAL"
    chmod 700 "$JOB_DIR" "$STATE_DIR" "$ANCHOR_DIR" "$JOB_DIR/quarantine" 2>/dev/null
    chmod 600 "$EVENT_LOG" "$JOURNAL" 2>/dev/null
    return 0
}

# The lock is informative: it says who holds it, and never kills them.
lock_job() {
    exec 200>"$LOCK_FILE" || die "$EX_INTERNAL" "No se pudo abrir el lock."
    if ! flock -n 200; then
        local pid="?" since="?" tgt="?"
        [[ -f "$PID_FILE" ]] && { read -r pid since tgt <"$PID_FILE" || true; }
        err "El job $JOB_ID ya esta en ejecucion."
        err "  PID    : $pid"
        err "  Inicio : $since"
        err "  Target : $tgt"
        err "No se intentara matar la instancia existente. Revisa: tmux ls / ps -fp $pid"
        exit "$EX_LOCKED"
    fi
    printf '%s %s %s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "$TARGET_DIR" >"$PID_FILE"
}

# A pointer to the active job, so `--resume` and the wizard do not depend on
# the operator remembering a job id.
set_current_job() { mkdir -p -- "$RUNTIME_DIR" 2>/dev/null; printf '%s\n' "$JOB_ID" >"$RUNTIME_DIR/current" 2>/dev/null; return 0; }
get_current_job() { [[ -r "$RUNTIME_DIR/current" ]] && head -n1 "$RUNTIME_DIR/current"; }

save_config() {
    # JOB_VERSION, not VERSION: load_config() below does a plain `source` of
    # this file, and a field literally named VERSION would clobber the live
    # constant on every --resume with whatever version created the job --
    # confirmed live: a job created under 4.4.7 and resumed under 4.4.8 kept
    # showing "v4.4.7" in the dashboard, --status and every log line, despite
    # actually running the newer code. JOB_VERSION keeps that historical
    # record (which version this job started under) without touching the
    # live $VERSION the running binary reports.
    { printf 'JOB_VERSION=%s\n' "$VERSION"
      local k
      for k in JOB_ID TARGET_DIR ZFS_DATASET ZFS_MOUNT EXPECTED_RECORDSIZE \
               BW_TARGET BW_MIN BW_MAX ADAPTIVE INTEGRITY PROFILE COOLDOWN_MODE \
               ADAPTIVE_PRIORITY; do
          printf '%s=%q\n' "$k" "${!k}"
      done
      for k in THRESHOLD_BYTES NICE_VALUE IONICE_CLASS NICE_MIN IONICE_MIN \
               COOLDOWN HEALTH_INTERVAL MARGIN_PCT MARGIN_MIN RETRIES WORKERS; do
          printf '%s=%s\n' "$k" "${!k}"
      done
    } >"$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null; return 0
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    # Written by this worker inside a mode-700 job directory. A plain `source`
    # here used to blindly overwrite every field, including ones the operator
    # just set on THIS invocation's command line -- confirmed live: `--resume
    # --adaptive off` kept throttling anyway, because load_config re-applied
    # the job's original ADAPTIVE=auto right after parse_args had already set
    # it to off. Skipping any key present in CLI_SET makes a flag typed on a
    # resume actually take effect, while an operator who passes nothing still
    # gets the job's saved settings exactly as before.
    local line key
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        [[ -n "${CLI_SET[$key]:-}" ]] && continue
        eval "$line"
    done < "$CONFIG_FILE"
    return 0
}

# Control file: the supervisor publishes live parameters, workers read them
# before each file. This is what lets runtime changes reach parallel workers.
publish_control() {
    local t="$CONTROL_FILE.tmp.$$"
    printf 'BW_BPS=%s\nNICE_VALUE=%s\nIONICE_CLASS=%s\nCOOLDOWN=%s\nPAUSE_REQ=%s\nEXIT_REQ=%s\n' \
        "$BW_BPS" "$NICE_VALUE" "$IONICE_CLASS" "$COOLDOWN" "$PAUSE_REQ" "$EXIT_REQ" >"$t"
    mv -f -- "$t" "$CONTROL_FILE"; return 0
}

read_control() {
    [[ -f "$CONTROL_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONTROL_FILE" 2>/dev/null || true
    return 0
}

# -----------------------------------------------------------------------------
# [9] Inventory. find -print0 plus printf %q is what actually makes newlines,
#     tabs, quotes and globs in filenames safe. Published atomically so a power
#     cut during the scan cannot leave a truncated snapshot.
# -----------------------------------------------------------------------------
# find is told to prune .zfs itself (cheaper and safer than filtering after the
# fact) and, with --one-dataset, to stay on the target's own filesystem.
scan_tree() {
    local -a args=("$TARGET_DIR")
    (( ONE_DATASET )) && args+=(-xdev)
    find "${args[@]}" \( -name .zfs -prune \) -o -type f -print0 2>/dev/null
}

build_inventory() {
    local n=0 f size mtime inode q tmp="$INVENTORY.building.$$" out=0
    log "Construyendo inventario SNAPSHOT (> $(human "$THRESHOLD_BYTES")) en $TARGET_DIR"
    : >"$tmp" || { err "No se pudo escribir $tmp"; return 1; }
    while IFS= read -r -d '' f; do
        size="$(stat -c '%s' -- "$f" 2>/dev/null)" || continue
        (( size > THRESHOLD_BYTES )) || continue
        # A file is a candidate only if ITS dataset is the right one. Doing this
        # at inventory time keeps the counters and the ETA honest.
        if ! file_dataset_ok "$f"; then
            out=$((out+1))
            case "$DS_SKIP_WHY" in
                *"otro dataset"*) R_OTHER_DS=$((R_OTHER_DS+1)) ;;
                *recordsize*)     R_RECORDSIZE=$((R_RECORDSIZE+1)) ;;
            esac
            continue
        fi
        mtime="$(stat -c '%y' -- "$f" 2>/dev/null)" || continue
        inode="$(stat -c '%i' -- "$f" 2>/dev/null)" || continue
        printf -v q '%q' "$f"
        printf '%s\t%s\t%s\t%s\t%s\n' "$size" "$mtime" "$inode" "$FILE_DS" "$q" >>"$tmp"
        n=$((n+1))
    done < <(scan_tree)
    sort -n -o "$tmp" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$INVENTORY" || { err "No se pudo publicar el inventario."; return 1; }
    count_inventory
    (( out )) && log "[DATASET] $out archivo(s) fuera del inventario: $R_OTHER_DS de otro dataset, $R_RECORDSIZE con otro recordsize."
    (( N_TOTAL )) || { log "No se encontraron candidatos."; return 1; }
    log "Inventario congelado: $N_TOTAL candidatos, $(human "$BYTES_PLANNED")."
    return 0
}

count_inventory() {
    local n=0 b=0 line size rest
    N_TOTAL=0 BYTES_PLANNED=0
    [[ -f "$INVENTORY" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n=$((n+1)); IFS=$'\t' read -r size rest <<<"$line"
        is_int "$size" && b=$((b+size))
    done <"$INVENTORY"
    N_TOTAL="$n" BYTES_PLANNED="$b"
}

# Counterpart of printf %q, on data this worker wrote in its own 700 directory.
unq() { eval "QPATH=$1"; }

# -----------------------------------------------------------------------------
# [10] State machine. One file per candidate, fsynced, so the checkpoint
#      survives a power cut. Guarded by flock so parallel workers can claim.
#
#      `sync -f PATH` below is coreutils' --file-system flag, not a per-file
#      fsync: it syncs the whole filesystem that PATH lives on. Broader than
#      strictly needed, but never weaker than what the name suggests.
# -----------------------------------------------------------------------------
state_key() { printf '%s' "$1" | sha256sum | cut -c1-32; }
state_file() { printf '%s/%s.state\n' "$STATE_DIR" "$1"; }

st_lock()   { exec 201>"$STATE_LOCK"; flock -x 201; }
st_unlock() { flock -u 201 2>/dev/null || true; }

save_state() {
    local key="$1" status="$2" att="$3" size="$4" inode="$5" mtime="$6" path="$7"
    local sf q t
    sf="$(state_file "$key")"; t="$sf.tmp.$$"; printf -v q '%q' "$path"
    { printf 'status=%s\nattempt=%s\nsize=%s\ninode=%s\nmtime=%s\npath=%s\nupdated=%s\n' \
        "$status" "$att" "$size" "$inode" "$mtime" "$q" "$(date +%s)"; } >"$t" || return 1
    sync -f "$t" 2>/dev/null || true       # durability of the checkpoint itself
    mv -f -- "$t" "$sf"
}

load_state() {
    local key="$1" sf k v
    ST_STATUS="PENDING" ST_ATTEMPT=0 ST_SIZE="" ST_INODE="" ST_MTIME="" ST_PATH=""
    sf="$(state_file "$key")"; [[ -f "$sf" ]] || return 0
    while IFS='=' read -r k v; do
        case "$k" in
            status) ST_STATUS="$v" ;; attempt) ST_ATTEMPT="$v" ;;
            size) ST_SIZE="$v" ;;   inode) ST_INODE="$v" ;;
            mtime) ST_MTIME="$v" ;; path) unq "$v"; ST_PATH="$QPATH" ;;
        esac
    done <"$sf"
}

journal() {
    local status="$1" path="$2" inode="$3" size="$4" result="$5" q
    [[ -n "$JOURNAL" ]] || return 0
    printf -v q '%q' "$path"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$status" "$inode" "$size" "$result" "$q" >>"$JOURNAL"
    sync -f "$JOURNAL" 2>/dev/null || true
    return 0
}

transition() {
    local key="$1" status="$2" att="$3" size="$4" inode="$5" mtime="$6" path="$7" res="$8"
    (( DRY_RUN )) && return 0
    save_state "$key" "$status" "$att" "$size" "$inode" "$mtime" "$path" \
        || warn "No se pudo persistir state=$status para $path"
    journal "$status" "$path" "$inode" "$size" "$res"
}

# Every inventory entry gets an explicit PENDING record up front, so "pending"
# is a counted fact rather than a subtraction and the journal starts complete.
init_pending() {
    local line size mtime inode ds q key
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -r size mtime inode ds q <<<"$line"; unq "$q"
        key="$(state_key "$QPATH")"
        [[ -f "$(state_file "$key")" ]] || save_state "$key" PENDING 0 "$size" "$inode" "$mtime" "$QPATH"
    done <"$INVENTORY"
    return 0
}

# The checkpoint accelerates; the filesystem decides. A terminal state is only
# honoured while the file still matches what was recorded when it was closed.
state_valid() {
    local f="$1" sz ino
    [[ -f "$f" && -n "$ST_SIZE" && -n "$ST_INODE" ]] || return 1
    sz="$(stat -c '%s' -- "$f" 2>/dev/null)" || return 1
    ino="$(stat -c '%i' -- "$f" 2>/dev/null)" || return 1
    [[ "$sz" == "$ST_SIZE" && "$ino" == "$ST_INODE" ]]
}

# Atomically take ownership of a file. Returns 1 when another worker has it or
# the state is terminal and still valid.
claim_file() {
    local f="$1" key="$2"
    st_lock
    load_state "$key"
    case "$ST_STATUS" in
        PROCESSING|VERIFYING) st_unlock; return 1 ;;   # owned by a live worker
    esac
    save_state "$key" PROCESSING "$ST_ATTEMPT" "${ST_SIZE:-0}" "${ST_INODE:-0}" "${ST_MTIME:-}" "$f"
    st_unlock
    return 0
}

# Workers report results here; the supervisor tallies. One line per outcome.
record_result() {
    printf '%s\t%s\t%s\n' "$1" "${2:-0}" "${3:-}" >>"$RESULTS_FILE"
    return 0
}

# -----------------------------------------------------------------------------
# [11] Metrics. Read straight from /proc: no iostat, sysstat or Prometheus.
#      IFS is set per-read on purpose: /proc lines are space separated and a
#      global IFS without a space silently yields empty fields.
# -----------------------------------------------------------------------------
read_cpu_mem() {
    CPU=0 IOWAIT=0 MEM=0
    [[ -r /proc/loadavg ]] && LOAD1="$(awk '{print $1}' /proc/loadavg)"
    if [[ -r /proc/meminfo ]]; then
        local mt ma arc_kb
        mt="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
        ma="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
        # MemAvailable does not know that ZFS ARC is reclaimable: on Linux, ARC
        # sits outside the normal page cache accounting, so a perfectly healthy
        # ZFS box with ARC near its max target reports MemAvailable as if that
        # memory were pinned. Confirmed live: ARC at ~20GiB/23.5GiB total,
        # MemAvailable showing ~2GiB free -- read as 92% "used" and feeding the
        # health score, even with CPU/iowait/disk all near zero. Credit back
        # whatever ARC could give up down to its own configured floor (c_min);
        # if the stats file is missing (non-ZFS host, exotic install) this is a
        # silent no-op and MEM falls back to the raw MemAvailable reading.
        arc_kb=0
        if [[ -r "$ARCSTATS_FILE" ]]; then
            arc_kb="$(awk '$1=="size"{s=$3} $1=="c_min"{m=$3} END{d=s-m; if(d<0)d=0; printf "%d", d/1024}' \
                "$ARCSTATS_FILE" 2>/dev/null)"
            [[ "$arc_kb" =~ ^[0-9]+$ ]] || arc_kb=0
        fi
        [[ -n "$mt" && -n "$ma" && "$mt" -gt 0 ]] && MEM=$(( 100 - ((ma+arc_kb)*100/mt) ))
        (( MEM < 0 )) && MEM=0
    fi
    [[ -r /proc/stat ]] || return 0
    local a=() b=() t1 t2 dt di
    IFS=' ' read -r -a a < <(awk '/^cpu /{print;exit}' /proc/stat)
    sleep 0.2
    IFS=' ' read -r -a b < <(awk '/^cpu /{print;exit}' /proc/stat)
    (( ${#a[@]} >= 9 && ${#b[@]} >= 9 )) || return 0
    t1=$(( a[1]+a[2]+a[3]+a[4]+a[5]+a[6]+a[7]+a[8] ))
    t2=$(( b[1]+b[2]+b[3]+b[4]+b[5]+b[6]+b[7]+b[8] ))
    dt=$(( t2-t1 )); di=$(( (b[4]+b[5])-(a[4]+a[5]) ))
    (( dt > 0 )) || return 0
    CPU=$(( 100*(dt-di)/dt )); IOWAIT=$(( 100*(b[5]-a[5])/dt ))
    return 0
}

# Storage is the delicate resource for a reblock, so it gets measured directly.
# /proc/diskstats field 10 (io_ticks) is busy-time in ms and field 11
# (weighted_io_ticks) accumulates queue time; together they give utilisation
# and a mean-latency proxy without extra dependencies.
read_disk() {
    DISK_UTIL=0 DISK_WAIT=0
    [[ -r /proc/diskstats ]] || return 0
    local s1 s2 ms=200
    s1="$(disk_snapshot)"; sleep 0.2; s2="$(disk_snapshot)"
    [[ -n "$s1" && -n "$s2" ]] || return 0
    local io1 w1 c1 io2 w2 c2
    IFS=' ' read -r io1 w1 c1 <<<"$s1"
    IFS=' ' read -r io2 w2 c2 <<<"$s2"
    local dio=$(( io2-io1 )) dw=$(( w2-w1 )) dc=$(( c2-c1 ))
    (( dio < 0 )) && dio=0; (( dw < 0 )) && dw=0; (( dc < 0 )) && dc=0
    DISK_UTIL=$(( dio*100/ms )); (( DISK_UTIL > 100 )) && DISK_UTIL=100
    (( dc > 0 )) && DISK_WAIT=$(( dw/dc ))
    return 0
}

# Aggregates whole physical devices only: partitions and zd* would double count.
disk_snapshot() {
    awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$/ {
            io+=$13; w+=$14; c+=$4+$8 } END { printf "%d %d %d", io+0, w+0, c+0 }' /proc/diskstats
}

# Pressure Stall Information. When the kernel exposes it (5.2+, so every
# current TrueNAS), PSI is a better answer than any derived percentage: it says
# what fraction of the last 10 seconds at least one task spent stalled waiting
# for that resource. It is the closest thing to "am I hurting this server".
read_psi() {
    PSI_IO=0 PSI_CPU=0 PSI_MEM=0
    [[ -d /proc/pressure ]] || return 0
    local v
    v="$(awk '/^some/{for(i=2;i<=NF;i++) if ($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i; exit}}' /proc/pressure/io 2>/dev/null)"
    [[ -n "$v" ]] && PSI_IO="$(awk -v x="$v" 'BEGIN{printf "%d", x+0.5}')"
    v="$(awk '/^some/{for(i=2;i<=NF;i++) if ($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i; exit}}' /proc/pressure/cpu 2>/dev/null)"
    [[ -n "$v" ]] && PSI_CPU="$(awk -v x="$v" 'BEGIN{printf "%d", x+0.5}')"
    v="$(awk '/^some/{for(i=2;i<=NF;i++) if ($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i; exit}}' /proc/pressure/memory 2>/dev/null)"
    [[ -n "$v" ]] && PSI_MEM="$(awk -v x="$v" 'BEGIN{printf "%d", x+0.5}')"
    return 0
}

# Swap activity is a late but unambiguous sign that the box is in trouble.
read_swap() {
    SWAP_USED=0
    [[ -r /proc/meminfo ]] || return 0
    local st sf
    st="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"; sf="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)"
    [[ -n "$st" && -n "$sf" && "$st" -gt 0 ]] && SWAP_USED=$(( 100-(sf*100/st) ))
    return 0
}

cpu_count() {
    local n=1
    [[ -r /proc/cpuinfo ]] && n="$(awk '/^processor[[:space:]]*:/{c++} END{print c+0}' /proc/cpuinfo)"
    (( n<1 )) && n=1; printf '%s\n' "$n"
}

# -----------------------------------------------------------------------------
# [12] Adaptive Resource Governor.
#      Pressure is scored, not thresholded: storage outranks CPU, and deviation
#      from the startup baseline counts as much as absolute numbers, because the
#      question is "how much am I disturbing this server", not "is CPU at 80%".
# -----------------------------------------------------------------------------
health_sample() {
    read_cpu_mem; read_disk; read_psi; read_swap
    local cpus ratio p=0
    cpus="$(cpu_count)"
    ratio="$(awk -v l="$LOAD1" -v c="$cpus" 'BEGIN{if(c<1)c=1;printf "%.0f",(l/c)*100}')"

    # Storage first: utilisation, then latency, then iowait.
    (( DISK_UTIL >= 90 )) && p=$((p+5)); (( DISK_UTIL >= 70 && DISK_UTIL < 90 )) && p=$((p+3))
    (( DISK_UTIL >= 50 && DISK_UTIL < 70 )) && p=$((p+1))
    (( DISK_WAIT >= 50 )) && p=$((p+4)); (( DISK_WAIT >= 20 && DISK_WAIT < 50 )) && p=$((p+2))
    (( IOWAIT >= 20 )) && p=$((p+4)); (( IOWAIT >= 10 && IOWAIT < 20 )) && p=$((p+2))
    (( CPU >= 85 )) && p=$((p+3)); (( CPU >= 70 && CPU < 85 )) && p=$((p+1))
    (( ratio >= 100 )) && p=$((p+2)); (( ratio >= 80 && ratio < 100 )) && p=$((p+1))
    (( MEM >= 95 )) && p=$((p+3)); (( MEM >= 90 && MEM < 95 )) && p=$((p+1))
    # PSI is a direct stall measurement, so it is weighted like storage.
    (( PSI_IO >= 40 )) && p=$((p+5)); (( PSI_IO >= 20 && PSI_IO < 40 )) && p=$((p+3))
    (( PSI_IO >= 10 && PSI_IO < 20 )) && p=$((p+1))
    (( PSI_CPU >= 40 )) && p=$((p+2)); (( PSI_MEM >= 20 )) && p=$((p+3))
    (( SWAP_USED >= 25 )) && p=$((p+2))

    # Baseline deviation.
    [[ "$BASE_LOAD" != 0 ]] && awk -v l="$LOAD1" -v b="$BASE_LOAD" 'BEGIN{exit !(b>0 && l>b*1.5)}' && p=$((p+2))
    (( BASE_IOWAIT > 0 && IOWAIT > BASE_IOWAIT+10 )) && p=$((p+2))
    (( BASE_DISK   > 0 && DISK_UTIL > BASE_DISK+25 )) && p=$((p+2))
    (( BASE_MEM    > 0 && MEM > BASE_MEM+5 )) && p=$((p+1))
    (( BASE_PSI    > 0 && PSI_IO > BASE_PSI+15 )) && p=$((p+2))

    # "Goodput" credit, the same idea TCP BBR and adaptive-concurrency
    # limiters use to tell "busy and productive" from "busy and stuck":
    # %util/PSI alone cannot make that call, because a disk at 100% delivering
    # real bytes looks identical to one that is 100% and going nowhere.
    # Confirmed live: an isolated fio write saturated this same single USB
    # disk at 150+ MiB/s real, sustained throughput, and still scored
    # EMERGENCY the whole time on %util/PSI alone. If the file actually being
    # copied right now is moving at least BW_MIN worth of real bytes/sec,
    # credit that back -- a few seconds in, so it never masks a copy that
    # never got moving. This only ever makes the score LESS severe; it can't
    # invent pressure that other signals didn't already see.
    GOODPUT_BPS=0
    if (( CUR_START > 0 )); then
        local el2; el2=$(( $(date +%s) - CUR_START ))
        if (( el2 >= 5 )); then
            GOODPUT_BPS=$(( CUR_DONE/el2 ))
            (( GOODPUT_BPS >= $(to_bytes "$BW_MIN") )) && { (( p >= 3 )) && p=$((p-3)) || p=0; }
        fi
    fi

    HEALTH_SCORE="$p"
    if   (( p >= 11 )); then HEALTH=EMERGENCY; HEALTH_WHY="riesgo operativo: presion extrema sostenida"
    elif (( p >= 7  )); then HEALTH=CRITICAL;  HEALTH_WHY="presion critica de almacenamiento/CPU/memoria"
    elif (( p >= 4  )); then HEALTH=PRESSURE;  HEALTH_WHY="presion elevada de recursos"
    elif (( p >= 2  )); then HEALTH=BUSY;      HEALTH_WHY="servidor ocupado; sin aumento automatico"
    else                     HEALTH=HEALTHY;   HEALTH_WHY="dentro del envelope operativo"
    fi
    return 0
}

# Baseline also proposes a starting bandwidth, instead of always assuming 35M.
suggest_initial_bw() {
    local t="$1" lo hi
    lo="$(to_bytes "$BW_MIN")"; hi="$(to_bytes "$BW_MAX")"
    case "$HEALTH" in
        HEALTHY)            t=$(( t*130/100 )) ;;
        BUSY)               : ;;
        PRESSURE)           t=$(( t*70/100 )) ;;
        CRITICAL|EMERGENCY) t=$(( t*50/100 )) ;;
    esac
    (( t < lo )) && t="$lo"; (( t > hi )) && t="$hi"
    printf '%s\n' "$t"
}

# Operator authority: a manual bandwidth is an absolute ceiling. AUTO may go
# below it for safety and may never go above it until authority is returned.
governor_step() {
    local now lo hi step new
    now="$(date +%s)"
    health_sample
    # Measuring always, and only skipping ACTION for adaptive=off, is
    # deliberate: with the gate before health_sample(), the dashboard's
    # SERVIDOR panel froze at UNKNOWN/0 the instant an operator chose
    # `--adaptive off` -- not because the server was fine, but because the
    # worker had stopped looking. `--adaptive off` still means exactly what
    # it always meant (no automatic THROTTLE/INCREASE/protective pause,
    # operator authority absolute) -- this only restores visibility into
    # what the disk is actually doing while that choice is in effect.
    [[ "$ADAPTIVE" != off ]] || return 0
    AUTO_NEXT=$(( AUTO_UNTIL > now ? AUTO_UNTIL-now : HEALTH_INTERVAL ))

    if [[ "$HEALTH" == EMERGENCY || "$HEALTH" == CRITICAL ]]; then CRIT_COUNT=$((CRIT_COUNT+1)); LAST_CRIT_TS="$now"; else CRIT_COUNT=0; fi
    if (( CRIT_COUNT >= EMERGENCY_SAMPLES && ! AUTO_PAUSED )); then
        AUTO_PAUSED=1
        log "[AUTO] PAUSA PROTECTIVA: $HEALTH sostenido. No se iniciaran nuevos archivos."
        journal "GOVERNOR" "$TARGET_DIR" 0 0 "protective_pause health=$HEALTH score=$HEALTH_SCORE"
        if (( AUTO_RESUME_PRESSURE )); then
            # Opt-in only. An operator [P]/[Q] during the wait still wins
            # immediately below; this never overrides a real stop request.
            local wait_start good_count=0 prev_status="$CUR_STATUS"
            wait_start="$(date +%s)"
            CUR_STATUS="pausado: esperando que baje la presion (auto-resume)"
            log "[AUTO] --auto-resume activo: esperando hasta ${PAUSE_TIMEOUT_MIN}m a que la presion baje, en vez de salir."
            while :; do
                if (( WORKER_ID == 0 )); then poll_keys; else read_control; fi
                (( PAUSE_REQ || EXIT_REQ )) && break
                dashboard; sleep "$HEALTH_INTERVAL"
                health_sample
                if [[ "$HEALTH" == EMERGENCY || "$HEALTH" == CRITICAL ]]; then good_count=0
                else good_count=$((good_count+1)); fi
                if (( good_count >= EMERGENCY_SAMPLES )); then
                    AUTO_PAUSED=0; CRIT_COUNT=0
                    log "[AUTO] Presion liberada ($HEALTH sostenido); se reanuda solo, sin --resume."
                    journal "GOVERNOR" "$TARGET_DIR" 0 0 "auto_resume health=$HEALTH score=$HEALTH_SCORE"
                    break
                fi
                if (( $(date +%s) - wait_start >= PAUSE_TIMEOUT_MIN*60 )); then
                    PAUSE_REQ=1
                    log "[AUTO] --pause-timeout (${PAUSE_TIMEOUT_MIN}m) agotado sin que la presion bajara; se sale como siempre."
                    journal "GOVERNOR" "$TARGET_DIR" 0 0 "auto_resume_timeout health=$HEALTH score=$HEALTH_SCORE"
                    break
                fi
            done
            CUR_STATUS="$prev_status"
        else
            PAUSE_REQ=1
        fi
    fi
    adapt_priority
    (( now < AUTO_UNTIL )) && return 0

    lo="$(to_bytes "$BW_MIN")" || return 0
    hi="$(to_bytes "$BW_MAX")" || return 0
    step=$(( BW_BPS/5 )); (( step < 1048576 )) && step=1048576

    case "$HEALTH" in
        EMERGENCY|CRITICAL|PRESSURE)
            new=$(( BW_BPS-step )); (( new < lo )) && new="$lo"
            if (( new < BW_BPS )); then
                log "[AUTO] THROTTLE $(bw_label "$BW_BPS") -> $(bw_label "$new") ($HEALTH_WHY)"
                journal "GOVERNOR" "$TARGET_DIR" 0 0 "throttle from=$BW_BPS to=$new health=$HEALTH"
                BW_BPS="$new"; AUTO_ACTION=THROTTLE; AUTO_WHY="$HEALTH_WHY"
                AUTO_UNTIL=$(( now+HEALTH_INTERVAL*2 ))
            fi ;;
        BUSY) AUTO_ACTION=HOLD; AUTO_WHY="$HEALTH_WHY" ;;
        HEALTHY)
            if [[ "$ADAPTIVE" == guarded ]]; then
                AUTO_ACTION=HOLD; AUTO_WHY="GUARDED: sin aumento automatico"; return 0
            fi
            # Anti-flapping: ZFS syncs dirty data on a ~5s timer (zfs_txg_timeout),
            # and on a single slow disk that sync is bursty enough to look like a
            # spike of real pressure every cycle (the well known "picket fence"
            # pattern). Confirmed live: a HEALTHY reading right after a protective
            # pause resolved was immediately followed by INCREASE, which promptly
            # overshot into the next txg burst and re-triggered CRITICAL -- pause,
            # resume, increase, pause again, every file. Holding off on INCREASE
            # for a few health cycles after the last CRITICAL/EMERGENCY sample
            # lets a couple of sync cycles pass cleanly before trusting "healthy"
            # enough to ask for more; THROTTLE and the protective pause itself are
            # untouched, so real danger still reacts immediately.
            if (( LAST_CRIT_TS > 0 && now - LAST_CRIT_TS < HEALTH_INTERVAL*3 )); then
                AUTO_ACTION=HOLD; AUTO_WHY="enfriamiento tras presion reciente"
                return 0
            fi
            new=$(( BW_BPS+step )); (( new > hi )) && new="$hi"
            if (( BW_MANUAL && new > BW_CEIL_BPS )); then
                new="$BW_CEIL_BPS"; AUTO_WHY="bloqueado por techo manual del operador"
                journal "GOVERNOR" "$TARGET_DIR" 0 0 "blocked_by_operator ceiling=$BW_CEIL_BPS"
            fi
            if (( new > BW_BPS )); then
                log "[AUTO] INCREASE $(bw_label "$BW_BPS") -> $(bw_label "$new") (servidor saludable)"
                BW_BPS="$new"; AUTO_ACTION=INCREASE; AUTO_WHY="servidor saludable"
                AUTO_UNTIL=$(( now+HEALTH_INTERVAL*2 ))
            fi ;;
    esac
    return 0
}

# Adaptive priority, opt-in. The operator's nice/ionice remain the aggressive
# bound: AUTO may make the worker gentler than configured, and may only return
# toward the configured value, never past it.
adapt_priority() {
    [[ "$ADAPTIVE_PRIORITY" == on ]] || return 0
    local want_nice="$NICE_VALUE" want_io="$IONICE_CLASS"
    case "$HEALTH" in
        HEALTHY)            want_nice="$NICE_MIN"; want_io="$IONICE_MIN" ;;
        BUSY)               want_nice=$(( (NICE_MIN+19)/2 )); want_io="$IONICE_CLASS" ;;
        PRESSURE|CRITICAL|EMERGENCY) want_nice=19; want_io=3 ;;
    esac
    (( want_nice < NICE_MIN )) && want_nice="$NICE_MIN"
    (( want_io   < IONICE_MIN )) && want_io="$IONICE_MIN"
    if [[ "$want_nice" != "$NICE_VALUE" || "$want_io" != "$IONICE_CLASS" ]]; then
        log "[AUTO] Prioridad nice $NICE_VALUE->$want_nice ionice $IONICE_CLASS->$want_io ($HEALTH)"
        NICE_VALUE="$want_nice"; IONICE_CLASS="$want_io"; apply_priority
    fi
    return 0
}

apply_priority() {
    have renice && { renice -n "$NICE_VALUE" -p "$$" >/dev/null 2>&1 || warn "No se pudo aplicar nice=$NICE_VALUE."; }
    have ionice && { ionice -c "$IONICE_CLASS" -p "$$" >/dev/null 2>&1 || warn "No se pudo aplicar ionice=$IONICE_CLASS."; }
    return 0
}

# Adaptive cooldown: same idea applied to the pause between files. 'fixed' is
# the default because it is the V2 behaviour and it is predictable.
adapt_cooldown() {
    [[ "$COOLDOWN_MODE" == adaptive ]] || return 0
    (( COOLDOWN_BASE > 0 )) || COOLDOWN_BASE="$COOLDOWN"
    local n="$COOLDOWN"
    case "$HEALTH" in
        EMERGENCY) n=$(( COOLDOWN_BASE*4 )) ;; CRITICAL) n=$(( COOLDOWN_BASE*3 )) ;;
        PRESSURE)  n=$(( COOLDOWN_BASE*2 )) ;; BUSY) n="$COOLDOWN_BASE" ;;
        HEALTHY)   n=$(( COOLDOWN_BASE/2 )) ;;
    esac
    (( n < 0 )) && n=0
    (( n != COOLDOWN )) && { log "[AUTO] Cooldown ${COOLDOWN}s -> ${n}s ($HEALTH)"; COOLDOWN="$n"; }
    return 0
}

# -----------------------------------------------------------------------------
# [13] UI. The screen must answer, at any moment: where am I, what am I doing,
#      how much is done, how much is left, how fast, is anything wrong.
# -----------------------------------------------------------------------------
bar() {
    local p="${1:-0}" w=26 i out=""
    (( p<0 )) && p=0; (( p>100 )) && p=100
    for (( i=0; i<w; i++ )); do (( i < p*w/100 )) && out+="#" || out+="."; done
    printf '%s' "$out"
}

# Colours a right-padded field without ever breaking alignment: the plain
# text is padded to WIDTH first, and only the already-sized string gets
# wrapped in colour -- so the invisible ANSI bytes never enter a printf
# width calculation (embedding colour codes *inside* a "%-Ns" field is what
# corrupts column alignment; this sidesteps that by never doing that).
# FORCE=1 colours even when VAL is 0 (some fields, like a health state, are
# never "quiet"); default is to render 0 in the plain/dim colour, since an
# all-zero row asking for attention is worse than one that does not.
cfield() {
    local color="$1" width="$2" val="$3" force="${4:-0}" text
    printf -v text '%-*s' "$width" "$val"
    if (( TTY && COLOR )) && { (( force )) || [[ "$val" != 0 ]]; }; then
        printf '%s%s%s' "$color" "$text" "$C_OFF"
    else
        printf '%s' "$text"
    fi
}

# Same idea as paint()'s [TAG] table (kept in one place so the dashboard and
# the log stay in the same colour language), for the one enum the dashboard
# shows outside a log line: HEALTH.
chealth() {
    case "$1" in
        HEALTHY)            printf '%s' "$C_OKB" ;;
        BUSY)                printf '%s' "$C_D" ;;
        PRESSURE)            printf '%s' "$C_WRB" ;;
        CRITICAL|EMERGENCY)  printf '%s' "$C_ERB" ;;
        *)                   printf '%s' "$C_D" ;;   # UNKNOWN, or anything future
    esac
}

avg_speed() {
    local el=$(( $(date +%s)-JOB_START )); (( el<1 )) && { printf '0\n'; return 0; }
    printf '%s\n' $(( BYTES_DONE/el ))
}

push_event() {
    LAST_EVENTS+=("$1")
    while (( ${#LAST_EVENTS[@]} > 5 )); do LAST_EVENTS=("${LAST_EVENTS[@]:1}"); done
}

dashboard() {
    [[ "$UI_MODE" == dash ]] || return 0
    local el sp=0 eta="--:--" fp=0 gp=0 bp=0 jel avg geta="calculando..." rem auth=AUTO ev
    if (( CUR_START > 0 )); then
        el=$(( $(date +%s)-CUR_START ))
        if (( el>0 && CUR_DONE>0 )); then
            sp=$(( CUR_DONE/el )); rem=$(( CUR_SIZE-CUR_DONE )); (( rem<0 )) && rem=0
            (( sp>0 )) && eta="$(printf '%02d:%02d' $(( rem/sp/60 )) $(( (rem/sp)%60 )))"
        fi
    fi
    (( CUR_SIZE>0 )) && fp=$(( CUR_DONE*100/CUR_SIZE ))
    (( N_TOTAL>0 )) && gp=$(( N_INDEX*100/N_TOTAL ))
    (( BYTES_PLANNED>0 )) && bp=$(( BYTES_SEEN*100/BYTES_PLANNED ))
    jel=$(( $(date +%s)-JOB_START )); avg="$(avg_speed)"
    (( avg>0 && BYTES_PLANNED>BYTES_SEEN )) && geta="~ $(hms $(( (BYTES_PLANNED-BYTES_SEEN)/avg )))"
    (( BW_MANUAL )) && auth="$(printf '%sMANUAL%s' "$C_M" "$C_OFF")"

    printf '\033[H\033[2J'
    printf '%s==================================================================%s\n' "$C_B" "$C_OFF"
    printf '  ZFS REBLOCK WORKER v%s      Modo: %s      Workers: %s\n' "$VERSION" "$JOB_MODE" "$WORKERS"
    printf '  Job: %s\n' "$JOB_ID"
    printf '%s==================================================================%s\n' "$C_B" "$C_OFF"
    printf '  Target      %s\n' "$TARGET_DIR"
    printf '  Dataset     %s   recordsize %s   umbral > %s\n' "$ZFS_DATASET" "$RUN_RECORDSIZE" "$(human "$RUN_THRESHOLD")"
    printf '  BW %s (efectivo %s, autoridad %s, %s)  nice %s  I/O %s  cooldown %ss\n' \
        "$BW_TARGET" "$(bw_label "$BW_BPS")" "$auth" "$ADAPTIVE" "$NICE_VALUE" "$IONICE_CLASS" "$COOLDOWN"
    printf '%s------------------------------------------------------------------%s\n' "$C_B" "$C_OFF"
    printf '  Archivos    [%s] %3s%%   %s / %s\n' "$(bar "$gp")" "$gp" "$N_INDEX" "$N_TOTAL"
    printf '  Datos       [%s] %3s%%   %s / %s\n' "$(bar "$bp")" "$bp" "$(human "$BYTES_SEEN")" "$(human "$BYTES_PLANNED")"
    printf '  Reescritos %s Omitidos %s Fallidos %s Stale %s Ausentes %s Pend %s\n' \
        "$(cfield "$C_OKB" 4 "$N_DONE" 1)" "$(cfield "$C_D" 4 "$N_SKIP" 1)" \
        "$(cfield "$C_ERB" 4 "$N_FAIL")" "$(cfield "$C_WRB" 4 "$N_STALE")" \
        "$(cfield "$C_D" 4 "$N_MISS" 1)" "$(( N_TOTAL-N_INDEX ))"
    printf '  Escrito %s   Media %s/s   Transcurrido %s   ETA %s\n' \
        "$(human "$BYTES_DONE")" "$(human "$avg")" "$(hms "$jel")" "$geta"
    printf '%s------------------------------------------------------------------%s\n' "$C_B" "$C_OFF"
    printf '  Actual      %s\n' "${CUR_FILE##*/}"
    local sc=""   # actively working: no colour, it is the common case
    [[ "$CUR_STATUS" == *pausado* || "$CUR_STATUS" == *esperando* ]] && sc="$C_WRB"
    [[ "$CUR_STATUS" == *enfriamiento* ]] && sc="$C_D"   # deliberate, not a problem
    [[ "$CUR_STATUS" == *COMMIT* ]] && sc="$C_C"          # the one irreversible instant
    if [[ -n "$sc" ]]; then printf '  Estado      %s%s%s\n' "$sc" "$CUR_STATUS" "$C_OFF"
    else printf '  Estado      %s\n' "$CUR_STATUS"; fi
    if (( COOLDOWN_LEFT > 0 )); then
        printf '  Cooldown    [%s] %ss\n' "$(bar $(( (COOLDOWN-COOLDOWN_LEFT)*100/(COOLDOWN>0?COOLDOWN:1) )))" "$COOLDOWN_LEFT"
    else
        printf '  [%s] %3s%%  %s / %s  %s/s  ETA %s  intento %s\n' "$(bar "$fp")" "$fp" \
            "$(human "$CUR_DONE")" "$(human "$CUR_SIZE")" "$(human "$sp")" "$eta" "$CUR_ATTEMPT"
    fi
    if (( ${#LAST_EVENTS[@]} )); then
        printf '%s------------------------------------------------------------------%s\n' "$C_B" "$C_OFF"
        printf '  Ultimos completados\n'
        for ev in "${LAST_EVENTS[@]}"; do printf '    %s\n' "$ev"; done
    fi
    printf '%s------------------------------------------------------------------%s\n' "$C_B" "$C_OFF"
    printf '  SERVIDOR %s score %-2s  cpu %3s%%  iowait %3s%%  disco %3s%% (%sms)  mem %3s%%  load %s\n' \
        "$(printf '%s%-9s%s' "$(chealth "$HEALTH")" "$HEALTH" "$C_OFF")" \
        "$HEALTH_SCORE" "$CPU" "$IOWAIT" "$DISK_UTIL" "$DISK_WAIT" "$MEM" "$LOAD1"
    local gc="$C_D"   # HOLD: nothing happening, do not compete for attention
    [[ "$AUTO_ACTION" == THROTTLE ]] && gc="$C_WRB"   # taking bandwidth away
    [[ "$AUTO_ACTION" == INCREASE ]] && gc="$C_OKB"   # giving bandwidth back
    printf '  Governor %s %s   (proxima evaluacion %ss)\n' \
        "$(printf '%s%-9s%s' "$gc" "$AUTO_ACTION" "$C_OFF")" "$AUTO_WHY" "$AUTO_NEXT"
    (( N_WARN )) && printf '  %sAvisos: %s (ver events.log)%s\n' "$C_Y" "$N_WARN" "$C_OFF"
    printf '%s==================================================================%s\n' "$C_B" "$C_OFF"
    printf '  [P] Pausar  [C] Controles  [S] Estado  [Q] Terminar con seguridad\n'
    return 0
}

# Changing bandwidth becomes an informed decision instead of a bare number.
bw_impact() {
    local newbps="$1" rem cur new
    rem=$(( BYTES_PLANNED-BYTES_SEEN )); (( rem<0 )) && rem=0
    cur=$(( BW_BPS>0 ? rem/BW_BPS : 0 )); new=$(( newbps>0 ? rem/newbps : 0 ))
    printf '    Pendiente: %s\n' "$(human "$rem")"
    printf '    %-9s -> %s\n' "$(bw_label "$BW_BPS")" "$(hms "$cur")"
    printf '    %-9s -> %s\n' "$(bw_label "$newbps")" "$(hms "$new")"
}

control_menu() {
    local c v b
    printf '\n--- CONTROL DEL WORKER ---\n'
    printf ' 1) BW           %s / efectivo %s (manual=%s)   Applies: NEXT FILE\n' "$BW_TARGET" "$(bw_label "$BW_BPS")" "$BW_MANUAL"
    printf ' 2) nice         %s                              Applies: NEXT FILE\n' "$NICE_VALUE"
    printf ' 3) ionice       %s (3=idle)                     Applies: NEXT FILE\n' "$IONICE_CLASS"
    printf ' 4) cooldown     %ss (%s)                        Applies: NEXT FILE\n' "$COOLDOWN" "$COOLDOWN_MODE"
    printf ' 5) adaptive     %s                              Applies: NEXT FILE\n' "$ADAPTIVE"
    printf ' 6) BW min/max   %s / %s                         Applies: NEXT FILE\n' "$BW_MIN" "$BW_MAX"
    printf ' 7) prioridad adaptativa %s (min nice %s / ionice %s)\n' "$ADAPTIVE_PRIORITY" "$NICE_MIN" "$IONICE_MIN"
    printf ' 8) recordsize   %s                              Applies: NEXT JOB\n' "$EXPECTED_RECORDSIZE"
    printf ' 9) threshold    %s                              Applies: NEXT INVENTORY\n' "$(human "$THRESHOLD_BYTES")"
    printf ' p) Cambiar de perfil en caliente (actual: %s)   Applies: NEXT FILE\n' "$PROFILE"
    printf ' t) Condiciones de parada (ahora: %s)\n' "$(stop_summary)"
    printf ' a) Devolver autoridad de BW a AUTO\n 0) Volver\n'
    read -r -p 'Opcion: ' c || return 0
    case "$c" in
        1) read -r -p 'Nuevo BW (ej 20M): ' v || return 0
           if b="$(to_bytes "$v")"; then
               bw_impact "$b"
               read -r -p '  Aplicar al proximo archivo? [y/N]: ' c || return 0
               [[ "$c" =~ ^[yYsS]$ ]] || return 0
               BW_TARGET="$v" BW_BPS="$b" BW_CEIL_BPS="$b" BW_MANUAL=1
               log "[OPERATOR] BW manual=$v. Techo absoluto: AUTO solo podra REDUCIR."
               journal "OPERATOR" "$TARGET_DIR" 0 0 "bw_manual=$v ceiling=$b"
           else warn "BW invalido."; fi ;;
        2) read -r -p 'nice [-20..19]: ' v || return 0
           if [[ "$v" =~ ^-?[0-9]+$ ]] && (( v>=-20 && v<=19 )); then
               NICE_VALUE="$v"; NICE_MIN="$v"; apply_priority
               log "[OPERATOR] nice=$v (limite inferior para AUTO)"
               journal OPERATOR "$TARGET_DIR" 0 0 "nice=$v"
           else warn "nice invalido."; fi ;;
        3) read -r -p 'ionice [1=RT 2=BE 3=IDLE]: ' v || return 0
           if [[ "$v" =~ ^[123]$ ]]; then IONICE_CLASS="$v"; IONICE_MIN="$v"; apply_priority
               log "[OPERATOR] ionice=$v (limite para AUTO)"
               journal OPERATOR "$TARGET_DIR" 0 0 "ionice=$v"
           else warn "ionice invalido."; fi ;;
        4) read -r -p 'cooldown (segundos): ' v || return 0
           if is_int "$v"; then COOLDOWN="$v"; COOLDOWN_BASE="$v"; log "[OPERATOR] cooldown=${v}s"
               journal OPERATOR "$TARGET_DIR" 0 0 "cooldown=${v}s"; else warn "valor invalido."; fi ;;
        5) read -r -p 'adaptive [off/auto/guarded]: ' v || return 0
           case "$v" in off|auto|guarded) ADAPTIVE="$v"; log "[OPERATOR] adaptive=$v"
               journal OPERATOR "$TARGET_DIR" 0 0 "adaptive=$v" ;; *) warn "modo invalido." ;; esac ;;
        6) read -r -p 'BW min: ' v || return 0; is_bw "$v" && BW_MIN="$v"
           read -r -p 'BW max: ' v || return 0; is_bw "$v" && BW_MAX="$v"
           log "[OPERATOR] BW bounds min=$BW_MIN max=$BW_MAX" ;;
        7) read -r -p 'prioridad adaptativa [on/off]: ' v || return 0
           case "$v" in on|off) ADAPTIVE_PRIORITY="$v"; log "[OPERATOR] adaptive-priority=$v"
               journal OPERATOR "$TARGET_DIR" 0 0 "adaptive_priority=$v" ;; *) warn "valor invalido." ;; esac ;;
        8) read -r -p 'recordsize (proximo job): ' v || return 0
           EXPECTED_RECORDSIZE="$v"; log "[OPERATOR] recordsize=$v preparado para el PROXIMO job."
           journal OPERATOR "$TARGET_DIR" 0 0 "recordsize=$v applies=NEXT_JOB" ;;
        9) read -r -p 'threshold (ej 2G, proximo inventario): ' v || return 0
           if v="$(to_bytes "$v")"; then THRESHOLD_BYTES="$v"
               log "[OPERATOR] threshold preparado para el PROXIMO inventario."
               journal OPERATOR "$TARGET_DIR" 0 0 "threshold=$v applies=NEXT_INVENTORY"
           else warn "threshold invalido."; fi ;;
        p|P) profile_menu ;;
        t|T) stop_menu ;;
        a|A) BW_MANUAL=0; BW_BPS="$(to_bytes "$BW_TARGET")"
           log "[OPERATOR] Autoridad de BW devuelta explicitamente a AUTO."
           journal "OPERATOR" "$TARGET_DIR" 0 0 "bw_authority=auto" ;;
    esac
    publish_control
    return 0
}

stop_summary() {
    local o=""
    (( STOP_AFTER > 0 )) && o="tras $STOP_AFTER archivos"
    [[ -n "$STOP_AT" ]] && o="${o:+$o, }a las $STOP_AT"
    printf '%s' "${o:-hasta completar}"
}

# Stop conditions from inside the run: a maintenance window often turns out to
# be shorter than planned, and nobody should have to babysit the console.
stop_menu() {
    local c v
    printf '\n--- CONDICIONES DE PARADA ---\n  actual: %s\n' "$(stop_summary)"
    printf '  [1] Ejecutar hasta completar\n  [2] Parar despues del archivo actual\n'
    printf '  [3] Parar tras N archivos reescritos\n  [4] Parar a una hora (HH:MM)\n  [0] Volver\n'
    read -r -p '  Opcion: ' c || return 0
    case "$c" in
        1) STOP_AFTER=0; STOP_AT=""; log "[OPERATOR] Sin condiciones de parada."
           journal OPERATOR "$TARGET_DIR" 0 0 "stop=none" ;;
        2) PAUSE_REQ=1; log "[OPERATOR] Parada tras el archivo actual." ;;
        3) read -r -p '  N archivos: ' v || return 0
           if is_int "$v"; then STOP_AFTER=$(( N_DONE+v ))
               log "[OPERATOR] Parar al llegar a $STOP_AFTER reescritos."
               journal OPERATOR "$TARGET_DIR" 0 0 "stop_after=$STOP_AFTER"
           else warn "valor invalido."; fi ;;
        4) read -r -p '  Hora HH:MM: ' v || return 0
           if [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then STOP_AT="$v"
               log "[OPERATOR] Parar a las $v."
               journal OPERATOR "$TARGET_DIR" 0 0 "stop_at=$v"
           else warn "hora invalida."; fi ;;
    esac
    return 0
}

# Hot profile switch, the DAY/NIGHT idea. Applies from the next file onwards;
# an operator bandwidth ceiling already in force is not lifted by it.
profile_menu() {
    local c n i names=()
    printf '\n--- PERFILES ---\n  actual: %s\n' "$PROFILE"
    if [[ -f "$PROFILES_FILE" ]]; then
        while IFS= read -r n; do
            n="${n%%#*}"; [[ "$n" == *=* ]] || continue
            n="${n%%=*}"; names+=("${n//[[:space:]]/}")
        done <"$PROFILES_FILE"
    fi
    (( ${#names[@]} )) || names=(default slow-hdd fast-storage night conservative)
    for (( i=0; i<${#names[@]}; i++ )); do printf '  [%s] %s\n' "$((i+1))" "${names[$i]}"; done
    printf '  [0] Volver\n'
    read -r -p '  Opcion: ' c || return 0
    is_int "$c" && (( c >= 1 && c <= ${#names[@]} )) || return 0
    PROFILE="${names[$((c-1))]}"
    load_profile
    BW_BPS="$(to_bytes "$BW_TARGET")"; COOLDOWN_BASE="$COOLDOWN"
    (( BW_MANUAL )) && (( BW_BPS > BW_CEIL_BPS )) && BW_BPS="$BW_CEIL_BPS"
    (( BW_MANUAL )) || BW_CEIL_BPS="$BW_BPS"
    log "[OPERATOR] Perfil -> $PROFILE (BW=$BW_TARGET cooldown=${COOLDOWN}s adaptive=$ADAPTIVE). Applies: NEXT FILE"
    journal OPERATOR "$TARGET_DIR" 0 0 "profile=$PROFILE bw=$BW_TARGET cooldown=$COOLDOWN adaptive=$ADAPTIVE"
    return 0
}

# Non-blocking key poll. Only when stdin is a TTY, so nohup/cron never stall.
poll_keys() {
    (( TTY )) || return 0
    local k=""
    read -r -t 0.05 -n 1 k 2>/dev/null || return 0
    case "$k" in
        p|P) PAUSE_REQ=1; log "[OPERATOR] Pausa solicitada; el archivo actual termina de forma segura." ;;
        c|C) control_menu ;;
        s|S) log "[STATUS] health=$HEALTH score=$HEALTH_SCORE bw=$(bw_label "$BW_BPS") done=$N_DONE skip=$N_SKIP fail=$N_FAIL stale=$N_STALE" ;;
        q|Q) EXIT_REQ=1; PAUSE_REQ=1; log "[OPERATOR] Salida segura solicitada; el archivo actual termina." ;;
    esac
    publish_control
    return 0
}

# -----------------------------------------------------------------------------
# [14] File primitives: snapshots, hashing, temporaries, rollback anchors.
# -----------------------------------------------------------------------------
snapshot_file() {
    local f="$1" s
    s="$(stat -c '%s %i %a %u %g %h' -- "$f" 2>/dev/null)" || return 1
    IFS=' ' read -r F_SIZE F_INODE F_MODE F_UID F_GID F_NLINK <<<"$s"
    F_MTIME="$(stat -c '%y' -- "$f")" || return 1
    F_ATIME="$(stat -c '%x' -- "$f")" || return 1
}

# Content hashing. The algorithm is a knob because the cost is real: hashing
# dominates the wall clock on a multi-TB job.
#   b2      BLAKE2b (GNU coreutils b2sum): the default. Cryptographic, same
#           guarantee this contract needs, ~3x faster than sha256 measured
#           on the reference NAS. Falls back to b3, then sha256.
#   b3      BLAKE3 (b3sum), if installed: same guarantee, faster still.
#           Not verified against b3sum's actual output format yet -- see
#           docs/TEST-PLAN.md.
#   sha256  cryptographic, the universal fallback (always a critical
#           dependency, so this floor can never come up empty)
#   md5     fastest everywhere, but collision-broken - acceptable only as an
#           accidental-corruption detector, never as a security guarantee
# GNU coreutils prefixes the checksum with a literal backslash whenever the
# filename needs escaping in the output line -- confirmed live: a name with an
# embedded newline. The filename portion gets escaped too (the newline becomes
# the two characters \n), but that backslash marker lands INSIDE what looks
# like the hash field, and a plain `awk '{print $1}'` keeps it. Since the
# generated temp filename never needs escaping, its hash never carries that
# marker, and comparing "\<hash>" against "<hash>" fails even when the file's
# actual content is byte-identical. Confirmed to break --integrity strict and
# maximum on any source whose name contains a newline or a backslash.
hash_of() {
    local h; h="$("$HASH_CMD" -- "$1" | awk '{print $1}')"
    printf '%s\n' "${h#\\}"
}
sha_of()  { hash_of "$1"; }   # kept: every call site reads as "the hash"

restore_times() { touch -a -d "$F_ATIME" -- "$1" && touch -m -d "$F_MTIME" -- "$1"; }

verify_meta() {
    local d="$1" s
    s="$(stat -c '%a %u %g' -- "$d" 2>/dev/null)" || return 1
    local m u g; IFS=' ' read -r m u g <<<"$s"
    [[ "$m" == "$F_MODE" ]] || { log "[META] mode $F_MODE != $m"; return 1; }
    [[ "$u" == "$F_UID"  ]] || { log "[META] uid $F_UID != $u";   return 1; }
    [[ "$g" == "$F_GID"  ]] || { log "[META] gid $F_GID != $g";   return 1; }
    [[ "$(stat -c '%x' -- "$d")" == "$F_ATIME" ]] || { log "[META] atime distinto"; return 1; }
    [[ "$(stat -c '%y' -- "$d")" == "$F_MTIME" ]] || { log "[META] mtime distinto"; return 1; }
}

# getfacl/getfattr when available; rsync metadata itemization otherwise. These
# are different mechanisms and the summary records which one actually ran, so
# the docs never claim more than was measured.
xattr_equal() {
    # `sed '1d'` used to drop just the "# file: PATH" header, on the assumption
    # it is always exactly one line. It is not: a path with an embedded newline
    # (confirmed live) splits that header across as many physical lines as the
    # path has newlines, and the leftover fragment then gets compared as if it
    # were real xattr data -- a spurious mismatch on an otherwise identical
    # file. Keeping only lines shaped like "name=value" sidesteps the header
    # entirely, however many lines it spans, since no header or filename
    # fragment takes that form.
    local a b
    a="$(getfattr -d -m - --absolute-names -- "$1" 2>/dev/null | grep '=')"
    b="$(getfattr -d -m - --absolute-names -- "$2" 2>/dev/null | grep '=')"
    [[ "$a" == "$b" ]] || { log "[XATTR] diferencia via getfattr"; return 1; }
}

# NFSv4 ACLs compared as structured data rather than as text. `path` and
# `fhandle` are removed on purpose: the whole point of the worker is to create
# a new inode, so a matching fhandle would mean the reblock did not happen.
# Every other field (aces, acl_flags, acl_type, owner, group, uid, gid,
# trivial) must be identical.
acl_equal_nfs4() {
    local a b
    a="$(nfs4xdr_getfacl -j -- "$1" 2>/dev/null | jq -S -c 'del(.path,.fhandle)')" \
        || { log "[ACL/NFS4] no se pudo leer la ACL de: $1"; return 1; }
    b="$(nfs4xdr_getfacl -j -- "$2" 2>/dev/null | jq -S -c 'del(.path,.fhandle)')" \
        || { log "[ACL/NFS4] no se pudo leer la ACL de: $2"; return 1; }
    [[ -n "$a" && -n "$b" ]] || { log "[ACL/NFS4] ACL vacia"; return 1; }
    [[ "$a" == "$b" ]] || { log "[ACL/NFS4] diferencia entre origen y destino"; return 1; }
}

acl_equal_posix() {
    # Same reasoning as xattr_equal(): `sed '1,3d'` assumes getfacl's header
    # (# file / # owner / # group) is always exactly 3 lines, which breaks the
    # instant the path itself contains a newline -- confirmed live, the same
    # way it broke xattr_equal(). Positively matching the fixed shape of a
    # real ACL entry (user/group/other/mask, optionally "default:", ending in
    # three rwx- characters) sidesteps the header however many lines it spans,
    # since no header line or filename fragment takes that shape.
    local pat='^(default:)?(user|group|other|mask)(:[^:]*)?:[rwx-]{3}$' a b
    a="$(getfacl --absolute-names -n -- "$1" 2>/dev/null | grep -E "$pat")"
    b="$(getfacl --absolute-names -n -- "$2" 2>/dev/null | grep -E "$pat")"
    [[ "$a" == "$b" ]] || { log "[ACL] diferencia via getfacl"; return 1; }
}

# Runs the verifier the file's own dataset requires. FILE_VERIFIER was resolved
# in file_dataset_ok, so by the time we get here it is known to be available;
# an empty value means the caller skipped that gate and is a bug, not a
# degradation, so it fails closed.
verify_acl_xattr() {
    case "$FILE_VERIFIER" in
        'nfs4xdr+jq')       acl_equal_nfs4 "$1" "$2" && xattr_equal "$1" "$2" ;;
        'getfacl+getfattr') acl_equal_posix "$1" "$2" && xattr_equal "$1" "$2" ;;
        'getfattr')         xattr_equal "$1" "$2" ;;
        *) log "[ACL] sin verificador resuelto para ${FILE_DS:-<dataset desconocido>} (acltype=${FILE_DS_ACL:-?})"
           return 1 ;;
    esac
}

# zdb hint. Only an explicit logical-size field counts; anything else is
# UNKNOWN. A hint never authorizes a skip: a single field does not prove every
# data block of the file is 1M, and zdb output is not a stable interface.
# Advisory block-size hint.
#
# `zdb -O` prints a TABLE, not key=value pairs:
#
#     Object  lvl   iblk   dblk  dsize  dnsize  lsize   %full  type
#      55362    3    32K   128K  70.4M     512  71.4M  100.00  ZFS plain file
#
# The field that matters is `dblk`, the data block size. `lsize` is the logical
# size of the whole FILE (71.4M above) and has nothing to do with recordsize --
# matching on it, as an earlier version did, would have compared a file's size
# against 1M and skipped files for no reason. The value is read positionally
# from the column whose header is `dblk`.
#
# Still advisory: one block-size figure does not prove every data block of the
# file is at the target size, and zdb's output is a debug interface, not an API.
# A hint never authorizes a skip.
zfs_hint() {
    local f="$1" rel out ds mp dblk
    have zdb || { printf 'UNKNOWN\n'; return 0; }
    # Ask the dataset that actually owns the file, not the one at the top of
    # the tree: under a path like /mnt/pool they are frequently different.
    if dataset_for "$f"; then ds="$DS_HIT_NAME"; mp="$DS_HIT_MOUNT"
    else ds="$ZFS_DATASET"; mp="$ZFS_MOUNT"; fi
    rel="${f#"$mp"/}"; [[ "$rel" == "$f" ]] && { printf 'UNKNOWN\n'; return 0; }
    # zdb -O walks pool metadata directly, competing for real disk I/O with
    # anything else touching the pool. Confirmed on the reference NAS during a
    # scrub, on a single spinning USB disk: two concurrent `zdb -O` calls each
    # blocked for 7+ minutes, stalling the whole job even though the hint they
    # were fetching is purely advisory and never decides anything. Bounding it
    # with `timeout` is what actually keeps that promise -- an unbounded call
    # can stall real, safety-critical work just as effectively as a bug that
    # lets the hint skip a file, even though it never touches that logic.
    if have timeout; then out="$(timeout 5 zdb -O "$ds" "$rel" 2>/dev/null || true)"
    else out="$(zdb -O "$ds" "$rel" 2>/dev/null || true)"; fi
    dblk="$(awk '
        /(^|[[:space:]])dblk([[:space:]]|$)/ { for (i=1;i<=NF;i++) if ($i=="dblk") col=i; next }
        col && NF >= col && $1 ~ /^[0-9]+$/  { print $col; exit }
    ' <<<"$out")"
    [[ -n "$dblk" ]] || { printf 'UNKNOWN\n'; return 0; }
    printf '%s\n' "$dblk"
}

# Does an advisory hint look like it is already at the target recordsize?
# Comparison is by bytes, so 1M / 1024K / 1048576 all agree.
hint_matches_target() {
    local h="${1:-}" a b
    [[ -n "$h" && "$h" != UNKNOWN ]] || return 1
    a="$(to_bytes "$h" 2>/dev/null)" || return 1
    b="$(to_bytes "$EXPECTED_RECORDSIZE" 2>/dev/null)" || return 1
    [[ "$a" == "$b" ]]
}

tok_of() { printf '%s' "$1" | sha256sum | cut -c1-16; }
tmp_path()    { printf '%s/.zrw-%s-%s.tmp\n'      "$(dirname -- "$1")" "$JOB_SHORT" "$(tok_of "$1")"; }
anchor_path() { printf '%s/.zrw-%s-%s.rollback\n' "$(dirname -- "$1")" "$JOB_SHORT" "$(tok_of "$1")"; }

clean_tmp() { [[ -n "$CUR_TMP" && -e "$CUR_TMP" ]] && rm -f -- "$CUR_TMP"; CUR_TMP=""; return 0; }

# A same-directory hardlink to the original inode. It costs no space and keeps
# the pre-commit data reachable until post-commit verification succeeds.
# The sidecar record is written first so recovery can find the anchor even if
# the process dies immediately after linking.
make_anchor() {
    local f="$1" tok; tok="$(tok_of "$f")"
    CUR_ANCHOR="$(anchor_path "$f")"
    printf '%q\n' "$f" >"$ANCHOR_DIR/$tok" || return 1
    sync -f "$ANCHOR_DIR/$tok" 2>/dev/null || true
    rm -f -- "$CUR_ANCHOR" 2>/dev/null
    ln -- "$f" "$CUR_ANCHOR" || { rm -f -- "$ANCHOR_DIR/$tok"; return 1; }
}

drop_anchor() {
    [[ -n "$CUR_ANCHOR" ]] || return 0
    rm -f -- "$CUR_ANCHOR" 2>/dev/null
    rm -f -- "$ANCHOR_DIR/$(basename -- "${CUR_ANCHOR%.rollback}" | sed 's/^.*-//')" 2>/dev/null
    CUR_ANCHOR=""; return 0
}

# Undo a commit: quarantine the unverified replacement, put the original inode
# back under its name, restore its timestamps.
rollback() {
    local f="$1" anchor="$2" q="$JOB_DIR/quarantine"
    log "[ROLLBACK] Restaurando el inode original de ${f##*/}"
    mkdir -p -- "$q"
    [[ -e "$f" ]] && mv -f -- "$f" "$q/$(basename -- "$f").rejected.$(date +%s)"
    [[ -e "$anchor" ]] || { err "No hay ancla para restaurar $f"; return 1; }
    mv -f -- "$anchor" "$f" || return 1
    restore_times "$f" 2>/dev/null || true
    sync
    R_ROLLBACK=$((R_ROLLBACK+1))
    journal "ROLLBACK" "$f" 0 0 "original restored from anchor"
    return 0
}

space_needed() {
    local m=$(( $1*MARGIN_PCT/100 )); (( m > MARGIN_MIN )) || m="$MARGIN_MIN"
    printf '%s\n' $(( $1+m ))
}

space_free() {
    local a; a="$(df -B1 --output=avail -- "$1" 2>/dev/null | tail -n1 | awk '{print $1}')"
    is_int "$a" || return 1; printf '%s\n' "$a"
}

check_space() {
    local a r; a="$(space_free "$1")" || return 1; r="$(space_needed "$2")"
    (( a >= r )) || { log "[SPACE] libre=$(human "$a") requerido=$(human "$r")"; return 1; }
}

source_unchanged() {
    local s; s="$(stat -c '%s %i' -- "$1" 2>/dev/null)" || return 1
    local sz ino; IFS=' ' read -r sz ino <<<"$s"
    [[ "$sz" == "$F_SIZE" && "$ino" == "$F_INODE" && "$(stat -c '%y' -- "$1")" == "$F_MTIME" ]]
}

# -----------------------------------------------------------------------------
# [15] Reblock pipeline.
# -----------------------------------------------------------------------------
run_rsync() {
    local src="$1" dst="$2" rate rc lg="$JOB_DIR/rsync-$WORKER_ID.log" share
    share=$(( BW_BPS/(WORKERS>0?WORKERS:1) )); (( share<1 )) && share=1
    rate="$(bw_rate "$share")"
    : >"$lg"; CUR_START="$(date +%s)"; CUR_DONE=0
    # -aAXS preserves perms/ACL/xattr and sparse; bwlimit is the only knob the
    # governor may move, and only between files.
    #
    # rsync is backgrounded as a plain child of THIS process, no nice/ionice
    # wrapper: apply_priority() already renice'd/ionice'd this process itself
    # (absolute, via -p "$$") at every point NICE_VALUE/IONICE_CLASS can
    # change (startup, operator [C], adaptive-priority), so the child simply
    # inherits the right values at fork -- the OS never resets priority on
    # fork. Wrapping the launch in the nice(1) command here used to double
    # it: nice's -n flag is an ADJUSTMENT relative to the caller's own
    # niceness, not an absolute target, so once apply_priority() had already
    # moved this process to nice=10, wrapping rsync in that same command
    # again with the same value asked for 10+10 -- clamped to 19, the OS
    # max, no matter what the operator picked.
    # Found live: [C] set nice=10, and the file already mid-copy correctly
    # kept its old value (nice=19, untouched -- Applies: NEXT FILE, as
    # promised), but the NEXT file's rsync also came up at nice=19 instead
    # of 10. ionice does not have this problem (`ionice -c` sets the class
    # absolutely, it does not add to whatever class the caller already has),
    # so it stayed correct even with the redundant wrapper -- confirmed live
    # too.
    rsync -aAXS --no-compress --bwlimit="$rate" -- "$src" "$dst" >"$lg" 2>&1 &
    RSYNC_PID=$!
    while kill -0 "$RSYNC_PID" 2>/dev/null; do
        [[ -e "$dst" ]] && { CUR_DONE="$(stat -c '%s' -- "$dst" 2>/dev/null || printf 0)"
                             (( CUR_DONE > CUR_SIZE )) && CUR_DONE="$CUR_SIZE"; }
        if (( WORKER_ID == 0 )); then governor_step; poll_keys; else read_control; fi
        dashboard; sleep 1
    done
    wait "$RSYNC_PID"; rc=$?; RSYNC_PID=""
    [[ -s "$lg" ]] && cat "$lg" >>"$EVENT_LOG" 2>/dev/null
    return "$rc"
}

count_bytes() { is_int "${1-}" && BYTES_SEEN=$(( BYTES_SEEN+$1 )); return 0; }

fail_file() {
    local key="$1" f="$2" inode="$3" why="$4"
    N_FAIL=$((N_FAIL+1)); record_result FAILED "$F_SIZE" "$f"
    transition "$key" FAILED "$CUR_ATTEMPT" "$F_SIZE" "$inode" "$F_MTIME" "$f" "$why"
    log "[FAILED] ${f##*/}: $why"; clean_tmp; drop_anchor; return 0
}

# What to do with a file that changed under us. An unattended run must never
# block, so the menu only appears on a terminal and can be switched off for the
# rest of the job from inside itself.
#   ask      prompt (default on a TTY)
#   skip     mark STALE and move on (default when unattended)
#   retry    re-snapshot and process it now
#   refresh  adopt the current size as the inventory truth, then process
stale_decision() {
    local f="$1" c
    if [[ "$STALE_POLICY" != ask ]] || (( ! TTY || WORKER_ID != 0 )) \
       || [[ "$UI_MODE" == quiet || "$UI_MODE" == json ]]; then
        printf '%s\n' "$([[ "$STALE_POLICY" == ask ]] && echo skip || echo "$STALE_POLICY")"
        return 0
    fi
    printf '\n%s[STALE]%s %s cambio desde el inventario.\n' "$C_Y" "$C_OFF" "${f##*/}"
    printf '  inventariado: %s\n  actual      : %s\n' "$(human "${ST_SIZE:-0}")" "$(human "$F_SIZE")"
    printf '  [1] Revalidar y procesarlo ahora\n'
    printf '  [2] Omitir, queda STALE   [default]\n'
    printf '  [3] Actualizar el inventario con el tamano actual y procesarlo\n'
    printf '  [4] Omitir y no volver a preguntar en este job\n'
    read -r -t 60 -p '  Opcion: ' c || c=2
    case "$c" in
        1) printf 'retry\n' ;;
        3) printf 'refresh\n' ;;
        4) STALE_POLICY=skip; log "[OPERATOR] stale-policy=skip para el resto del job"; printf 'skip\n' ;;
        *) printf 'skip\n' ;;
    esac
}

stale_file() {
    local key="$1" f="$2" why="$3"
    N_STALE=$((N_STALE+1)); R_CHANGED=$((R_CHANGED+1)); count_bytes "$F_SIZE"
    record_result STALE "$F_SIZE" "$f"
    transition "$key" STALE "$CUR_ATTEMPT" "$F_SIZE" "$F_INODE" "$F_MTIME" "$f" "$why"
    log "[STALE] ${f##*/}: $why"; clean_tmp; drop_anchor; return 0
}

process_one() {
    local f="$1" key="$2" hint src_sha="" tmp_sha post_sha tmp_size ok attempt
    local p_size p_inode p_atime p_mtime post_ok
    CUR_FILE="$f" CUR_DONE=0 CUR_SIZE=0 CUR_ATTEMPT=0 CUR_START=0 COOLDOWN_LEFT=0
    CUR_STATUS="evaluando"

    [[ -f "$f" ]] || { N_MISS=$((N_MISS+1)); R_MISSING=$((R_MISSING+1)); count_bytes "$ST_SIZE"
        record_result MISSING 0 "$f"
        transition "$key" MISSING "$ST_ATTEMPT" 0 0 "" "$f" "archivo ausente"
        log "[MISSING] $f"; return 0; }

    snapshot_file "$f" || { CUR_ATTEMPT="$ST_ATTEMPT"; fail_file "$key" "$f" 0 "no se pudo leer metadata"; return 0; }
    CUR_SIZE="$F_SIZE"

    # Defence in depth: the inventory already filtered by dataset, but a dataset
    # can be created, moved or re-tuned while a multi-day job is running.
    if ! file_dataset_ok "$f"; then
        N_SKIP=$((N_SKIP+1)); count_bytes "$F_SIZE"; record_result SKIPPED "$F_SIZE" "$f"
        case "$DS_SKIP_WHY" in
            *"otro dataset"*) R_OTHER_DS=$((R_OTHER_DS+1)) ;;
            *recordsize*)     R_RECORDSIZE=$((R_RECORDSIZE+1)) ;;
        esac
        transition "$key" SKIPPED "$ST_ATTEMPT" "$F_SIZE" "$F_INODE" "$F_MTIME" "$f" "$DS_SKIP_WHY"
        log "[SKIP] ${f##*/}: $DS_SKIP_WHY"
        return 0
    fi

    # Replacing the inode would break every other name pointing at it.
    if (( F_NLINK > 1 )); then
        N_SKIP=$((N_SKIP+1)); R_HARDLINK=$((R_HARDLINK+1)); count_bytes "$F_SIZE"
        record_result SKIPPED "$F_SIZE" "$f"
        transition "$key" SKIPPED "$ST_ATTEMPT" "$F_SIZE" "$F_INODE" "$F_MTIME" "$f" "hardlink nlink=$F_NLINK"
        log "[SKIP] HARDLINK (nlink=$F_NLINK) - requiere decision explicita: ${f##*/}"
        return 0
    fi

    # Changed since the inventory: the operator may want to revalidate it, skip
    # it, or adopt the new size as the truth. Unattended runs always skip.
    if [[ -n "$ST_SIZE" && "$ST_SIZE" != "$F_SIZE" ]]; then
        case "$(stale_decision "$f")" in
            retry)   log "[RETRY] Revalidando ${f##*/} por decision del operador." ;;
            refresh) log "[OPERATOR] Inventario actualizado para ${f##*/}: $ST_SIZE -> $F_SIZE"
                     journal OPERATOR "$f" "$F_INODE" "$F_SIZE" "inventory refreshed by operator" ;;
            *) stale_file "$key" "$f" "tamano cambiado desde el inventario ($ST_SIZE -> $F_SIZE)"; return 0 ;;
        esac
    fi

    CUR_STATUS="inspeccion ZFS (advisory)"; dashboard
    hint="$(zfs_hint "$f")"
    if hint_matches_target "$hint"; then
        N_HINT_1M=$((N_HINT_1M+1))
        log "[ZFS] hint advisory: dblk=$hint ya coincide con $EXPECTED_RECORDSIZE para ${f##*/}; se reescribe igual (el hint no decide)."
    else
        log "[ZFS] hint advisory: dblk=$hint para ${f##*/}; se verifica y reescribe."
    fi

    CUR_STATUS="comprobando espacio"
    if ! check_space "$(dirname -- "$f")" "$F_SIZE"; then
        SPACE_PAUSE=1; PAUSE_REQ=1; R_SPACE=$((R_SPACE+1))
        transition "$key" PENDING "$ST_ATTEMPT" "$F_SIZE" "$F_INODE" "$F_MTIME" "$f" "espacio insuficiente; lote pausado"
        log "[PAUSE] Espacio insuficiente para ${f##*/}. El archivo queda PENDING."
        return 0
    fi

    if (( DRY_RUN )); then count_bytes "$F_SIZE"; log "[DRY-RUN] Se reescribiria: $f ($(human "$F_SIZE"))"; return 0; fi

    # Timestamps captured before ANY read: on atime-enabled datasets reading
    # the file changes atime, so a later touch -r would copy a polluted value.
    local a0="$F_ATIME" m0="$F_MTIME"
    CUR_TMP="$(tmp_path "$f")"; rm -f -- "$CUR_TMP" 2>/dev/null
    log "------------------------------------------------------------------"
    log "[PROCESS] ${f##*/} size=$(human "$F_SIZE") bw=$(bw_label "$BW_BPS")"

    ok=0
    for (( attempt=1; attempt<=RETRIES+1; attempt++ )); do
        CUR_ATTEMPT=$(( ST_ATTEMPT+attempt ))
        transition "$key" PROCESSING "$CUR_ATTEMPT" "$F_SIZE" "$F_INODE" "$F_MTIME" "$f" "copia intento $attempt"
        source_unchanged "$f" || { stale_file "$key" "$f" "cambio antes de copiar"; return 0; }
        if [[ "$INTEGRITY" != standard ]]; then
            CUR_STATUS="hash $HASH_ALGO del origen"; dashboard
            src_sha="$(sha_of "$f")" || { fail_file "$key" "$f" "$F_INODE" "hash $HASH_ALGO del origen fallo"; return 0; }
            touch -a -d "$a0" -- "$f" 2>/dev/null || true   # undo the read's atime
        fi
        CUR_STATUS="REESCRIBIENDO (rsync)"
        run_rsync "$f" "$CUR_TMP" && { ok=1; break; }
        log "[RETRY] rsync fallo en ${f##*/} (intento $attempt/$((RETRIES+1)))"
        rm -f -- "$CUR_TMP" 2>/dev/null
    done
    (( ok )) || { fail_file "$key" "$f" "$F_INODE" "rsync fallo tras $((RETRIES+1)) intentos"; return 0; }

    CUR_STATUS="VERIFICANDO"; dashboard
    transition "$key" VERIFYING "$CUR_ATTEMPT" "$F_SIZE" "$F_INODE" "$F_MTIME" "$f" "copia completa"
    source_unchanged "$f" || { stale_file "$key" "$f" "cambio durante la copia"; return 0; }

    # Same size and same mtime can still hide a content change, so strict mode
    # re-hashes the source. A writer touching the file is STALE, not a failure.
    if [[ "$INTEGRITY" != standard ]]; then
        local now_sha; now_sha="$(sha_of "$f")" || { fail_file "$key" "$f" "$F_INODE" "re-hash del origen fallo"; return 0; }
        touch -a -d "$a0" -- "$f" 2>/dev/null || true
        [[ "$now_sha" == "$src_sha" ]] || { stale_file "$key" "$f" "el contenido del origen cambio durante la copia"; return 0; }
    fi

    tmp_size="$(stat -c '%s' -- "$CUR_TMP" 2>/dev/null || printf -- -1)"
    [[ "$tmp_size" == "$F_SIZE" ]] || { fail_file "$key" "$f" "$F_INODE" "tamano distinto origen=$F_SIZE temp=$tmp_size"; return 0; }

    # Order matters: hash first (reading moves atime), then restore, then verify.
    if [[ "$INTEGRITY" != standard ]]; then
        tmp_sha="$(sha_of "$CUR_TMP")" || { fail_file "$key" "$f" "$F_INODE" "hash $HASH_ALGO del temporal fallo"; return 0; }
        [[ "$src_sha" == "$tmp_sha" ]] || { fail_file "$key" "$f" "$F_INODE" "hash $HASH_ALGO no coincide antes del commit"; return 0; }
        log "[VERIFY] hash $HASH_ALGO origen == temporal (${src_sha:0:12}...)"
    fi
    verify_acl_xattr "$f" "$CUR_TMP" || { fail_file "$key" "$f" "$F_INODE" "verificacion ACL/xattr fallo (acltype=$FILE_DS_ACL, verificador=$FILE_VERIFIER)"; return 0; }
    F_ATIME="$a0" F_MTIME="$m0"
    restore_times "$CUR_TMP" || { fail_file "$key" "$f" "$F_INODE" "no se pudieron restaurar timestamps"; return 0; }
    verify_meta "$CUR_TMP"   || { fail_file "$key" "$f" "$F_INODE" "verificacion de mode/uid/gid/timestamps fallo"; return 0; }
    source_unchanged "$f"    || { stale_file "$key" "$f" "cambio justo antes del commit"; return 0; }

    make_anchor "$f" || { fail_file "$key" "$f" "$F_INODE" "no se pudo crear el ancla de rollback"; return 0; }

    # ------------------------- COMMIT BOUNDARY -------------------------
    # No explicit sync of CUR_TMP here, on purpose: on ZFS, the rename and the
    # data blocks it references are part of the same copy-on-write pointer
    # graph, and can only ever be committed together in the same transaction
    # group. If the machine dies before that TXG reaches disk, ZFS rolls back
    # to the last fully-committed TXG: the rename can never "outrun" its own
    # data, nor leave a truncated file under the real name. This guarantee is
    # exactly why discover_dataset() requires the target to sit inside a ZFS
    # dataset -- on any other filesystem it would not hold, and this commit
    # would need its own fsync before the rename.
    CUR_STATUS="COMMIT (rename atomico)"; dashboard
    mv -f -- "$CUR_TMP" "$f" || { fail_file "$key" "$f" "$F_INODE" "el rename fallo"; return 0; }
    CUR_TMP=""

    p_size="$(stat -c '%s' -- "$f" 2>/dev/null)" || p_size=-1
    p_inode="$(stat -c '%i' -- "$f" 2>/dev/null)" || p_inode=-1
    post_ok=1
    [[ "$p_size" == "$F_SIZE" ]] || post_ok=0
    if (( post_ok )) && [[ "$INTEGRITY" == maximum ]]; then
        post_sha="$(sha_of "$f" 2>/dev/null || true)"
        [[ "$post_sha" == "$src_sha" ]] || post_ok=0
    fi
    restore_times "$f" 2>/dev/null || true
    p_atime="$(stat -c '%x' -- "$f" 2>/dev/null)"; p_mtime="$(stat -c '%y' -- "$f" 2>/dev/null)"
    [[ "$p_atime" == "$F_ATIME" && "$p_mtime" == "$F_MTIME" ]] || post_ok=0
    # The anchor still carries the original metadata, so ACL/xattr are compared
    # after the commit against the real original rather than only before it.
    (( post_ok )) && { verify_acl_xattr "$CUR_ANCHOR" "$f" || post_ok=0; }

    if (( ! post_ok )); then
        N_FAIL=$((N_FAIL+1)); record_result FAILED "$F_SIZE" "$f"
        log "[FAILED] Invariante post-commit violada; iniciando rollback."
        if rollback "$f" "$CUR_ANCHOR"; then
            CUR_ANCHOR=""
            transition "$key" PENDING "$CUR_ATTEMPT" "$F_SIZE" "$F_INODE" "$F_MTIME" "$f" "rollback: original restaurado"
            log "[ROLLBACK] Original restaurado; el reemplazo quedo en cuarentena."
        else
            err "[CRITICAL] El rollback fallo. Revisar manualmente el ancla: $CUR_ANCHOR"
            transition "$key" FAILED "$CUR_ATTEMPT" "$F_SIZE" "$p_inode" "$F_MTIME" "$f" "rollback fallido"
        fi
        drop_anchor; return 0
    fi

    drop_anchor
    CUR_STATUS="sync"; dashboard; sync
    N_DONE=$((N_DONE+1)); BYTES_DONE=$(( BYTES_DONE+F_SIZE )); count_bytes "$F_SIZE"
    record_result DONE "$F_SIZE" "$f"
    transition "$key" DONE "$CUR_ATTEMPT" "$F_SIZE" "$p_inode" "$F_MTIME" "$f" "commit verificado"

    local el sp; el=$(( $(date +%s)-CUR_START )); (( el<1 )) && el=1; sp=$(( F_SIZE/el ))
    push_event "$(printf 'OK %-34s %10s %9s/s %s' "$(printf '%.34s' "${f##*/}")" "$(human "$F_SIZE")" "$(human "$sp")" "$(hms "$el")")"
    log "[OK] ${f##*/} inode $F_INODE -> $p_inode size=$(human "$F_SIZE") $(human "$sp")/s elapsed=$(hms "$el")"

    adapt_cooldown
    if (( COOLDOWN > 0 )); then
        CUR_STATUS="enfriamiento entre archivos"
        local i
        for (( i=COOLDOWN; i>0; i-- )); do
            COOLDOWN_LEFT="$i"
            if (( WORKER_ID == 0 )); then poll_keys; else read_control; fi
            dashboard; sleep 1; (( PAUSE_REQ )) && break
        done
        COOLDOWN_LEFT=0
    fi
    return 0
}

# -----------------------------------------------------------------------------
# [16] Recovery. A trap only runs on orderly exits; power loss runs nothing.
#      So recovery is rebuilt from what is on disk, not from shell state.
# -----------------------------------------------------------------------------
# Found live, the hard way, by a real machine reboot mid-copy (ronda 12): if
# the crash lands while rsync itself is still mid-transfer, the file on disk
# is not yet CUR_TMP -- it is rsync's own scratch name, CUR_TMP plus rsync's
# random suffix (".zrw-<job>-<tok>.tmp.XXXXXX"), which rsync only renames to
# the exact ".tmp" name once the transfer finishes. A glob for exactly
# ".zrw-*.tmp" never sees that file: it is real, on disk, taking up space,
# and --status does report it ("orphan_temps"), but recover_temps() silently
# walked past it forever, leaving the operator with a count and no cleanup
# path. Matching ".tmp*" (not just ".tmp") closes that gap.
recover_temps() {
    local f base q found=0
    while IFS= read -r -d '' f; do
        base="$(basename -- "$f")"
        if [[ "$base" != ".zrw-${JOB_SHORT}-"* ]]; then
            N_FOREIGN=$((N_FOREIGN+1)); log "[RECOVERY] Temporal de OTRO job; no se toca: $f"; continue
        fi
        found=1; q="$JOB_DIR/quarantine/${base}.$(date +%s)"
        # Never promoted, never deleted: it might hold a complete copy.
        if mv -f -- "$f" "$q"; then
            N_RECOV=$((N_RECOV+1)); log "[RECOVERY] Temporal huerfano en cuarentena: $q"
            journal QUARANTINE "$f" 0 0 "orphan temp -> $q"
        else warn "No se pudo poner en cuarentena: $f"; fi
    done < <(find "$TARGET_DIR" -type f -name '.zrw-*.tmp*' -print0 2>/dev/null)
    (( found )) || log "[RECOVERY] Sin temporales huerfanos propios."
    (( N_FOREIGN )) && warn "$N_FOREIGN temporal(es) de otros jobs presentes; no se modificaron."
    return 0
}

# An orphan anchor is not cosmetic: it leaves the original with nlink=2, which
# would make the next run classify the file as a hardlink and skip it forever.
# Comparing inodes tells whether the commit happened before the interruption.
recover_anchors() {
    local rec tok f anchor a_ino f_ino
    shopt -s nullglob
    for rec in "$ANCHOR_DIR"/*; do
        tok="$(basename -- "$rec")"
        unq "$(cat -- "$rec")"; f="$QPATH"
        anchor="$(anchor_path "$f")"
        if [[ ! -e "$anchor" ]]; then rm -f -- "$rec"; continue; fi
        a_ino="$(stat -c '%i' -- "$anchor" 2>/dev/null || printf 0)"
        f_ino="$(stat -c '%i' -- "$f" 2>/dev/null || printf 0)"
        if [[ "$a_ino" == "$f_ino" ]]; then
            # Commit never happened: the original is intact, drop the anchor.
            rm -f -- "$anchor" "$rec"
            log "[RECOVERY] Ancla huerfana sin commit; original intacto: ${f##*/}"
        else
            # Commit happened but was never verified. Return the file to the
            # state it had before the worker touched it.
            log "[RECOVERY] Ancla huerfana con commit sin verificar: ${f##*/}"
            snapshot_file "$anchor" 2>/dev/null || true
            if rollback "$f" "$anchor"; then
                N_RECOV=$((N_RECOV+1)); rm -f -- "$rec"
                st_lock; save_state "$(state_key "$f")" PENDING 0 "$F_SIZE" "$F_INODE" "$F_MTIME" "$f"; st_unlock
                log "[RECOVERY] Original restaurado y devuelto a PENDING: ${f##*/}"
            else
                warn "No se pudo completar el rollback de $f; ancla: $anchor"
            fi
        fi
    done
    shopt -u nullglob
    return 0
}

# PROCESSING/VERIFYING mean a worker died mid-flight. Back to PENDING.
recover_states() {
    local sf key
    [[ -d "$STATE_DIR" ]] || return 0
    shopt -s nullglob
    for sf in "$STATE_DIR"/*.state; do
        key="${sf##*/}"; key="${key%.state}"; load_state "$key"
        case "$ST_STATUS" in
            PROCESSING|VERIFYING)
                transition "$key" PENDING "$ST_ATTEMPT" "$ST_SIZE" "$ST_INODE" "$ST_MTIME" "$ST_PATH" "PENDING_AFTER_RECOVERY"
                log "[RECOVERY] $ST_PATH vuelve a PENDING (estaba en $ST_STATUS)." ;;
        esac
    done
    shopt -u nullglob
    return 0
}

# Quarantined temporaries are evidence, so the operator gets them pre-analysed.
inspect_quarantine() {
    local q="$JOB_DIR/quarantine" f n=0
    [[ -d "$q" ]] || return 0
    shopt -s nullglob
    for f in "$q"/*; do
        n=$((n+1))
        printf '  %s\n    tamano: %s   sha256: %s\n' "$(basename -- "$f")" \
            "$(human "$(stat -c '%s' -- "$f" 2>/dev/null || printf 0)")" "$(sha_of "$f" 2>/dev/null || echo '-')"
    done
    shopt -u nullglob
    (( n )) && say "  ($n elementos en cuarentena requieren decision humana)"
    return 0
}

# -----------------------------------------------------------------------------
# [17] Reporting.
# -----------------------------------------------------------------------------
tally_results() {
    local st bytes rest
    N_DONE=0 N_SKIP=0 N_FAIL=0 N_STALE=0 N_MISS=0 BYTES_DONE=0 BYTES_SEEN=0
    [[ -f "$RESULTS_FILE" ]] || return 0
    while IFS=$'\t' read -r st bytes rest; do
        is_int "$bytes" || bytes=0
        BYTES_SEEN=$(( BYTES_SEEN+bytes ))
        case "$st" in
            DONE)    N_DONE=$((N_DONE+1)); BYTES_DONE=$(( BYTES_DONE+bytes )) ;;
            SKIPPED) N_SKIP=$((N_SKIP+1)) ;;  FAILED) N_FAIL=$((N_FAIL+1)) ;;
            STALE)   N_STALE=$((N_STALE+1)) ;; MISSING) N_MISS=$((N_MISS+1)) ;;
        esac
    done <"$RESULTS_FILE"
    return 0
}

write_summary() {
    local end el avg
    end="$(date +%s)"; el=$(( end-JOB_START )); avg="$(avg_speed)"
    { printf 'metric\tvalue\n'
      printf 'version\t%s\njob_id\t%s\ntarget\t%s\ndataset\t%s\n' "$VERSION" "$JOB_ID" "$TARGET_DIR" "$ZFS_DATASET"
      printf 'recordsize_target\t%s\nthreshold_bytes\t%s\nworkers\t%s\n' "$EXPECTED_RECORDSIZE" "$THRESHOLD_BYTES" "$WORKERS"
      printf 'candidates\t%s\nprocessed\t%s\nskipped\t%s\nfailed\t%s\nstale\t%s\nmissing\t%s\n' \
             "$N_TOTAL" "$N_DONE" "$N_SKIP" "$N_FAIL" "$N_STALE" "$N_MISS"
      printf 'recovered\t%s\nrollbacks\t%s\nforeign_temps\t%s\nwarnings\t%s\n' "$N_RECOV" "$R_ROLLBACK" "$N_FOREIGN" "$N_WARN"
      printf 'reason_hardlink\t%s\nreason_changed\t%s\nreason_missing\t%s\nreason_space\t%s\n' \
             "$R_HARDLINK" "$R_CHANGED" "$R_MISSING" "$R_SPACE"
      printf 'bytes_planned\t%s\nbytes_rewritten\t%s\navg_bytes_per_sec\t%s\nelapsed_seconds\t%s\n' \
             "$BYTES_PLANNED" "$BYTES_DONE" "$avg" "$el"
      printf 'adaptive_mode\t%s\nadaptive_priority\t%s\ncooldown_mode\t%s\n' "$ADAPTIVE" "$ADAPTIVE_PRIORITY" "$COOLDOWN_MODE"
      printf 'final_bw_effective\t%s\nbw_authority\t%s\n' "$(bw_label "$BW_BPS")" "$( (( BW_MANUAL )) && echo MANUAL || echo AUTO)"
      printf 'health_status\t%s\nhealth_score\t%s\ndisk_util\t%s\ndisk_wait_ms\t%s\n' "$HEALTH" "$HEALTH_SCORE" "$DISK_UTIL" "$DISK_WAIT"
      printf 'psi_io\t%s\npsi_cpu\t%s\npsi_mem\t%s\nswap_used\t%s\n' "$PSI_IO" "$PSI_CPU" "$PSI_MEM" "$SWAP_USED"
      printf 'hash\t%s\ndatasets_in_tree\t%s\n' "$HASH_ALGO" "$TREE_DATASETS"
      printf 'skipped_other_dataset\t%s\nskipped_recordsize\t%s\n' "$R_OTHER_DS" "$R_RECORDSIZE"
      printf 'datasets_recordsize_ok\t%s\ndatasets_recordsize_other\t%s\n' "$TREE_RS_OK" "$TREE_RS_BAD"
      printf 'datasets_acl_verifiable\t%s\ndatasets_acl_unverifiable\t%s\n' "$TREE_ACL_OK" "$TREE_ACL_BAD"
      printf 'paused_for_space\t%s\n' "$SPACE_PAUSE"
      printf 'integrity\t%s\nacl_policy\t%s\nprofile\t%s\n' "$INTEGRITY" "$TREE_ACL_REPORT" "$PROFILE"
    } >"$SUMMARY_TSV"

    cat >"$SUMMARY_JSON" <<EOF
{
  "version": "$VERSION",
  "job_id": "$(jesc "$JOB_ID")",
  "target": "$(jesc "$TARGET_DIR")",
  "dataset": "$(jesc "$ZFS_DATASET")",
  "recordsize_target": "$(jesc "$EXPECTED_RECORDSIZE")",
  "threshold_bytes": $THRESHOLD_BYTES,
  "workers": $WORKERS,
  "candidates": $N_TOTAL,
  "processed": $N_DONE,
  "skipped": $N_SKIP,
  "failed": $N_FAIL,
  "stale": $N_STALE,
  "missing": $N_MISS,
  "recovered": $N_RECOV,
  "rollbacks": $R_ROLLBACK,
  "foreign_temps": $N_FOREIGN,
  "warnings": $N_WARN,
  "reasons": { "hardlink": $R_HARDLINK, "changed_since_inventory": $R_CHANGED,
               "missing": $R_MISSING, "insufficient_space": $R_SPACE },
  "bytes_planned": $BYTES_PLANNED,
  "bytes_rewritten": $BYTES_DONE,
  "avg_bytes_per_sec": $avg,
  "elapsed_seconds": $el,
  "adaptive_mode": "$ADAPTIVE",
  "adaptive_priority": "$ADAPTIVE_PRIORITY",
  "final_bw_effective": "$(bw_label "$BW_BPS")",
  "bw_authority": "$( (( BW_MANUAL )) && echo MANUAL || echo AUTO)",
  "health_status": "$HEALTH",
  "health_score": $HEALTH_SCORE,
  "disk_util": $DISK_UTIL,
  "disk_wait_ms": $DISK_WAIT,
  "psi_io": $PSI_IO,
  "psi_cpu": $PSI_CPU,
  "psi_mem": $PSI_MEM,
  "swap_used": $SWAP_USED,
  "hash": "$HASH_ALGO",
  "datasets_in_tree": $TREE_DATASETS,
  "datasets_recordsize_ok": $TREE_RS_OK,
  "datasets_recordsize_other": $TREE_RS_BAD,
  "paused_for_space": $SPACE_PAUSE,
  "skipped_other_dataset": $R_OTHER_DS,
  "skipped_recordsize": $R_RECORDSIZE,
  "integrity": "$INTEGRITY",
  "acl_policy": "$(jesc "$TREE_ACL_REPORT")",
  "acl_datasets_verifiable": $TREE_ACL_OK,
  "acl_datasets_unverifiable": $TREE_ACL_BAD,
  "profile": "$(jesc "$PROFILE")"
}
EOF
    [[ "$UI_MODE" == json ]] && cat "$SUMMARY_JSON"
    return 0
}

final_report() {
    [[ "$UI_MODE" == json ]] && return 0
    local el avg title="JOB COMPLETADO" tc="$C_OKB"
    el=$(( $(date +%s)-JOB_START )); avg="$(avg_speed)"
    (( N_FAIL )) && tc="$C_WRB"   # completed, but not cleanly: still worth a second look
    (( PAUSE_REQ )) && { title="JOB PAUSADO"; tc="$C_WRB"; }
    (( ENV_ABORT )) && { title="JOB DETENIDO POR CAMBIO DEL ENTORNO"; tc="$C_ERB"; }
    raw ""
    raw "=================================================================="
    if (( TTY && COLOR )); then raw "  ${tc}${title}${C_OFF}"; else raw "  $title"; fi
    raw "=================================================================="
    printf '  Job              %s\n  Target           %s\n  Dataset          %s\n\n' "$JOB_ID" "$TARGET_DIR" "$ZFS_DATASET"
    printf '  Candidatos       %s\n  Revisados        %s\n  Reescritos       %s\n' "$N_TOTAL" "$N_INDEX" "$N_DONE"
    printf '  Omitidos         %s\n  Fallidos         %s\n  Modificados      %s\n  Ausentes         %s\n\n' "$N_SKIP" "$N_FAIL" "$N_STALE" "$N_MISS"
    if (( R_HARDLINK || R_CHANGED || R_MISSING || R_SPACE )); then
        raw "  Motivos"
        (( R_HARDLINK )) && printf '    %5s  hardlink (pendiente de decision explicita)\n' "$R_HARDLINK"
        (( R_CHANGED ))  && printf '    %5s  cambiado desde el inventario o durante la copia\n' "$R_CHANGED"
        (( R_MISSING ))  && printf '    %5s  desaparecido\n' "$R_MISSING"
        (( R_SPACE ))    && printf '    %5s  espacio insuficiente (lote pausado)\n' "$R_SPACE"
        raw ""
    fi
    printf '  Datos reescritos %s\n  Velocidad media  %s/s\n  Transcurrido     %s\n\n' "$(human "$BYTES_DONE")" "$(human "$avg")" "$(hms "$el")"
    printf '  Avisos           %s\n  Recuperaciones   %s\n  Rollbacks        %s\n  Temporales ajenos %s\n' "$N_WARN" "$N_RECOV" "$R_ROLLBACK" "$N_FOREIGN"
    printf '  Integridad       %s (hash %s; ACL/xattr por acltype de cada dataset)\n\n' "$INTEGRITY" "$HASH_ALGO"
    raw "  ESTADO DEL SISTEMA"
    printf '    ZFS        %s\n    Recordsize %s\n    Espacio    %s libres\n' "$ZFS_DATASET" "$RUN_RECORDSIZE" "$(human "$(space_free "$TARGET_DIR" 2>/dev/null || echo 0)")"
    printf '    nice / I/O %s / %s\n    Servidor   %s (score %s, disco %s%%)\n' "$NICE_VALUE" "$IONICE_CLASS" "$HEALTH" "$HEALTH_SCORE" "$DISK_UTIL"
    raw "=================================================================="
    inspect_quarantine
    if (( N_FAIL || N_STALE || R_HARDLINK )); then
        raw "  Trabajo pendiente:"
        (( N_FAIL ))  && printf '    %s --job %s --retry-failed\n' "$SCRIPT_PATH" "$JOB_ID"
        (( N_STALE )) && printf '    %s --job %s --retry-stale\n' "$SCRIPT_PATH" "$JOB_ID"
        (( R_HARDLINK )) && printf '    %s hardlink(s) omitidos: requieren decision manual\n' "$R_HARDLINK"
    elif (( SPACE_PAUSE )); then
        # A space pause is not a generic pause: resuming without freeing space
        # just walks into the same wall on the same file.
        printf '  %sPausado por falta de espacio%s en %s (libres: %s).\n' \
            "$C_Y" "$C_OFF" "$TARGET_DIR" "$(human "$(space_free "$TARGET_DIR" 2>/dev/null || echo 0)")"
        printf '  Liberar espacio y recien entonces reanudar con:\n    %s --job %s --resume\n' \
            "$SCRIPT_PATH" "$JOB_ID"
    elif (( PAUSE_REQ )); then
        printf '  Reanudar con:\n    %s --job %s --resume\n' "$SCRIPT_PATH" "$JOB_ID"
    fi
    printf '  Detalle: %s\n  Resumen: %s\n' "$EVENT_LOG" "$SUMMARY_JSON"
    raw "=================================================================="
    return 0
}

# Fills JS_* for one job id, for --status and the job picker.
#
# Nothing here is read by position. The files belong to whatever version of the
# worker ran that job, which is not necessarily this one, so the journal columns
# are located by the names in its own header row.
job_stats() {
    local d="$STATE_ROOT/$1" s
    JS_TOTAL=0 JS_DONE=0 JS_PEND=0 JS_FAIL=0 JS_STALE=0 JS_SKIP=0 JS_TARGET="" JS_TMP=0 JS_PID=""
    JS_INFLIGHT=0 JS_LAST="" JS_LASTSTATE="" JS_ANCHORS=0 JS_BYTES=0

    [[ -f "$d/inventory.tsv" ]] && JS_TOTAL="$(grep -c . "$d/inventory.tsv" 2>/dev/null)"
    [[ -f "$d/config.env" ]] && JS_TARGET="$(awk -F'TARGET_DIR=' '/^TARGET_DIR=/{print $2}' "$d/config.env" | tr -d "'\"")"
    [[ -f "$d/job.pid" ]] && { read -r JS_PID _ <"$d/job.pid" || true; }

    # One awk pass over the state files. An unmatched glob just makes awk fail
    # and leaves every counter at zero, which is the right answer for a job
    # whose state directory is gone.
    s="$(awk -F= '$1 == "status" { c[$2]++ }
        END { printf "%d %d %d %d %d %d", c["DONE"]+0, c["PENDING"]+0, c["FAILED"]+0,
                     c["STALE"]+0, c["SKIPPED"]+0, c["PROCESSING"]+0 + c["VERIFYING"]+0 }' \
        "$d"/state/*.state 2>/dev/null)"
    [[ -n "$s" ]] && IFS=' ' read -r JS_DONE JS_PEND JS_FAIL JS_STALE JS_SKIP JS_INFLIGHT <<<"$s"

    # Last activity, by column name, and never the header row itself.
    if [[ -s "$d/journal.tsv" ]]; then
        s="$(awk -F'\t' '
            NR == 1 { for (i=1; i<=NF; i++) col[$i] = i; next }
            { last = $0 }
            END {
                if (last == "") exit
                n = split(last, f, "\t")
                t  = (("timestamp" in col) && col["timestamp"] <= n) ? f[col["timestamp"]] : f[1]
                st = (("state"     in col) && col["state"]     <= n) ? f[col["state"]]     : f[2]
                printf "%s\t%s", t, st
            }' "$d/journal.tsv" 2>/dev/null)"
        if [[ -n "$s" ]]; then JS_LAST="${s%%$'\t'*}"; JS_LASTSTATE="${s#*$'\t'}"; fi
    fi

    [[ -d "$d/anchors" ]] && JS_ANCHORS="$(find "$d/anchors" -type f 2>/dev/null | wc -l | tr -dc '0-9')"
    [[ -f "$d/summary.tsv" ]] && JS_BYTES="$(awk -F'\t' '$1=="bytes_rewritten"{print $2}' "$d/summary.tsv")"
    [[ -n "$JS_BYTES" ]] || JS_BYTES=0

    # Orphan temps still sitting in the target tree. The depth is bounded on
    # purpose: this runs once per listed job, and an unbounded walk over a media
    # library would make --status take minutes.
    [[ -n "$JS_TARGET" && -d "$JS_TARGET" ]] \
        && JS_TMP="$(find "$JS_TARGET" -maxdepth 4 -name '.zrw-*' 2>/dev/null | wc -l | tr -dc '0-9')"

    [[ -n "$JS_TOTAL"   ]] || JS_TOTAL=0
    [[ -n "$JS_ANCHORS" ]] || JS_ANCHORS=0
    [[ -n "$JS_TMP"     ]] || JS_TMP=0
    return 0
}

show_status() {
    mkdir -p -- "$STATE_ROOT"
    local filter="" d jid pct first=1
    [[ -n "$TARGET_DIR" ]] && resolve_dir "$TARGET_DIR" && filter="$TARGET_DIR"
    (( JSON_OUT )) && printf '{"version":"%s","jobs":[' "$VERSION"
    (( JSON_OUT )) || { raw "ZFS REBLOCK WORKER v$VERSION - JOBS EN $STATE_ROOT"
                        [[ -n "$filter" ]] && raw "Filtro: $filter"
                        raw "=============================================================="; }
    shopt -s nullglob
    for d in "$STATE_ROOT"/ZRW-*; do
        [[ -f "$d/config.env" ]] || continue
        jid="${d##*/}"; job_stats "$jid"
        [[ -n "$filter" && "$JS_TARGET" != "$filter" ]] && continue
        pct=0; (( JS_TOTAL>0 )) && pct=$(( (JS_DONE+JS_SKIP)*100/JS_TOTAL ))
        local alive="no"; [[ -n "$JS_PID" ]] && kill -0 "$JS_PID" 2>/dev/null && alive="si"
        if (( JSON_OUT )); then
            (( first )) || printf ','; first=0
            printf '{"job_id":"%s","target":"%s","candidates":%s,"done":%s,"skipped":%s,"pending":%s,"failed":%s,"stale":%s,"progress_pct":%s,"running":"%s","orphan_temps":%s}' \
                "$(jesc "$jid")" "$(jesc "$JS_TARGET")" "$JS_TOTAL" "$JS_DONE" "$JS_SKIP" "$JS_PEND" "$JS_FAIL" "$JS_STALE" "$pct" "$alive" "$JS_TMP"
        else
            printf '\n%s\n' "$jid"
            printf '  directorio  : %s\n  inventario  : %-6s progreso: %s%%   en ejecucion: %s\n' "$JS_TARGET" "$JS_TOTAL" "$pct" "$alive"
            printf '  completados : %-6s omitidos: %-6s pendientes: %s\n  fallidos    : %-6s stale   : %s\n' "$JS_DONE" "$JS_SKIP" "$JS_PEND" "$JS_FAIL" "$JS_STALE"
            if (( JS_TMP )); then
                if [[ "$alive" == "si" ]]; then
                    printf '  temporales  : %s archivo(s) .zrw-* en el arbol (puede incluir el temporal activo de la copia en curso, no necesariamente residuos)\n' "$JS_TMP"
                else
                    printf '  temporales  : %s residuos .zrw-* en el arbol\n' "$JS_TMP"
                fi
            fi
            [[ -f "$d/summary.json" ]] && printf '  resumen     : %s\n' "$d/summary.json"
        fi
    done
    shopt -u nullglob
    (( JSON_OUT )) && printf ']}\n'
    return 0
}

# --explain: why this file would (or would not) be processed, and under which
# guarantees. Reads only; modifies nothing.
explain_file() {
    local f="$1" hint req avail
    resolve_dir "$(dirname -- "$f")" || die "$EX_USAGE" "No se pudo resolver el directorio de '$f'."
    [[ -f "$f" ]] || die "$EX_USAGE" "No es un archivo regular: $f"
    # --explain does not go through preflight, so the two things the verdict
    # depends on -- the dataset map and this host's capabilities -- have to be
    # established here, or the answer would differ from what a real run does.
    map_datasets || die "$EX_NOT_ZFS" "No se pudo enumerar los datasets ZFS."
    probe_acl_capabilities
    discover_dataset || die "$EX_NOT_ZFS" "No se pudo identificar el dataset ZFS de '$f'."
    file_dataset_ok "$f" || true
    snapshot_file "$f" || die "$EX_INTERNAL" "No se pudo leer la metadata de '$f'."
    hint="$(zfs_hint "$f")"; req="$(space_needed "$F_SIZE")"; avail="$(space_free "$(dirname -- "$f")")" || avail=0
    raw "=============================================================="
    raw "  POR QUE ESTE ARCHIVO SERIA O NO PROCESADO"
    raw "=============================================================="
    printf '  Archivo        : %s\n  Dataset        : %s (mountpoint %s)\n' "$f" "$ZFS_DATASET" "$ZFS_MOUNT"
    printf '  recordsize     : actual=%s esperado=%s\n\n' "$(dataset_recordsize "$ZFS_DATASET")" "$EXPECTED_RECORDSIZE"
    raw "  SELECCION"
    if (( F_SIZE > THRESHOLD_BYTES )); then printf '    [SI] supera el umbral: %s > %s\n' "$(human "$F_SIZE")" "$(human "$THRESHOLD_BYTES")"
    else printf '    [NO] no supera el umbral: %s <= %s\n' "$(human "$F_SIZE")" "$(human "$THRESHOLD_BYTES")"; fi
    if (( F_NLINK > 1 )); then printf '    [NO] hardlink (nlink=%s) -> SKIPPED\n' "$F_NLINK"
    else printf '    [SI] sin hardlinks (nlink=%s)\n' "$F_NLINK"; fi
    printf '    [--] inspeccion ZFS advisory: %s (nunca decide por si sola)\n\n' "$hint"
    raw "  ESPACIO"
    printf '    requerido (tamano + margen %s%%/min %s) : %s\n' "$MARGIN_PCT" "$(human "$MARGIN_MIN")" "$(human "$req")"
    printf '    disponible                             : %s -> %s\n\n' "$(human "$avail")" "$( (( avail >= req )) && echo OK || echo INSUFICIENTE)"
    raw "  GARANTIAS QUE SE APLICARIAN"
    printf '    integridad                     : %s\n' "$INTEGRITY"
    printf '    hash %-10s origen -> temporal : %s\n' "$HASH_ALGO" "$( [[ "$INTEGRITY" == standard ]] && echo no || echo si)"
    printf '    hash %-10s post-commit       : %s\n' "$HASH_ALGO" "$( [[ "$INTEGRITY" == maximum ]] && echo si || echo no)"
    printf '    atime / mtime                  : capturados y restaurados (%s / %s)\n' "$F_ATIME" "$F_MTIME"
    printf '    mode/uid/gid                   : %s / %s / %s\n' "$F_MODE" "$F_UID" "$F_GID"
    printf '    ACL y xattr                    : acltype=%s -> %s\n' "${FILE_DS_ACL:-?}" "${FILE_VERIFIER:-NINGUNO: este archivo se omitiria}"
    printf '    sparse                         : rsync -S\n'
    printf '    temporal                       : mismo directorio (%s)\n' "$(dirname -- "$f")"
    printf '    ancla de rollback              : hardlink al inode original (coste de espacio 0)\n'
    printf '    commit                         : rename atomico, reversible hasta verificar\n\n'
    raw "  El worker NO cambia el recordsize del dataset."
    raw "=============================================================="
    return 0
}

# -----------------------------------------------------------------------------
# [18] Profiles, preferences, wizard and directory browser.
# -----------------------------------------------------------------------------
# Profiles live in a file so they are the operator's numbers, not numbers this
# worker invented about hardware it has never seen.
load_profile() {
    [[ "$PROFILE" == default ]] && return 0
    local line name rest bw mn mx cd gov
    if [[ -f "$PROFILES_FILE" ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"; [[ "$line" == *=* ]] || continue
            name="${line%%=*}"; rest="${line#*=}"; name="${name//[[:space:]]/}"
            [[ "$name" == "$PROFILE" ]] || continue
            IFS=',' read -r bw mn mx cd gov <<<"${rest//[[:space:]]/}"
            is_bw "$bw" && BW_TARGET="$bw"; is_bw "$mn" && BW_MIN="$mn"; is_bw "$mx" && BW_MAX="$mx"
            is_int "$cd" && COOLDOWN="$cd"
            case "$gov" in off|auto|guarded) ADAPTIVE="$gov" ;; esac
            return 0
        done <"$PROFILES_FILE"
    fi
    case "$PROFILE" in
        slow-hdd)     BW_TARGET=20M BW_MIN=8M  BW_MAX=40M  COOLDOWN=45 ADAPTIVE=guarded ;;
        fast-storage) BW_TARGET=80M BW_MIN=20M BW_MAX=160M COOLDOWN=10 ADAPTIVE=auto ;;
        night)        BW_TARGET=35M BW_MIN=10M BW_MAX=80M  COOLDOWN=30 ADAPTIVE=auto ;;
        conservative) BW_TARGET=15M BW_MIN=8M  BW_MAX=30M  COOLDOWN=60 ADAPTIVE=guarded ;;
        *) die "$EX_USAGE" "Perfil desconocido: $PROFILE (ver $PROFILES_FILE)" ;;
    esac
    return 0
}

save_profile() {
    local n="$1" t
    [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]] || { warn "Nombre de perfil invalido: $n"; return 1; }
    mkdir -p -- "$(dirname -- "$PROFILES_FILE")"
    [[ -f "$PROFILES_FILE" ]] || printf '# ZFS Reblock Worker profiles\n' >"$PROFILES_FILE"
    t="$PROFILES_FILE.tmp.$$"
    grep -v "^[[:space:]]*${n}[[:space:]]*=" "$PROFILES_FILE" >"$t" 2>/dev/null || : >"$t"
    printf '%-12s = %s, %s, %s, %s, %s\n' "$n" "$BW_TARGET" "$BW_MIN" "$BW_MAX" "$COOLDOWN" "$ADAPTIVE" >>"$t"
    mv -f -- "$t" "$PROFILES_FILE" && say "Perfil '$n' guardado en $PROFILES_FILE"
}

save_last_dir() { mkdir -p -- "$RUNTIME_DIR" 2>/dev/null && printf 'LAST_DIR=%q\n' "$1" >"$PREFS_FILE" 2>/dev/null; return 0; }
# shellcheck source=/dev/null
load_last_dir() { LAST_DIR=""; [[ -f "$PREFS_FILE" ]] && { source "$PREFS_FILE" 2>/dev/null || true; }; return 0; }

browse_bash() {
    local cur="$1" c e subs
    [[ -d "$cur" ]] || cur=/
    while :; do
        printf '\nDirectorio actual: %s\n' "$cur" >&2
        printf '  0) Seleccionar este  1) Subir  2) Escribir ruta  3) Listar subdirectorios  q) Cancelar\n' >&2
        read -r -p 'Opcion: ' c || return 1
        case "$c" in
            0) printf '%s\n' "$cur"; return 0 ;;
            1) [[ "$cur" != / ]] && cur="$(dirname -- "$cur")" ;;
            2) read -r -p 'Ruta: ' e || return 1; resolve_dir "$e" && cur="$TARGET_DIR" || warn "Ruta invalida." ;;
            3) subs="$(find "$cur" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)"
               [[ -z "$subs" ]] && { warn "Sin subdirectorios."; continue; }
               printf '%s\n' "$subs" | sed 's/^/    /' >&2
               read -r -p 'Nombre (ENTER vuelve): ' e || return 1
               [[ -n "$e" ]] && { resolve_dir "$cur/$e" && cur="$TARGET_DIR" || warn "Ruta invalida."; } ;;
            q|Q) return 1 ;;
        esac
    done
}

browse_menu() {   # shared whiptail/dialog implementation
    local tool="$1" cur="$2" opts c d base next
    [[ -d "$cur" ]] || cur=/
    while :; do
        opts=(SELECT "Seleccionar: $cur" UP ".. (subir)" TYPE "Escribir una ruta")
        while IFS= read -r d; do base="$(basename -- "$d")"; opts+=("DIR:$base" "$base/"); done \
            < <(find "$cur" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n 200)
        if [[ "$tool" == whiptail ]]; then
            c="$(whiptail --title "Selector de directorio" --menu "Ubicacion: $cur" 22 90 14 "${opts[@]}" 3>&1 1>&2 2>&3)" || return 1
        else
            c="$(dialog --stdout --title "Selector de directorio" --menu "Ubicacion: $cur" 22 90 14 "${opts[@]}")" || return 1
        fi
        case "$c" in
            SELECT) printf '%s\n' "$cur"; return 0 ;;
            UP) [[ "$cur" != / ]] && cur="$(dirname -- "$cur")" ;;
            TYPE) if [[ "$tool" == whiptail ]]; then next="$(whiptail --inputbox "Ruta:" 10 80 "$cur" 3>&1 1>&2 2>&3)" || continue
                  else next="$(dialog --stdout --inputbox "Ruta:" 10 80 "$cur")" || continue; fi
                  resolve_dir "$next" && cur="$TARGET_DIR" ;;
            DIR:*) resolve_dir "$cur/${c#DIR:}" && cur="$TARGET_DIR" ;;
        esac
    done
}

browse_fzf() {
    local cur="$1" p
    [[ -d "$cur" ]] || cur=/
    while :; do
        p="$( { printf '.  (SELECCIONAR ESTE DIRECTORIO)\n..\n'
                find "$cur" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; } \
              | fzf --prompt="$cur > " --height=90% )" || return 1
        case "$p" in
            '.  (SELECCIONAR ESTE DIRECTORIO)') printf '%s\n' "$cur"; return 0 ;;
            '..') [[ "$cur" != / ]] && cur="$(dirname -- "$cur")" ;;
            *) resolve_dir "$cur/$p" && cur="$TARGET_DIR" ;;
        esac
    done
}

# The fancy browser is a convenience, never a requirement.
browse() {
    detect_browser
    case "$BROWSER" in
        whiptail|dialog) browse_menu "$BROWSER" "$1" ;;
        fzf) browse_fzf "$1" ;;
        *) (( TTY )) && say "Sin whiptail/dialog/fzf: selector basico integrado." >&2; browse_bash "$1" ;;
    esac
}

latest_job() {
    local d n="" t bt=0
    shopt -s nullglob
    for d in "$STATE_ROOT"/ZRW-*; do
        [[ -f "$d/config.env" ]] || continue
        t="$(stat -c '%Y' -- "$d" 2>/dev/null || printf 0)"
        (( t > bt )) && { bt="$t"; n="${d##*/}"; }
    done
    shopt -u nullglob
    [[ -n "$n" ]] && printf '%s\n' "$n"
}

# The wizard is state-aware: before offering anything it looks at what exists.
wizard_resume() {
    local jid="$1" c
    job_stats "$jid"
    raw "=============================================================="
    if (( JS_PEND == 0 && JS_FAIL == 0 && JS_STALE == 0 && JS_TOTAL > 0 )); then raw "  TRABAJO COMPLETO"
    else raw "  TRABAJO ANTERIOR ENCONTRADO"; fi
    raw "=============================================================="
    printf '  Job           : %s\n  Directorio    : %s\n' "$jid" "$JS_TARGET"
    [[ -n "$JS_LAST" ]] && printf '  Ultima activ. : %s   (ultimo evento: %s)\n' "$JS_LAST" "$JS_LASTSTATE"
    printf '  Inventario    : %s archivos\n' "$JS_TOTAL"
    local pct=0; (( JS_TOTAL>0 )) && pct=$(( (JS_DONE+JS_SKIP)*100/JS_TOTAL ))
    printf '  Progreso      : [%s] %s%%   (%s reescritos, %s)\n' "$(bar "$pct")" "$pct" "$JS_DONE" "$(human "$JS_BYTES")"
    printf '  Completados %s%-6s%s Omitidos %-6s Pendientes %s%-6s%s Fallidos %s%-6s%s Modificados %s\n' \
        "$C_G" "$JS_DONE" "$C_OFF" "$JS_SKIP" "$C_B" "$JS_PEND" "$C_OFF" \
        "$( (( JS_FAIL )) && printf '%s' "$C_R" || printf '%s' "$C_OFF")" "$JS_FAIL" "$C_OFF" "$JS_STALE"
    if (( JS_INFLIGHT || JS_TMP || JS_ANCHORS )); then
        printf '\n  %sRECUPERACION PENDIENTE%s\n' "$C_C" "$C_OFF"
        (( JS_INFLIGHT )) && printf '    %s archivo(s) quedaron en PROCESSING/VERIFYING al detenerse el worker.\n' "$JS_INFLIGHT"
        (( JS_INFLIGHT )) && printf '    Su estado real se verificara contra el filesystem antes de continuar.\n'
        (( JS_TMP ))      && printf '    %s temporal(es) .zrw-* en el arbol; iran a cuarentena, nunca se promueven.\n' "$JS_TMP"
        (( JS_ANCHORS ))  && printf '    %s ancla(s) de rollback registradas; se resolveran comparando inodes.\n' "$JS_ANCHORS"
    fi
    raw "--------------------------------------------------------------"
    (( JS_PEND ))  && raw "  [1] Continuar este trabajo"
    (( JS_FAIL ))  && raw "  [2] Reintentar los $JS_FAIL FAILED"
    (( JS_STALE )) && raw "  [3] Revalidar los $JS_STALE STALE"
    raw "  [4] Ver estado detallado"
    raw "  [5] Refrescar inventario (buscar nuevos candidatos)"
    raw "  [6] Empezar un trabajo nuevo"
    raw "  [Q] Salir"
    read -r -p 'Seleccione: ' c || exit "$EX_OK"
    case "$c" in
        1) JOB_ID="$jid"; RESUME=1 ;;
        2) JOB_ID="$jid"; RESUME=1; RETRY_FAILED=1 ;;
        3) JOB_ID="$jid"; RESUME=1; RETRY_STALE=1 ;;
        4) show_status; exit "$EX_OK" ;;
        5) JOB_ID="$jid"; RESUME=1; REFRESH_INV=1 ;;
        6) return 1 ;;
        *) exit "$EX_OK" ;;
    esac
    return 0
}

wizard() {
    mkdir -p -- "$STATE_ROOT"
    local c v prev start
    prev="$(latest_job)" && { wizard_resume "$prev" && return 0; }
    raw "=============================================================="
    raw "  ZFS REBLOCK WORKER v$VERSION"
    raw "  Sin parametros: modo interactivo."
    raw "=============================================================="
    raw "  [1] Nuevo trabajo          [2] Continuar uno existente"
    raw "  [3] Ver estado             [4] Reintentar FAILED"
    raw "  [5] Simulacion (dry-run)   [6] Verificar el sistema (--check)"
    raw "  [Q] Salir"
    read -r -p 'Seleccione [1-6/Q]: ' c || exit "$EX_OK"
    case "$c" in
        3) show_status; exit "$EX_OK" ;;
        6) CHECK_ONLY=1; return 0 ;;
        2) read -r -p 'Job ID: ' JOB_ID || exit "$EX_OK"; RESUME=1; return 0 ;;
        4) read -r -p 'Job ID: ' JOB_ID || exit "$EX_OK"; RETRY_FAILED=1; RESUME=1; return 0 ;;
        5) DRY_RUN=1 ;;
        1) ;;
        *) exit "$EX_OK" ;;
    esac

    load_last_dir; start=/mnt
    if [[ -n "${LAST_DIR:-}" && -d "${LAST_DIR:-}" ]]; then
        raw ""; raw "  Ultimo directorio utilizado: $LAST_DIR"
        read -r -p '  [ENTER] explorar desde ahi  [U] usarlo  [N] empezar en /mnt: ' v || true
        case "${v:-}" in u|U) TARGET_DIR="$LAST_DIR" ;; n|N) start=/mnt ;; *) start="$LAST_DIR" ;; esac
    fi
    [[ -n "$TARGET_DIR" ]] || { TARGET_DIR="$(browse "$start")" || exit "$EX_OK"; }
    save_last_dir "$TARGET_DIR"

    raw ""; raw "Configuracion (ENTER mantiene el valor, identico al V2):"
    ask() { read -r -p "  $1 [$2]: " v || true; [[ -n "${v:-}" ]] && printf '%s' "$v" || printf '%s' "$2"; }
    v=""; THRESHOLD_BYTES="$(to_bytes "$(ask 'Umbral de tamano' "$(human "$THRESHOLD_BYTES")")" 2>/dev/null || printf '%s' "$THRESHOLD_BYTES")"
    EXPECTED_RECORDSIZE="$(ask 'Recordsize esperado (el worker NO lo cambia)' "$EXPECTED_RECORDSIZE")"
    BW_TARGET="$(ask 'Limite de I/O' "$BW_TARGET")"
    NICE_VALUE="$(ask 'nice' "$NICE_VALUE")"
    IONICE_CLASS="$(ask 'ionice class (3=idle)' "$IONICE_CLASS")"
    COOLDOWN="$(ask 'Cooldown entre archivos (s)' "$COOLDOWN")"
    MARGIN_PCT="$(ask 'Margen de espacio (%)' "$MARGIN_PCT")"
    WORKERS="$(ask 'Workers en paralelo (1 = recomendado)' "$WORKERS")"
    ADAPTIVE="$(ask 'Governor [off/auto/guarded]' "$ADAPTIVE")"
    ADAPTIVE_PRIORITY="$(ask 'Prioridad adaptativa [on/off]' "$ADAPTIVE_PRIORITY")"
    raw "  Integridad: standard = tamano+rsync | strict = hash pre-commit | maximum = + post-commit"
    INTEGRITY="$(ask 'Integridad' "$INTEGRITY")"
    PROFILE="$(ask 'Perfil' "$PROFILE")"; [[ "$PROFILE" != default ]] && load_profile

    raw ""; raw "=============================================================="
    raw "  RESUMEN DEL TRABAJO"
    raw "=============================================================="
    printf '  Directorio     %s\n  Umbral         > %s\n  Recordsize     %s\n' "$TARGET_DIR" "$(human "$THRESHOLD_BYTES")" "$EXPECTED_RECORDSIZE"
    printf '  BW             %s (min %s / max %s)\n  nice / ionice  %s / %s\n' "$BW_TARGET" "$BW_MIN" "$BW_MAX" "$NICE_VALUE" "$IONICE_CLASS"
    printf '  Cooldown       %s s (%s)\n  Margen espacio %s%% (min %s)\n' "$COOLDOWN" "$COOLDOWN_MODE" "$MARGIN_PCT" "$(human "$MARGIN_MIN")"
    printf '  Workers        %s\n  Governor       %s (prioridad adaptativa %s)\n' "$WORKERS" "$ADAPTIVE" "$ADAPTIVE_PRIORITY"
    printf '  Integridad     %s   perfil %s\n' "$INTEGRITY" "$PROFILE"
    raw ""
    raw "  SIEMPRE ACTIVO (no configurable)"
    raw "    lock exclusivo - temporal + rename atomico - ancla de rollback"
    raw "    hash criptografico y verificacion post-commit - atime/mtime/ACL/xattr/mode/uid/gid"
    raw "    el recordsize del dataset NO se modifica"
    raw "=============================================================="
    read -r -p '[ENTER] Comenzar  [G] Guardar como perfil  [Q] Cancelar: ' v || exit "$EX_OK"
    [[ "${v:-}" =~ ^[qQ]$ ]] && exit "$EX_OK"
    [[ "${v:-}" =~ ^[gG]$ ]] && { read -r -p 'Nombre del perfil: ' v || true; [[ -n "${v:-}" ]] && save_profile "$v"; }
    return 0
}

# -----------------------------------------------------------------------------
# [19] CLI.
# -----------------------------------------------------------------------------
usage() {
cat <<EOF
zfs-reblock-worker.sh v$VERSION

Uso:
  $0                              Wizard interactivo (incluye explorador)
  $0 /ruta                        Ejecucion directa con los defaults del V2
  $0 /ruta --bwlimit 20M --adaptive guarded
  $0 /ruta --dry-run              Simulacion; no crea job ni toca archivos
  $0 /ruta --dry-run --ui json    Simulacion desatendida, salida machine-readable
  $0 --check                      Verifica el sistema y sale
  $0 --explain /ruta/archivo      Explica que haria con ese archivo
  $0 --status [/ruta] [--json]
  $0 --job ZRW-... --resume | --retry-failed | --retry-stale

Seleccion y objetivo:
  --threshold SIZE         tamano minimo de candidato (2G)
  --recordsize SIZE        recordsize esperado (1M); el dataset ya debe tenerlo
  --refresh-inventory      reconstruir el snapshot (alias --refresh)
  --one-dataset            no cruzar a datasets hijos (find -xdev)
  --cross-dataset MODE     skip | process | stop (skip)
                             que hacer con archivos de otro dataset del arbol
  --stale-policy MODE      auto | ask | skip | retry | refresh (auto)
                             auto = preguntar en terminal, omitir si desatendido

Un path como /mnt/pool puede abarcar varios datasets, otros pools, montajes no
ZFS y directorios .zfs. El worker mapea los datasets una vez y resuelve CADA
archivo contra ese mapa: comprueba el recordsize del dataset que realmente lo
contiene y su espacio libre real. Los .zfs nunca se recorren.

Rendimiento (el operador manda; AUTO solo optimiza por debajo de su techo):
  --bwlimit VALUE          BW objetivo (35M)
  --bw-min / --bw-max      limites del governor (10M / 80M)
  --adaptive MODE          off | auto | guarded (auto)
  --adaptive-priority on|off   nice/ionice gobernados por el estado del servidor (off)
  --nice N / --ionice C    prioridad base (19 / 3=idle); tambien son el limite de AUTO
  --nice-min N             nice mas agresivo que AUTO puede usar (10)
  --ionice-min C           clase de I/O mas agresiva que AUTO puede usar (2)
  --cooldown SECONDS       pausa entre archivos (30)
  --cooldown-mode MODE     fixed | adaptive (fixed)
  --workers N              archivos en paralelo (1). Ver AVISO abajo.
  --health-interval SEC    muestreo del governor (10)
  --profile NAME           default | slow-hdd | fast-storage | night | conservative

Seguridad:
  --integrity LEVEL        standard | strict | maximum (strict)
                             standard = tamano + verificacion de rsync
                             strict   = + hash origen<->temporal pre-commit
                             maximum  = + relectura completa post-commit
                                        (~+33% de I/O de lectura; opcional)
  --hash ALGO              b2 | b3 | sha256 | md5 (b2)
                             b2     = BLAKE2b, default: criptografico, misma
                                      garantia que sha256, ~3x mas rapido
                             b3     = BLAKE3 (si esta instalado); fallback
                                      automatico de b2 si falta b2sum
                             sha256 = fallback final si no hay b2sum ni b3sum
                             md5    = el mas rapido; detecta corrupcion accidental,
                                      NO resiste manipulacion deliberada
  --space-margin PCT       margen de espacio en % (20)
  --retries N              reintentos por archivo (2)

Operacion desatendida:
  --ui MODE                auto | dash | plain | quiet | json (auto)
  --json                   equivalente a --ui json
  --quiet                  equivalente a --ui quiet
  --log-file PATH          copia del log en una ruta propia
  --stop-after N           detenerse tras reescribir N archivos
  --stop-at HH:MM          detenerse al llegar esa hora
  --dry-sample N           en dry-run, leer N archivos completos para medir
                           el throughput real (solo lectura)
  --estimate               mostrar estimacion de duracion y comparativa de BW
  --no-color               salida sin color (tambien con NO_COLOR=1)
  --auto-resume            ante una pausa protectiva del governor (no ante
                           [P]/[Q] del operador ni disco lleno), esperar a
                           que la presion baje y continuar solo, sin salir
                           ni requerir --resume a mano
  --pause-timeout MIN      con --auto-resume, minutos maximos de espera antes
                           de rendirse y salir como siempre, codigo 13 (120)

Codigos de salida:
  0  ok            1  uso/validacion   10 requiere root    11 job bloqueado
  12 hubo FAILED   13 job pausado      14 error interno
  20 dependencia critica ausente       21 dependencia no funcional
  22 no es un dataset ZFS              23 recordsize distinto del esperado

POR QUE EXISTE ESTE WORKER
  Cambiar el recordsize de un dataset solo afecta a las escrituras nuevas. Los
  archivos que ya existen conservan el tamano de bloque con el que se
  escribieron, asi que un 'zfs set recordsize=1M' no los convierte. La unica
  forma de convertirlos es reescribirlos, y al reescribirlos NO deben perder su
  mtime ni su atime. Eso es exactamente lo que hace este worker.

AVISO sobre --workers: mas de 1 multiplica la presion sobre el pool. El BW
configurado se reparte entre los workers para respetar el techo del operador,
pero la latencia del almacenamiento sube igual. Para archivos delicados, 1.
EOF
}

parse_args() {
    (( $# )) || { wizard; return 0; }
    local a
    while (( $# )); do
        a="$1"
        case "$a" in
            --help|-h) usage; exit "$EX_OK" ;;
            --version) raw "$VERSION"; exit "$EX_OK" ;;
            # value-taking options, validated later in one place
            --bwlimit|--bw-min|--bw-max|--adaptive|--adaptive-priority|--threshold|\
            --recordsize|--nice|--ionice|--nice-min|--ionice-min|--cooldown|--cooldown-mode|\
            --space-margin|--retries|--health-interval|--profile|--integrity|--job|\
            --explain|--workers|--ui|--log-file|--stop-after|--stop-at|--dry-sample|\
            --hash|--cross-dataset|--stale-policy|--pause-timeout)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "$a requiere un valor"
                case "$a" in
                    --bwlimit) BW_TARGET="$2"; CLI_SET[BW_TARGET]=1 ;;
                    --bw-min) BW_MIN="$2"; CLI_SET[BW_MIN]=1 ;;
                    --bw-max) BW_MAX="$2"; CLI_SET[BW_MAX]=1 ;;
                    --adaptive) ADAPTIVE="$2"; CLI_SET[ADAPTIVE]=1 ;;
                    --adaptive-priority) ADAPTIVE_PRIORITY="$2"; CLI_SET[ADAPTIVE_PRIORITY]=1 ;;
                    --threshold) THRESHOLD_BYTES="$(to_bytes "$2")" || die "$EX_USAGE" "threshold invalido: $2"
                                 CLI_SET[THRESHOLD_BYTES]=1 ;;
                    --recordsize) EXPECTED_RECORDSIZE="$2"; CLI_SET[EXPECTED_RECORDSIZE]=1 ;;
                    --nice) NICE_VALUE="$2"; CLI_SET[NICE_VALUE]=1 ;;
                    --ionice) IONICE_CLASS="$2"; CLI_SET[IONICE_CLASS]=1 ;;
                    --nice-min) NICE_MIN="$2"; CLI_SET[NICE_MIN]=1 ;;
                    --ionice-min) IONICE_MIN="$2"; CLI_SET[IONICE_MIN]=1 ;;
                    --cooldown) COOLDOWN="$2"; CLI_SET[COOLDOWN]=1 ;;
                    --cooldown-mode) COOLDOWN_MODE="$2"; CLI_SET[COOLDOWN_MODE]=1 ;;
                    --space-margin) MARGIN_PCT="$2"; CLI_SET[MARGIN_PCT]=1 ;;
                    --retries) RETRIES="$2"; CLI_SET[RETRIES]=1 ;;
                    --health-interval) HEALTH_INTERVAL="$2"; CLI_SET[HEALTH_INTERVAL]=1 ;;
                    --profile) PROFILE="$2"; load_profile; CLI_SET[PROFILE]=1 ;;
                    --integrity) INTEGRITY="$2"; CLI_SET[INTEGRITY]=1 ;;
                    --job) JOB_ID="$2" ;;             --explain) EXPLAIN_PATH="$2" ;;
                    --workers) WORKERS="$2"; CLI_SET[WORKERS]=1 ;;
                    --ui) UI_MODE="$2" ;;
                    --log-file) LOG_FILE="$2" ;;      --stop-after) STOP_AFTER="$2" ;;
                    --stop-at) STOP_AT="$2" ;;        --dry-sample) DRY_SAMPLE="$2" ;;
                    --hash) HASH_ALGO="$2" ;;         --cross-dataset) CROSS_DATASET="$2" ;;
                    --stale-policy) STALE_POLICY="$2" ;;
                    --pause-timeout) PAUSE_TIMEOUT_MIN="$2" ;;
                esac; shift 2 ;;
            --new-job|--restart) JOB_ID=""; shift ;;
            --resume) RESUME=1; shift ;;
            --retry-failed) RETRY_FAILED=1; RESUME=1; shift ;;
            --retry-stale) RETRY_STALE=1; RESUME=1; shift ;;
            --refresh-inventory|--refresh) REFRESH_INV=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --one-dataset) ONE_DATASET=1; shift ;;
            --estimate) SHOW_ESTIMATE=1; shift ;;
            --auto-resume) AUTO_RESUME_PRESSURE=1; shift ;;
            --no-color) COLOR=0; set_palette; shift ;;
            --check) CHECK_ONLY=1; shift ;;
            --status) STATUS_ONLY=1; shift ;;
            --json) JSON_OUT=1; UI_MODE=json; shift ;;
            --quiet) UI_MODE=quiet; shift ;;
            --) shift; break ;;
            -*) die "$EX_USAGE" "Opcion desconocida: $a" ;;
            *) TARGET_DIR="$a"; shift ;;
        esac
    done
    return 0
}

validate() {
    is_bw "$BW_TARGET" || die "$EX_USAGE" "BW invalido: $BW_TARGET"
    is_bw "$BW_MIN" || die "$EX_USAGE" "BW min invalido: $BW_MIN"
    is_bw "$BW_MAX" || die "$EX_USAGE" "BW max invalido: $BW_MAX"
    (( $(to_bytes "$BW_MIN") <= $(to_bytes "$BW_MAX") )) || die "$EX_USAGE" "BW min > BW max."
    case "$ADAPTIVE" in off|auto|guarded) ;; *) die "$EX_USAGE" "adaptive invalido: $ADAPTIVE" ;; esac
    case "$ADAPTIVE_PRIORITY" in on|off) ;; *) die "$EX_USAGE" "adaptive-priority invalido: $ADAPTIVE_PRIORITY" ;; esac
    case "$INTEGRITY" in standard|strict|maximum) ;; *) die "$EX_USAGE" "integrity invalido: $INTEGRITY" ;; esac
    case "$COOLDOWN_MODE" in fixed|adaptive) ;; *) die "$EX_USAGE" "cooldown-mode invalido: $COOLDOWN_MODE" ;; esac
    case "$UI_MODE" in auto|dash|plain|quiet|json) ;; *) die "$EX_USAGE" "ui invalido: $UI_MODE" ;; esac
    case "$HASH_ALGO" in b2|b3|sha256|md5) ;; *) die "$EX_USAGE" "hash invalido: $HASH_ALGO (b2|b3|sha256|md5)" ;; esac
    case "$CROSS_DATASET" in skip|process|stop) ;; *) die "$EX_USAGE" "cross-dataset invalido: $CROSS_DATASET" ;; esac
    case "$STALE_POLICY" in auto|ask|skip|retry|refresh) ;; *) die "$EX_USAGE" "stale-policy invalido: $STALE_POLICY" ;; esac
    local n
    for n in COOLDOWN HEALTH_INTERVAL RETRIES MARGIN_PCT THRESHOLD_BYTES WORKERS STOP_AFTER DRY_SAMPLE; do
        is_int "${!n}" || die "$EX_USAGE" "$n invalido: ${!n}"
    done
    (( HEALTH_INTERVAL >= 1 )) || die "$EX_USAGE" "health-interval debe ser >= 1"
    (( WORKERS >= 1 && WORKERS <= 16 )) || die "$EX_USAGE" "workers fuera de rango (1..16)"
    [[ "$NICE_VALUE" =~ ^-?[0-9]+$ ]] && (( NICE_VALUE >= -20 && NICE_VALUE <= 19 )) || die "$EX_USAGE" "nice invalido"
    [[ "$NICE_MIN" =~ ^-?[0-9]+$ ]] && (( NICE_MIN >= -20 && NICE_MIN <= 19 )) || die "$EX_USAGE" "nice-min invalido"
    [[ "$IONICE_CLASS" =~ ^[123]$ ]] || die "$EX_USAGE" "ionice invalido"
    [[ "$IONICE_MIN" =~ ^[123]$ ]] || die "$EX_USAGE" "ionice-min invalido"
    to_bytes "$EXPECTED_RECORDSIZE" >/dev/null || die "$EX_USAGE" "recordsize invalido"
    [[ -z "$STOP_AT" ]] || [[ "$STOP_AT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "$EX_USAGE" "stop-at invalido (HH:MM)"
    # UI auto-resolution: a dashboard needs a terminal; otherwise plain text.
    [[ "$UI_MODE" == auto ]] && { (( TTY )) && UI_MODE=dash || UI_MODE=plain; }
    # Interactive only where a human can actually answer.
    if [[ "$STALE_POLICY" == auto ]]; then
        if (( TTY )) && [[ "$UI_MODE" != quiet && "$UI_MODE" != json ]]; then STALE_POLICY=ask; else STALE_POLICY=skip; fi
    fi
    # maximum re-reads every committed file in full. On multi-TB jobs that is
    # roughly a third more I/O, so the cost is stated rather than assumed.
    [[ "$INTEGRITY" == maximum ]] && warn         "integrity=maximum: cada archivo se relee completo tras el commit (~+33% de I/O de lectura). Para lotes de varios TB considera 'strict'." 
    (( WORKERS > 1 )) && warn "workers=$WORKERS: mayor presion sobre el pool; el BW se reparte entre workers."
    return 0
}

# Split out of validate() on purpose: validate() runs before the job is even
# resolved, so computing BW_BPS there meant a plain `--resume` (no --bwlimit)
# always started from the compiled default (35M), never from whatever
# BW_TARGET the job actually had saved -- load_config() had not run yet.
# Harmless under adaptive=auto (corrected within seconds), silent and wrong
# under `--adaptive off`: nothing would ever correct it back to the
# operator's real fixed rate. Called once load_config/CLI_SET have both had
# their say, right before a job actually starts running.
finalize_bw() {
    BW_BPS="$(to_bytes "$BW_TARGET")"; BW_CEIL_BPS="$BW_BPS"; COOLDOWN_BASE="$COOLDOWN"
    return 0
}

# -----------------------------------------------------------------------------
# [20] Main and the run loops.
# -----------------------------------------------------------------------------
cleanup() {
    [[ -n "$RSYNC_PID" ]] && kill -0 "$RSYNC_PID" 2>/dev/null && kill "$RSYNC_PID" 2>/dev/null
    # Orderly exits only. A power cut runs nothing here, which is exactly why
    # recover_temps/recover_anchors exist.
    [[ -n "$CUR_TMP" && -e "$CUR_TMP" ]] && { log "[CLEANUP] Eliminando temporal no comprometido: $CUR_TMP"; rm -f -- "$CUR_TMP"; }
    [[ -n "$CUR_ANCHOR" && -e "$CUR_ANCHOR" ]] && { log "[CLEANUP] Eliminando ancla de rollback: $CUR_ANCHOR"; drop_anchor; }
    return 0
}

# A trap only suppresses a signal's *default* action; it does not make the
# shell exit on its own. Registering the same handler for EXIT together
# with INT and TERM, with a cleanup() that never calls exit, meant Ctrl+C
# ran cleanup() and then simply resumed execution right after whatever was
# interrupted -- found live, in the wizard: one Ctrl+C skipped past a single
# `read` prompt instead of leaving, so it took one Ctrl+C per remaining
# question, and an empty answer at the end broke --profile validation. The
# same trap covers a real copy in progress too: an operator trying to abort
# a stuck job with Ctrl+C would have hit the identical non-exit. EXIT alone
# still runs cleanup() on every normal exit path; INT/TERM additionally call
# `exit` explicitly, with the signal's conventional 128+N code, which is
# what actually leaves -- and that `exit` itself re-fires the EXIT trap, so
# cleanup() only needs to be listed once.
trap cleanup EXIT
trap 'exit 130' INT     # 128 + SIGINT(2)
trap 'exit 143' TERM    # 128 + SIGTERM(15)
trap '' HUP    # survive an SSH disconnect; tmux/nohup remain the recommendation

# Environment can change under a job that runs for days.
env_sane() {
    local prev="$ZFS_DATASET" rec acl
    [[ -d "$TARGET_DIR" ]] || { err "El directorio objetivo ya no esta disponible: $TARGET_DIR"; return 1; }
    # Re-mapping is what makes the acltype check meaningful: a `zfs set
    # acltype=` mid-run has to be seen, not read back from a stale map.
    map_datasets || { err "Ya no se pueden enumerar los datasets ZFS."; return 1; }
    discover_dataset || { err "Ya no se puede identificar el dataset de '$TARGET_DIR'."; return 1; }
    [[ "$ZFS_DATASET" == "$prev" ]] || { err "El dataset cambio durante la ejecucion: '$prev' -> '$ZFS_DATASET'."; return 1; }
    rec="$(dataset_recordsize "$ZFS_DATASET")"
    [[ "$rec" == "$RUN_RECORDSIZE" ]] || { err "El recordsize cambio durante la ejecucion: '$rec'."; return 1; }
    # acltype is as load-bearing as recordsize: if it changes, the verifier the
    # job has been using stops being the right one, and a preserved-ACL claim
    # that was true for the first file would quietly stop being true.
    if dataset_for "$TARGET_DIR"; then
        acl="$DS_HIT_ACL"
        [[ -n "$(acl_verifier_for "$acl")" ]] || {
            err "El acltype de '$ZFS_DATASET' cambio a '${acl:-<vacio>}' y este host no puede verificarlo ($(acl_missing_for "$acl"))."
            return 1
        }
    fi
    return 0
}

stop_now() {
    (( STOP_AFTER > 0 && N_DONE >= STOP_AFTER )) && { log "[STOP] Limite de $STOP_AFTER archivos reescritos."; return 0; }
    if [[ -n "$STOP_AT" ]]; then
        local hm; hm="$(date '+%H:%M')"
        [[ "$hm" > "$STOP_AT" || "$hm" == "$STOP_AT" ]] && [[ "$STOP_AT" > "$JOB_START_HM" ]] \
            && { log "[STOP] Hora limite $STOP_AT alcanzada."; return 0; }
    fi
    return 1
}

measure_baseline() {
    [[ "$ADAPTIVE" != off ]] || return 0
    log "[AUTO-BASELINE] Observando el servidor ${BASELINE_SECONDS}s antes del primer archivo..."
    local i=0 sl=0 si=0 sm=0 sd=0 sp=0 per=$(( BASELINE_SECONDS/BASELINE_SAMPLES ))
    (( per<1 )) && per=1
    while (( i < BASELINE_SAMPLES )); do
        health_sample
        sl="$(awk -v a="$sl" -v b="$LOAD1" 'BEGIN{printf "%.4f",a+b}')"
        si=$(( si+IOWAIT )); sm=$(( sm+MEM )); sd=$(( sd+DISK_UTIL )); sp=$(( sp+PSI_IO ))
        i=$(( i+1 )); dashboard; sleep "$per"
    done
    BASE_LOAD="$(awk -v s="$sl" -v n="$i" 'BEGIN{printf "%.2f",s/n}')"
    BASE_IOWAIT=$(( si/i )); BASE_MEM=$(( sm/i )); BASE_DISK=$(( sd/i )); BASE_PSI=$(( sp/i ))
    log "[AUTO-BASELINE] load=$BASE_LOAD iowait=${BASE_IOWAIT}% disco=${BASE_DISK}% psi-io=${BASE_PSI}% mem=${BASE_MEM}% estado=$HEALTH"
    if (( ! BW_MANUAL )); then
        local s; s="$(suggest_initial_bw "$BW_BPS")"
        (( s != BW_BPS )) && { log "[AUTO-BASELINE] BW inicial recomendado: $(bw_label "$s") (era $(bw_label "$BW_BPS"))"; BW_BPS="$s"; }
    fi
    return 0
}

# Decide whether this entry must be processed by this run.
selectable() {
    case "$ST_STATUS" in
        DONE|SKIPPED)
            if state_valid "$1"; then
                count_bytes "$ST_SIZE"
                [[ "$ST_STATUS" == DONE ]] && N_DONE=$((N_DONE+1)) || N_SKIP=$((N_SKIP+1))
                return 1
            fi
            # The checkpoint no longer matches the filesystem: re-evaluate.
            N_RECOV=$((N_RECOV+1))
            journal RECOVERED "$1" 0 0 "estado $ST_STATUS no coincide con el filesystem"
            log "[RECOVERY] ${1##*/} estaba en $ST_STATUS pero ya no coincide; se reevalua."
            ST_ATTEMPT=0 ST_SIZE="" ;;
        STALE)
            (( RETRY_STALE )) || { N_STALE=$((N_STALE+1)); count_bytes "$ST_SIZE"; return 1; }
            ST_SIZE="" ;;
        MISSING)
            [[ -f "$1" ]] || { N_MISS=$((N_MISS+1)); count_bytes "$ST_SIZE"; return 1; }
            ST_SIZE="" ;;
        FAILED)
            (( RETRY_FAILED )) || { N_FAIL=$((N_FAIL+1)); count_bytes "$ST_SIZE"; return 1; } ;;
    esac
    (( RETRY_FAILED )) && [[ "$ST_STATUS" != FAILED ]] && return 1
    (( RETRY_STALE ))  && [[ "$ST_STATUS" != STALE  ]] && return 1
    return 0
}

# One pass over the inventory. Runs in the parent (WORKERS=1) or in each child.
run_loop() {
    local line size mtime inode ds q key
    # Inventory reads use fd 3, not stdin: poll_keys()/read_control() read the
    # operator's keypress from fd 0 further down the call chain (process_one
    # -> run_rsync -> poll_keys), while this loop is still active. Sharing
    # fd 0 with the inventory file meant every keypress poll during a copy
    # silently consumed one byte of whichever inventory line came next,
    # eventually corrupting a real entry into an empty path -- found live,
    # by a real [Q] keypress mid-copy turning a later file into a phantom
    # MISSING record. fd 3 keeps the two reads from ever touching the same
    # stream.
    while IFS= read -r -u 3 line; do
        [[ -n "$line" ]] || continue
        if (( WORKER_ID == 0 )); then
            env_sane || { ENV_ABORT=1; err "Worker detenido de forma segura; estado guardado."; break; }
            stop_now && { PAUSE_REQ=1; break; }
        else
            read_control
        fi
        (( PAUSE_REQ || EXIT_REQ )) && break

        N_INDEX=$(( N_INDEX+1 ))
        IFS=$'\t' read -r size mtime inode ds q <<<"$line"; unq "$q"
        key="$(state_key "$QPATH")"
        load_state "$key"
        selectable "$QPATH" || continue
        if (( WORKERS > 1 )); then claim_file "$QPATH" "$key" || continue; fi
        process_one "$QPATH" "$key"
        dashboard
    done 3<"$INVENTORY"
    return 0
}

# Supervisor for parallel mode: children do the work, the parent owns the
# governor, the dashboard and the operator controls.
run_parallel() {
    local i pids=()
    publish_control
    for (( i=1; i<=WORKERS; i++ )); do
        ( WORKER_ID="$i"; UI_MODE=quiet; run_loop ) &
        pids+=("$!")
    done
    while :; do
        local alive=0 p
        for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
        (( alive )) || break
        governor_step; poll_keys; adapt_cooldown; publish_control
        tally_results; N_INDEX=$(( N_DONE+N_SKIP+N_FAIL+N_STALE+N_MISS ))
        dashboard; sleep 1
    done
    wait 2>/dev/null || true
    tally_results; N_INDEX=$(( N_DONE+N_SKIP+N_FAIL+N_STALE+N_MISS ))
    return 0
}

# Dry-run: no job, no state, no modification. Optionally reads a sample of
# candidates end to end to measure the real throughput of this pool.
do_dry_run() {
    local rec n=0 bytes=0 sz path bps eta out_ds=0 out_rs=0 hint1m=0 hintbytes=0 hc hl
    [[ -n "$TARGET_DIR" ]] || die "$EX_USAGE" "Dry-run requiere un directorio."
    resolve_dir "$TARGET_DIR" || die "$EX_USAGE" "Directorio objetivo invalido: $TARGET_DIR"
    map_datasets || die "$EX_NOT_ZFS" "No se pudo enumerar los datasets ZFS."
    discover_dataset || die "$EX_NOT_ZFS" "No se pudo identificar el dataset ZFS de '$TARGET_DIR'."
    usb_advisory
    rec="$(dataset_recordsize "$ZFS_DATASET")"
    probe_acl_capabilities
    survey_tree || true    # dry-run reports the problem, it does not refuse to report

    local -a cands=() csz=() chint=()
    while IFS= read -r -d '' path; do
        sz="$(stat -c '%s' -- "$path" 2>/dev/null)" || continue
        (( sz > THRESHOLD_BYTES )) || continue
        if ! file_dataset_ok "$path"; then
            case "$DS_SKIP_WHY" in
                *"otro dataset"*) out_ds=$((out_ds+1)) ;;
                *) out_rs=$((out_rs+1)) ;;
            esac
            continue
        fi
        n=$((n+1)); bytes=$(( bytes+sz )); cands+=("$path"); csz+=("$sz")
        # Advisory classification only. zdb never decides anything here either;
        # it just lets the operator see roughly how much may already be at the
        # target block size before committing to a multi-day run.
        local h; h="$(zfs_hint "$path")"; chint+=("$h")
        hint_matches_target "$h" && { hint1m=$((hint1m+1)); hintbytes=$(( hintbytes+sz )); }
    done < <(scan_tree)

    bps="$(to_bytes "$BW_TARGET")"; eta=$(( bytes/(bps>0?bps:1) + n*COOLDOWN ))

    # Optional read-only rehearsal: a measured read rate beats a theoretical ETA.
    local sample_bytes=0 sample_secs=0 real_bps=0 i t0
    if (( DRY_SAMPLE > 0 && n > 0 )); then
        t0="$(date +%s)"
        for (( i=0; i<DRY_SAMPLE && i<n; i++ )); do
            hash_of "${cands[$i]}" >/dev/null 2>&1 || true
            sample_bytes=$(( sample_bytes+csz[i] ))
        done
        sample_secs=$(( $(date +%s)-t0 )); (( sample_secs<1 )) && sample_secs=1
        real_bps=$(( sample_bytes/sample_secs ))
    fi


    if [[ "$UI_MODE" == json ]]; then
        printf '{"mode":"dry-run","version":"%s","target":"%s","dataset":"%s","datasets_in_tree":%s,' \
            "$VERSION" "$(jesc "$TARGET_DIR")" "$(jesc "$ZFS_DATASET")" "$TREE_DATASETS"
        printf '"recordsize_actual":"%s","recordsize_expected":"%s","recordsize_match":%s,' \
            "$(jesc "$rec")" "$(jesc "$EXPECTED_RECORDSIZE")" \
            "$( [[ "$rec" == "$EXPECTED_RECORDSIZE" ]] && echo true || echo false)"
        printf '"threshold_bytes":%s,"candidates":%s,"bytes":%s,' \
            "$THRESHOLD_BYTES" "$n" "$bytes"
        printf '"excluded_other_dataset":%s,"excluded_recordsize":%s,' \
            "$out_ds" "$out_rs"
        printf '"advisory_already_target":%s,"advisory_already_bytes":%s,"advisory_need_reblock":%s,' \
            "$hint1m" "$hintbytes" "$(( n-hint1m ))"
        printf '"free_bytes":%s,"eta_seconds":%s,"bwlimit":"%s","hash":"%s","integrity":"%s",' \
            "$(space_free "$TARGET_DIR" || echo 0)" "$eta" "$BW_TARGET" "$HASH_ALGO" "$INTEGRITY"
        printf '"sampled_files":%s,"sampled_bytes":%s,"measured_read_bps":%s,"workers":%s}\n' \
            "$(( DRY_SAMPLE<n ? DRY_SAMPLE : n ))" "$sample_bytes" "$real_bps" "$WORKERS"
        exit "$EX_OK"
    fi

    head_rule
    printf '  %sDRY-RUN%s  no se crea job, no se modifica ningun archivo\n' "$C_HDR" "$C_OFF"
    head_rule

    printf '  Target          : %s\n' "$TARGET_DIR"
    printf '  Dataset         : %s' "$ZFS_DATASET"
    (( TREE_DATASETS > 1 )) && printf ' %s(el arbol abarca %s datasets)%s' \
        "$C_Y" "$TREE_DATASETS" "$C_OFF"
    printf '\n'

    local rs_verdict
    if [[ "$rec" == "$EXPECTED_RECORDSIZE" ]]; then
        rs_verdict="$(printf '%s[OK]%s' "$C_G" "$C_OFF")"
    else
        rs_verdict="$(printf '%s[NO COINCIDE: el job real se detendria]%s' "$C_R" "$C_OFF")"
    fi
    printf '  recordsize      : actual=%s esperado=%s  %s\n' \
        "$rec" "$EXPECTED_RECORDSIZE" "$rs_verdict"
    printf '  Umbral          : > %s\n' "$(human "$THRESHOLD_BYTES")"
    printf '  Hash            : %s\n' "$HASH_ALGO"
    printf '  Integridad      : %s\n' "$INTEGRITY"
    rule

    # Per-file listing. The hint column prints the block size zdb reported so
    # the operator can see the evidence, not just our verdict on it.
    if [[ "$UI_MODE" != quiet ]]; then
        local hc hl
        for (( i=0; i<n; i++ )); do
            if hint_matches_target "${chint[$i]}"; then
                hc="$C_D"; hl="ya-$EXPECTED_RECORDSIZE?"
            else
                hc="$C_G"; hl="reblock"
            fi
            printf '  [%4d] %-12s %-14s %s%-12s%s %s\n' \
                "$((i+1))" "$(human "${csz[$i]}")" "dblk=${chint[$i]}" \
                "$hc" "$hl" "$C_OFF" "${cands[$i]#"$TARGET_DIR"/}"
        done
        rule
    fi

    # One field width for every label, including the two built at runtime.
    local W=27
    printf '  %-*s: %s\n' "$W" "Candidatos" "$n"
    printf '  %-*s: %s\n' "$W" "Datos a reescribir" "$(human "$bytes")"
    printf '  %s%-*s%s: %s  (%s)  -- pista advisory de zdb, NO se saltean\n' \
        "$C_D" "$W" "Posiblemente ya en $EXPECTED_RECORDSIZE" "$C_OFF" \
        "$hint1m" "$(human "$hintbytes")"
    printf '  %-*s: %s  (%s)\n' "$W" "Necesitan reblock (seguro)" \
        "$(( n-hint1m ))" "$(human "$(( bytes-hintbytes ))")"
    (( out_ds || out_rs )) && printf '  %s%-*s%s: %s de otro dataset, %s con otro recordsize\n' \
        "$C_Y" "$W" "Excluidos" "$C_OFF" "$out_ds" "$out_rs"
    printf '  %-*s: %s\n' "$W" "Espacio libre" \
        "$(human "$(space_free "$TARGET_DIR" || echo 0)")"

    if (( n > 0 )) && { (( SHOW_ESTIMATE )) || (( real_bps > 0 )); }; then
        rule
        printf '  %sESTIMACION%s (teorica; el tiempo real puede ser mayor)\n' "$C_B" "$C_OFF"
        printf '  a %-5s -> %s\n' "$BW_TARGET" "$(hms "$eta")"
        local b l
        for l in 20M 35M 50M 80M; do
            [[ "$l" == "$BW_TARGET" ]] && continue
            b="$(to_bytes "$l")"
            printf '  a %-5s -> %s\n' "$l" "$(hms $(( bytes/b + n*COOLDOWN )))"
        done
        if (( real_bps > 0 )); then
            printf '  lectura real medida: %s/s sobre %s archivo(s) (%s)\n' \
                "$(human "$real_bps")" "$(( DRY_SAMPLE<n ? DRY_SAMPLE : n ))" \
                "$(human "$sample_bytes")"
            printf '  %sETA con esa lectura: %s%s\n' \
                "$C_B" "$(hms $(( bytes/(real_bps>0?real_bps:1) + n*COOLDOWN )))" "$C_OFF"
        fi
    elif (( n > 0 )); then
        printf '  (usa %s--estimate%s para la estimacion de duracion y la comparativa de limites)\n' \
            "$C_B" "$C_OFF"
    fi

    printf '  %sNo se modifico ningun archivo.%s\n' "$C_G" "$C_OFF"
    head_rule
    exit "$EX_OK"
}

main() {
    parse_args "$@"
    (( STATUS_ONLY )) && { show_status; exit "$EX_OK"; }
    preflight
    (( CHECK_ONLY )) && { say "Verificacion completada. No se modifico ningun archivo."; exit "$EX_OK"; }
    validate
    [[ -n "$EXPLAIN_PATH" ]] && { explain_file "$EXPLAIN_PATH"; exit "$EX_OK"; }
    (( DRY_RUN )) && do_dry_run

    # ---- job resolution ----
    # --resume / --retry-* without --job fall back to the current-job pointer.
    if [[ -z "$JOB_ID" ]] && (( RESUME )); then
        JOB_ID="$(get_current_job || true)"
        [[ -n "$JOB_ID" ]] && log "Usando el trabajo actual: $JOB_ID"
    fi
    if [[ -n "$JOB_ID" ]]; then
        JOB_DIR="$STATE_ROOT/$JOB_ID"
        [[ -f "$JOB_DIR/config.env" ]] || die "$EX_USAGE" "Job no encontrado: $JOB_ID"
        CONFIG_FILE="$JOB_DIR/config.env"; load_config; init_job
        [[ -n "$TARGET_DIR" ]] || die "$EX_INTERNAL" "El job no contiene TARGET_DIR."
        resolve_dir "$TARGET_DIR" || die "$EX_USAGE" "El TARGET_DIR del job ya no existe: $TARGET_DIR"
        JOB_MODE=RESUME
    else
        [[ -n "$TARGET_DIR" ]] || die "$EX_USAGE" "No se indico directorio objetivo."
        resolve_dir "$TARGET_DIR" || die "$EX_USAGE" "Directorio objetivo invalido: $TARGET_DIR"
        JOB_ID="$(make_job_id)"; init_job; JOB_MODE=NEW
    fi
    (( RETRY_FAILED )) && JOB_MODE=RETRY-FAILED
    (( RETRY_STALE ))  && JOB_MODE=RETRY-STALE
    [[ -n "$LOG_FILE" ]] && { EVENT_LOG="$LOG_FILE"; touch "$EVENT_LOG"; }

    lock_job
    map_datasets || die "$EX_NOT_ZFS" "No se pudo enumerar los datasets ZFS."
    discover_dataset || die "$EX_NOT_ZFS" "No se pudo identificar el dataset ZFS de '$TARGET_DIR'."
    [[ "$JOB_MODE" == NEW ]] && usb_advisory   # once per job, not on every --resume

    # Fail-early. The worker demands the recordsize; it never sets it.
    local rec; rec="$(dataset_recordsize "$ZFS_DATASET")"
    if [[ "$rec" != "$EXPECTED_RECORDSIZE" ]]; then
        err "El dataset '$ZFS_DATASET' tiene recordsize='$rec' y se esperaba '$EXPECTED_RECORDSIZE'."
        err "El worker no lo modifica: es una decision explicita del administrador."
        err "Si corresponde:  zfs set recordsize=$EXPECTED_RECORDSIZE $ZFS_DATASET"
        exit "$EX_RECORDSIZE"
    fi
    (( RESUME )) && [[ -f "$CONFIG_FILE" ]] || save_config
    RUN_RECORDSIZE="$EXPECTED_RECORDSIZE" RUN_THRESHOLD="$THRESHOLD_BYTES"
    finalize_bw

    JOB_START="$(date +%s)"; JOB_START_HM="$(date '+%H:%M')"
    log "=============================================================="
    log "ZFS REBLOCK WORKER v$VERSION  [$JOB_MODE]"
    log "job=$JOB_ID  workers=$WORKERS"
    log "target=$TARGET_DIR  dataset=$ZFS_DATASET  mountpoint=$ZFS_MOUNT"
    log "recordsize=$EXPECTED_RECORDSIZE  umbral>$(human "$THRESHOLD_BYTES")"
    log "BW=$BW_TARGET (min $BW_MIN / max $BW_MAX) adaptive=$ADAPTIVE prioridad-adaptativa=$ADAPTIVE_PRIORITY"
    log "nice=$NICE_VALUE ionice=$IONICE_CLASS cooldown=${COOLDOWN}s ($COOLDOWN_MODE) retries=$RETRIES"
    log "integridad=$INTEGRITY  hash=$HASH_ALGO  perfil=$PROFILE"
    log "atime/mtime/ACL/xattr: PRESERVACION OBLIGATORIA | zdb: SOLO ADVISORY"
    log "=============================================================="

    survey_tree || die "$EX_DEP_MISSING" "El arbol no es verificable con las herramientas de este host."
    set_current_job
    apply_priority
    recover_temps
    recover_anchors
    recover_states

    if (( REFRESH_INV )) || [[ ! -s "$INVENTORY" ]]; then
        build_inventory || { write_summary; exit "$EX_OK"; }
    else
        count_inventory; log "Inventario snapshot existente: $N_TOTAL candidatos ($(human "$BYTES_PLANNED"))."
    fi
    init_pending
    measure_baseline

    N_INDEX=0
    if (( WORKERS > 1 )); then run_parallel; else run_loop; fi

    write_summary
    final_report
    (( N_FAIL > 0 )) && exit "$EX_FAILED"
    (( PAUSE_REQ || ENV_ABORT )) && exit "$EX_PAUSED"
    exit "$EX_OK"
}

# Tests source this file with ZRW_LIB_ONLY=1 to reach the pure functions.
[[ "${ZRW_LIB_ONLY:-0}" == 1 ]] || main "$@"
