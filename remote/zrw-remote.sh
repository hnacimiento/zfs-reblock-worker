#!/usr/bin/env bash
# =============================================================================
# zrw-remote.sh - drive the worker on a remote TrueNAS over SSH.
#
# Read-only by default, and deliberately hard to misuse: every mode that could
# modify a byte on the NAS is refused unless ZRW_ALLOW_WRITE=yes in the config
# AND the operator confirms interactively.
#
# Credentials never live here. The config names an SSH key path; nothing else.
#
# Usage:
#   ./remote/zrw-remote.sh discover     capability discovery (read-only)
#   ./remote/zrw-remote.sh check        system preflight on the NAS
#   ./remote/zrw-remote.sh dryrun       inventory + estimation, human readable
#   ./remote/zrw-remote.sh dryrun-json  same, machine readable
#   ./remote/zrw-remote.sh explain FILE why that file would be processed
#   ./remote/zrw-remote.sh tests        run the worker's own test benches there
#   ./remote/zrw-remote.sh status       state of the jobs staged on the NAS
#   ./remote/zrw-remote.sh all          env + discover + check + dryrun + tests
#   ./remote/zrw-remote.sh shell        interactive ssh in the staging dir
#   ./remote/zrw-remote.sh run          THE REAL THING - guarded, see above
#
# Everything the remote prints is saved under remote/results/<timestamp>/.
# =============================================================================
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$HERE/.." && pwd -P)"
CONF="${ZRW_REMOTE_CONF:-$HERE/zrw-remote.conf}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
OUTDIR="$HERE/results/$STAMP"

readonly EX_OK=0 EX_USAGE=1 EX_CONF=2 EX_SSH=3 EX_REFUSED=4

# $1 is the message and $2 the exit code, so printing "$*" glued the numeric
# code onto the end of every error text the operator reads.
die() { printf '[ERROR] %s\n' "$1" >&2; exit "${2:-$EX_USAGE}"; }
info() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# Help must work before any configuration exists, or the first run is a dead end.
case "${1:-}" in
    -h|--help|help)
        sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        printf '\nConfiguracion esperada en: %s\n' "$CONF"
        [[ -f "$CONF" ]] || printf 'Todavia no existe. Crealo con:\n  cp %s %s\n  chmod 600 %s\n' \
            "$HERE/zrw-remote.conf.example" "$CONF" "$CONF"
        exit "$EX_OK" ;;
esac

# --- configuration -----------------------------------------------------------
[[ -f "$CONF" ]] || die "Falta $CONF. Copia remote/zrw-remote.conf.example y completalo." "$EX_CONF"

# This file gets edited on Windows more often than not, and a CRLF in it is
# silent poison: ZRW_ALLOW_WRITE would come out as "no<CR>", which is not "no",
# and every path would carry a trailing carriage return. Strip the CRs before
# sourcing instead of making the operator debug that.
if LC_ALL=C grep -qU $'\r' "$CONF" 2>/dev/null; then
    printf '[WARN] %s tiene saltos de linea CRLF; se ignoran los CR al leerlo.\n' "$CONF" >&2
    CONF_CLEAN="$(mktemp)"
    trap 'rm -f -- "${CONF_CLEAN:-}"' EXIT
    tr -d '\r' <"$CONF" >"$CONF_CLEAN"
    # shellcheck disable=SC1090
    source "$CONF_CLEAN"
else
    # shellcheck disable=SC1090
    source "$CONF"
fi

: "${ZRW_HOST:=}" "${ZRW_USER:=root}" "${ZRW_PORT:=22}" "${ZRW_SSH_KEY:=}"
: "${ZRW_SSH_OPTS:=}" "${ZRW_TARGET:=}" "${ZRW_REMOTE_DIR:=/mnt/zrw}"
: "${ZRW_THRESHOLD:=2G}" "${ZRW_RECORDSIZE:=1M}" "${ZRW_BWLIMIT:=35M}"
: "${ZRW_INTEGRITY:=maximum}" "${ZRW_DRY_SAMPLE:=0}" "${ZRW_ALLOW_WRITE:=no}"
: "${ZRW_HASH:=sha256}" "${ZRW_WORKERS:=1}"
: "${ZRW_SSH_BIN:=ssh}" "${ZRW_SCP_BIN:=scp}"

[[ -n "$ZRW_HOST" ]] || die "ZRW_HOST vacio en $CONF." "$EX_CONF"
[[ -n "$ZRW_TARGET" ]] || die "ZRW_TARGET vacio en $CONF." "$EX_CONF"
[[ -n "$ZRW_SSH_KEY" ]] || die "ZRW_SSH_KEY vacio en $CONF (solo se admite autenticacion por llave)." "$EX_CONF"
KEY="${ZRW_SSH_KEY/#\~/$HOME}"
[[ -f "$KEY" ]] || die "No existe la llave SSH: $KEY" "$EX_CONF"
# A private key readable by others is a real finding, not a nitpick.
perms="$(stat -c '%a' -- "$KEY" 2>/dev/null || echo '')"
# On an NTFS path the POSIX bits are a fiction, so the warning would be noise:
# there the real permission is the NTFS ACL, which only Windows' own ssh reads.
case "$KEY" in
    /mnt/[a-z]/*|/[a-z]/*|[A-Za-z]:*) : ;;
    *) [[ -n "$perms" && "${perms: -2}" != "00" ]] \
        && printf '[WARN] %s tiene permisos %s; deberia ser 600.\n' "$KEY" "$perms" >&2 ;;
esac

command -v "$ZRW_SSH_BIN" >/dev/null 2>&1 || die "No existe el binario ssh indicado: $ZRW_SSH_BIN" "$EX_CONF"

# BatchMode: never hang waiting for a password prompt in an unattended run.
SSH_BASE=("$ZRW_SSH_BIN" -i "$KEY" -p "$ZRW_PORT" -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes)
# shellcheck disable=SC2206
[[ -n "$ZRW_SSH_OPTS" ]] && SSH_BASE+=($ZRW_SSH_OPTS)
DEST="$ZRW_USER@$ZRW_HOST"

rsh() { "${SSH_BASE[@]}" "$DEST" "$@"; }

# Every remote command below is assembled as ONE string and handed to ssh,
# which the far end re-parses with its own shell (zsh on this project's
# reference NAS, though the bug is not zsh-specific). Wrapping a value in
# literal single quotes breaks the instant that value itself contains one --
# and real media libraries are full of them ("O'Brien's ..."). `%q` produces
# a quoted form that survives the round trip; both bash and zsh understand it.
rq() { local q; printf -v q '%q' "$1"; printf '%s' "$q"; }

Q_TARGET="$(rq "$ZRW_TARGET")"
Q_REMOTE_DIR="$(rq "$ZRW_REMOTE_DIR")"

# --- staging -----------------------------------------------------------------
probe() {
    info "Probando conexion con $DEST:$ZRW_PORT"
    rsh true 2>/dev/null || die "No se pudo conectar por SSH a $DEST:$ZRW_PORT con $KEY" "$EX_SSH"
    local uid; uid="$(rsh 'id -u' 2>/dev/null || echo '')"
    [[ "$uid" == 0 ]] || printf '[WARN] El usuario remoto no es root (uid=%s); el worker exigira UID 0.\n' "${uid:-?}" >&2
    rsh "test -d $Q_TARGET" || die "El directorio remoto no existe: $ZRW_TARGET" "$EX_CONF"
}

stage() {
    info "Copiando el worker a $DEST:$ZRW_REMOTE_DIR"
    rsh "mkdir -p $Q_REMOTE_DIR/{tests,examples,remote}" || die "No se pudo crear $ZRW_REMOTE_DIR" "$EX_SSH"
    if command -v rsync >/dev/null 2>&1; then
        # remote/*** has to be in this filter: `discover` runs
        # remote/zrw-discovery.sh on the NAS, and without it that file is simply
        # not there. Only the scp fallback below ever copied it.
        rsync -az --delete-excluded \
            -e "$ZRW_SSH_BIN -i $KEY -p $ZRW_PORT -o BatchMode=yes -o IdentitiesOnly=yes" \
            --include='zfs-reblock-worker.sh' --include='tests/***' \
            --include='examples/***' --include='remote/***' \
            --exclude='*' "$ROOT/" "$DEST:$ZRW_REMOTE_DIR/" || die "rsync fallo" "$EX_SSH"
    else
        local SCP=("$ZRW_SCP_BIN" -q -i "$KEY" -P "$ZRW_PORT" -o BatchMode=yes -o IdentitiesOnly=yes)
        "${SCP[@]}" "$ROOT/zfs-reblock-worker.sh" "$DEST:$ZRW_REMOTE_DIR/" || die "scp fallo" "$EX_SSH"
        "${SCP[@]}" "$ROOT"/tests/*.sh          "$DEST:$ZRW_REMOTE_DIR/tests/"    || true
        "${SCP[@]}" "$ROOT"/examples/*.conf     "$DEST:$ZRW_REMOTE_DIR/examples/" || true
        "${SCP[@]}" "$ROOT"/remote/*.sh          "$DEST:$ZRW_REMOTE_DIR/remote/"   || true
    fi
    rsh "chmod +x $Q_REMOTE_DIR/zfs-reblock-worker.sh $Q_REMOTE_DIR/tests/*.sh $Q_REMOTE_DIR/remote/*.sh 2>/dev/null; true"
    # Fail loudly here rather than with a confusing "No such file" three steps on.
    rsh "test -s $Q_REMOTE_DIR/remote/zrw-discovery.sh" \
        || die "La sonda no quedo en $ZRW_REMOTE_DIR/remote/. Revisa el filtro de rsync." "$EX_SSH"
}

# Every remote invocation is captured to a file and echoed locally.
STEPS=()
capture() {
    local name="$1"; shift
    mkdir -p -- "$OUTDIR"
    info "$name"
    { printf '### %s\n### %s\n### %s\n\n' "$name" "$(date -Is)" "$*"; } >"$OUTDIR/$name.txt"
    rsh "$@" 2>&1 | tee -a "$OUTDIR/$name.txt"
    local rc="${PIPESTATUS[0]}"
    printf '\n### exit code: %s\n' "$rc" >>"$OUTDIR/$name.txt"
    printf '    (guardado en %s)\n' "$OUTDIR/$name.txt"
    STEPS+=("$name:$rc")
    return "$rc"
}

# The worker's exit codes are semantic on purpose. Translating them here is the
# difference between "algo fallo" and knowing which tool to install.
why() {
    case "$1" in
        0)  printf 'OK' ;;
        1)  printf 'uso o configuracion invalida' ;;
        10) printf 'se requiere UID 0 en el NAS' ;;
        11) printf 'otro worker tiene el job tomado' ;;
        12) printf 'termino con archivos en FAILED' ;;
        13) printf 'se detuvo antes de tiempo (espacio, operador o governor)' ;;
        14) printf 'condicion interna inesperada' ;;
        20) printf 'falta una dependencia critica, o ningun dataset es verificable (ACL)' ;;
        21) printf 'un comando existe pero no funciona' ;;
        22) printf 'el objetivo no esta en un dataset ZFS identificable' ;;
        23) printf 'el recordsize del dataset no es el esperado' ;;
        *)  printf 'codigo no reconocido' ;;
    esac
}

report() {
    local e n rc bad=0
    printf '\n==============================================================\n'
    printf '  RESUMEN  (%s)\n' "$OUTDIR"
    printf '==============================================================\n'
    for e in "${STEPS[@]:-}"; do
        [[ -n "$e" ]] || continue
        n="${e%:*}"; rc="${e##*:}"
        if [[ "$rc" == 0 ]]; then printf '  \033[32m[OK]\033[0m   %-14s\n' "$n"
        else printf '  \033[31m[%3s]\033[0m  %-14s %s\n' "$rc" "$n" "$(why "$rc")"; bad=1; fi
    done
    printf '==============================================================\n'
    (( bad )) && printf '  Revisa los .txt del directorio antes de pasar a la etapa siguiente.\n'
    return 0
}

W="$ZRW_REMOTE_DIR/zfs-reblock-worker.sh"
Q_W="$(rq "$W")"
COMMON="--threshold '$ZRW_THRESHOLD' --recordsize '$ZRW_RECORDSIZE' --bwlimit '$ZRW_BWLIMIT'"
COMMON="$COMMON --integrity '$ZRW_INTEGRITY' --hash '$ZRW_HASH' --workers '$ZRW_WORKERS'"

# Capability discovery. Read-only unless ZRW_SCRATCH_DIR is set in the config,
# in which case one real file is copied into that directory and removed again.
do_discover() {
    local extra=""
    # The round-trip is opt-in and writes into the source file's own directory,
    # which is the only placement that reproduces the worker faithfully.
    [[ "${ZRW_PROBE_WRITE:-no}" == yes ]] && extra=" --probe-write"
    [[ -n "${ZRW_STATE_DIR:-}" ]] && extra="$extra --state-dir $(rq "$ZRW_STATE_DIR")"
    [[ -n "${ZRW_SCRATCH_DIR:-}" ]] && extra="$extra --scratch $(rq "$ZRW_SCRATCH_DIR")"
    capture discovery "cd $Q_REMOTE_DIR && bash remote/zrw-discovery.sh $Q_TARGET$extra"
}

do_check()   { capture check "cd $Q_REMOTE_DIR && $Q_W --check"; }
do_dryrun()  { capture dryrun "cd $Q_REMOTE_DIR && $Q_W $Q_TARGET $COMMON --dry-run --dry-sample '$ZRW_DRY_SAMPLE'"; }
do_dryjson() { capture dryrun-json "cd $Q_REMOTE_DIR && $Q_W $Q_TARGET $COMMON --dry-run --ui json"; }
do_status()  { capture status "cd $Q_REMOTE_DIR && $Q_W --status --json"; }
do_tests()   { capture tests "cd $Q_REMOTE_DIR && bash tests/test_static.sh; bash tests/test_units.sh; bash tests/test_integration.sh"; }
do_explain() {
    [[ -n "${1:-}" ]] || die "explain necesita una ruta de archivo remota."
    capture explain "cd $Q_REMOTE_DIR && $Q_W --explain $(rq "$1") $COMMON"
}
# The environment probe lives in its own staged script, remote/zrw-env.sh.
# It used to be a one-liner embedded here, which needed three levels of quote
# escaping to survive the trip through ssh -- and hid a wrong awk filter.
do_env() { capture environment "bash $Q_REMOTE_DIR/remote/zrw-env.sh $Q_TARGET"; }

# --- the guarded, write-capable path ----------------------------------------
do_run() {
    [[ "$ZRW_ALLOW_WRITE" == yes ]] || die \
        "Rechazado: ZRW_ALLOW_WRITE no es 'yes' en $CONF. Este modo MODIFICA archivos en el NAS." "$EX_REFUSED"
    printf '\n\033[31m%s\033[0m\n' "=============================================================="
    printf '\033[31m  ESTE MODO REESCRIBE ARCHIVOS REALES EN %s\033[0m\n' "$ZRW_HOST"
    printf '\033[31m%s\033[0m\n' "=============================================================="
    printf '  Host    : %s\n  Target  : %s\n  Umbral  : > %s\n  BW      : %s\n  Integr. : %s\n\n' \
        "$ZRW_HOST" "$ZRW_TARGET" "$ZRW_THRESHOLD" "$ZRW_BWLIMIT" "$ZRW_INTEGRITY"
    printf '  Antes de esto deberias haber corrido: check, dryrun y docs/TEST-PLAN.md\n\n'
    read -r -p "  Escribi exactamente el nombre del host para continuar: " ans || exit "$EX_REFUSED"
    [[ "$ans" == "$ZRW_HOST" ]] || die "Cancelado." "$EX_REFUSED"
    # tmux keeps the job alive across an SSH disconnect; a reblock runs for days.
    if rsh 'command -v tmux >/dev/null'; then
        info "Lanzando dentro de tmux (sesion zrw). Reconectar: ssh ... -t tmux attach -t zrw"
        rsh "cd $Q_REMOTE_DIR && tmux new -d -s zrw \"$Q_W $Q_TARGET $COMMON --ui plain 2>&1 | tee -a $Q_REMOTE_DIR/run-$STAMP.log\"" \
            && info "Lanzado. Seguimiento: $0 status"
    else
        printf '[WARN] tmux no esta en el NAS; se usara nohup.\n' >&2
        rsh "cd $Q_REMOTE_DIR && nohup $Q_W $Q_TARGET $COMMON --ui plain >'run-$STAMP.log' 2>&1 & echo lanzado pid=\$!"
    fi
}

usage() {
    sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    printf '\nConfiguracion actual (%s):\n' "$CONF"
    printf '  host=%s  user=%s  port=%s\n  target=%s\n  remote-dir=%s\n' \
        "$ZRW_HOST" "$ZRW_USER" "$ZRW_PORT" "$ZRW_TARGET" "$ZRW_REMOTE_DIR"
    printf '  umbral=%s  recordsize=%s  bw=%s  integridad=%s  hash=%s  workers=%s\n' \
        "$ZRW_THRESHOLD" "$ZRW_RECORDSIZE" "$ZRW_BWLIMIT" "$ZRW_INTEGRITY" "$ZRW_HASH" "$ZRW_WORKERS"
    printf '  probe-write=%s  allow-write=%s\n' "${ZRW_PROBE_WRITE:-no}" "$ZRW_ALLOW_WRITE"
}

main() {
    local cmd="${1:-all}"; shift || true
    case "$cmd" in
        -h|--help|help) usage; exit "$EX_OK" ;;
        discover)    probe; stage; do_discover ;;
        check)       probe; stage; do_env; do_check ;;
        dryrun)      probe; stage; do_dryrun ;;
        dryrun-json) probe; stage; do_dryjson ;;
        explain)     probe; stage; do_explain "${1:-}" ;;
        tests)       probe; stage; do_tests ;;
        status)      probe; do_status ;;
        shell)       exec "${SSH_BASE[@]}" -t "$DEST" "cd $Q_REMOTE_DIR && exec \$SHELL -l" ;;
        run)         probe; stage; do_run ;;
        all)         probe; stage
                     do_env     || true
                     do_discover|| true
                     do_check   || true
                     do_dryrun  || true
                     do_dryjson || true
                     do_tests   || true
                     report ;;
        *) die "Comando desconocido: $cmd (ver --help)" ;;
    esac
}

main "$@"
