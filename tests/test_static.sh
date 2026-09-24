#!/usr/bin/env bash
# Static review. Touches neither ZFS nor any file of a dataset.
set -u
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$DIR/../zfs-reblock-worker.sh"
fails=0

check() { local d="$1"; shift
    if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "$d"
    else printf '  FAIL %s\n' "$d"; fails=$((fails+1)); fi; }
has()  { grep -q -- "$1" "$SCRIPT"; }

printf 'ZFS Reblock Worker - static checks\n'

check "bash -n (sintaxis completa)" bash -n "$SCRIPT"
check "--help funciona"            bash "$SCRIPT" --help

# CRLF makes a Bash script unrunnable on Linux ("bad interpreter"). Easy to
# introduce when editing from Windows, so it is checked every time.
no_crlf() { local f
    for f in "$SCRIPT" "$DIR"/*.sh "$DIR/../examples/profiles.conf" "$DIR/../remote"/*.sh; do
        [[ -f "$f" ]] || continue
        LC_ALL=C grep -qU $'\r' "$f" 2>/dev/null && { printf '       %s tiene CRLF\n' "$f"; return 1; }
    done; return 0; }
check "sin CRLF (arrancan en Linux)" no_crlf
good_shebang() { [[ "$(head -n1 "$SCRIPT")" == '#!/usr/bin/env bash' ]]; }
check "shebang correcto" good_shebang

# Safety-contract invariants.
check "rsync preserva ACL/xattr y sparse (-aAXS)"   has 'rsync -aAXS'
check "SHA-256 presente"                            has 'sha_of'
check "commit por rename"                           has 'mv -f -- "\$CUR_TMP" "\$f"'
check "ancla de rollback por hardlink"              has 'ln -- "\$f" "\$CUR_ANCHOR"'
check "rollback post-commit"                        has 'rollback "\$f" "\$CUR_ANCHOR"'
check "recuperacion de anclas huerfanas"            has 'recover_anchors'
check "recuperacion de temporales huerfanos"        has 'recover_temps'
check "estados transitorios vuelven a PENDING"      has 'PENDING_AFTER_RECOVERY'
check "el checkpoint no es autoridad absoluta"      has 'state_valid'
check "estado fsyncado (durabilidad del checkpoint)" has 'sync -f'
check "PENDING inicializado por inventario"         has 'init_pending'
check "lock exclusivo con flock"                    has 'flock -n 200'
check "lock informativo (PID/inicio/target)"        has 'PID_FILE'
check "inventario con find -print0"                 has '\-type f \-print0'
check "mapa de datasets por longest-prefix"        has 'map_datasets'
check "recordsize verificado por dataset del archivo" has 'file_dataset_ok'
check ".zfs nunca se recorre"                      has '\-name .zfs \-prune'
check "metricas PSI"                               has '/proc/pressure'
check "algoritmo de hash configurable"             has 'HASH_CMD'
check "puntero al trabajo actual"                  has 'set_current_job'
check "menu de decision ante STALE"                has 'stale_decision'
check "menu de condiciones de parada"              has 'stop_menu'
check "cambio de perfil en caliente"               has 'profile_menu'
check "color para el ojo humano"                   has 'paint()'
check "inventario publicado atomicamente"           has 'mv -f -- "\$tmp" "\$INVENTORY"'
check "baseline antes del primer archivo"           has 'AUTO-BASELINE'
check "governor adaptativo"                         has 'governor_step'
check "presion de disco desde /proc/diskstats"      has '/proc/diskstats'
check "nivel EMERGENCY"                             has 'EMERGENCY'
check "techo manual por encima de AUTO"             has 'BW_MANUAL'
check "prioridad adaptativa"                        has 'adapt_priority'
check "workers en paralelo"                         has 'run_parallel'
check "claim atomico entre workers"                 has 'claim_file'
check "explorador con fallback"                     has 'browse_bash'
check "modo --explain"                              has 'explain_file'
check "trap de limpieza"                            has 'trap cleanup EXIT'
check "temporales y anclas marcados por job"        has '.zrw-%s-%s.tmp'
check "impacto estimado al cambiar el BW"           has 'bw_impact'
check "cuarentena inspeccionada"                    has 'inspect_quarantine'

# Things that must NOT be there.
# Only a real command invocation counts; help text and messages may name it.
no_zfs_set() { ! grep -qE '(^|[;&|]|then |else )[[:space:]]*zfs set ' "$SCRIPT"; }
check "no ejecuta 'zfs set' (no cambia el recordsize)" no_zfs_set
no_hardcoded() { ! grep -q '/mnt/tank/media' "$SCRIPT"; }
check "sin rutas de destino hardcodeadas" no_hardcoded
no_sete() { ! grep -q '^set -euo' "$SCRIPT"; }
check "sin set -e (un archivo que falla no aborta el lote)" no_sete
# A zdb hint must never be the reason a file is skipped.
no_zdb_skip() { ! grep -A3 'hint="\$(zfs_hint' "$SCRIPT" | grep -q 'SKIPPED'; }
check "un hint de zdb nunca produce SKIP" no_zdb_skip

# zdb -O walks pool metadata on disk and can block for minutes under real
# contention (confirmed live: 7+ minutes during a concurrent scrub). Advisory
# was always about the decision; an unbounded call breaks that promise just as
# effectively by stalling real work. The call must be reachable through timeout.
zdb_hint_bounded() { grep -q 'timeout .* zdb -O\|timeout zdb -O' "$SCRIPT"; }
check "la llamada a zdb -O tiene un limite de tiempo" zdb_hint_bounded

# /proc parsing must set IFS locally: a global IFS without a space silently
# yields empty fields and blinds the governor.
ifs_ok() { grep -q "IFS=' ' read" "$SCRIPT"; }
check "lectura de /proc con IFS explicito" ifs_ok

# Under `pipefail`, `producer | grep -q PATTERN` is a race: grep can close its
# end of the pipe the instant it finds a match, and if the producer is still
# writing the SIGPIPE it gets turns into the pipeline's exit code -- indistin-
# guishable from "no match". Confirmed live: `rsync --version | grep -qi ACLs`
# failed 5/5 times on the reference NAS despite that rsync fully supporting
# ACLs. The safe idiom is `[[ "$(producer)" == *PATTERN* ]]`, which captures
# everything before testing it. This check allows the pattern only inside an
# explicit `( set -o pipefail; ... )` subshell, which zrw-discovery.sh uses on
# purpose to demonstrate the bug for the operator, isolated from the rest of
# the script's control flow.
no_racy_grep_q() {
    local f bad=0 line
    for f in "$SCRIPT" "$DIR/../remote"/*.sh; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ "$line" == *'( set -o pipefail;'* ]] && continue
            # A comment mentioning the pattern (e.g. explaining a past fix) is
            # not a live pipeline; skip anything after the code has ended.
            [[ "${line#*:}" =~ ^[[:space:]]*# ]] && continue
            printf '       %s\n' "$line"; bad=1
        done < <(grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "$f")
    done
    return "$bad"
}
check "sin 'comando | grep -q' desprotegido (SIGPIPE + pipefail)" no_racy_grep_q

# `nice -n N` is a relative adjustment on top of the caller's own niceness,
# not an absolute target -- apply_priority() already renices this process
# itself (absolute, via renice -p "$$") every time NICE_VALUE can change, so
# rsync inherits the right value at fork with no wrapper needed. Wrapping it
# in `nice -n "$NICE_VALUE"` again doubles the adjustment once the caller is
# no longer at niceness 0 (found live: operator set nice=10, the next file's
# rsync came up at 19, the OS-clamped 10+10). Guards against reintroducing
# that wrapper around the rsync launch specifically.
no_double_nice() { ! grep -qE '(^|[^a-zA-Z])nice -n "\$NICE_VALUE"' "$SCRIPT"; }
check "rsync no se envuelve en 'nice -n' (heredaria y duplicaria el ajuste)" no_double_nice

# A trap only suppresses a signal's default action; it does not make the
# shell exit on its own. `trap cleanup EXIT INT TERM` with a cleanup() that
# never calls exit meant one Ctrl+C ran cleanup() and then simply resumed
# execution right after whatever was interrupted -- found live, in the
# wizard: it took one Ctrl+C per remaining prompt, not one to leave. Guards
# against reintroducing INT/TERM into that same combined trap line.
no_bare_int_term_trap() { ! grep -qE "trap [^;]*EXIT[^;]*(INT|TERM)" "$SCRIPT"; }
check "INT/TERM no comparten trap con EXIT sin exit explicito (Ctrl+C debe salir)" no_bare_int_term_trap

# Every external command used must be declared in the preflight lists.
missing=""
for c in rsync flock zfs sha256sum stat find sort awk sed grep head tail uniq \
         df date sleep touch mv rm mkdir dirname basename ln id kill sync; do
    sed -n '/CRIT_CMDS=(/,/)/p' "$SCRIPT" | grep -qw "$c" || missing="$missing $c"
done
if [[ -z "$missing" ]]; then printf '  ok   todos los comandos usados estan en el preflight critico\n'
else printf '  FAIL comandos usados y no declarados:%s\n' "$missing"; fails=$((fails+1)); fi

# All comments must be in English (project convention).
spanish_comments() {
    grep -nE '^\s*#' "$SCRIPT" | grep -vE '^\s*[0-9]+:\s*#!' \
        | grep -qiE '\b(configuraci|archivo|verifica|temporal|estado|siguiente|siempre)\b' && return 1
    return 0
}
check "comentarios del script en ingles" spanish_comments

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck sin warnings" shellcheck -S warning "$SCRIPT"
else
    printf '  --   shellcheck no instalado (opcional)\n'
fi

# The scripts under remote/ are shipped and run on the server too, so a syntax
# error there is as fatal as one in the worker. They were outside this suite
# until a real run on the NAS made them part of the delivery.
for aux in "$DIR/../remote"/*.sh; do
    [[ -f "$aux" ]] || continue
    check "bash -n $(basename "$aux")" bash -n "$aux"
    if command -v shellcheck >/dev/null 2>&1; then
        check "shellcheck $(basename "$aux")" shellcheck -S warning "$aux"
    fi
done

if (( fails )); then printf '\nstatic checks: %s FALLOS\n' "$fails"; exit 1; fi
printf '\nstatic checks: OK\n'
