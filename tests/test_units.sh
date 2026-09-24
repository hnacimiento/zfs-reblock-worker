#!/usr/bin/env bash
# Unit tests for the worker's pure functions.
#
# The script is sourced with ZRW_LIB_ONLY=1, so main() never runs: no ZFS is
# touched, no job is created and no file of any dataset is modified. Runs on
# any Linux (or Git Bash) without ZFS installed.
set -u
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1090
ZRW_LIB_ONLY=1 source "$DIR/../zfs-reblock-worker.sh"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
eq()   { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (esperado [$2], obtenido [$3])"; fi; }
ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
no()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }

printf 'ZFS Reblock Worker - unit tests\n'

# --- units -------------------------------------------------------------------
eq "to_bytes 1024"  "1024"          "$(to_bytes 1024)"
eq "to_bytes 512K"  "524288"        "$(to_bytes 512K)"
eq "to_bytes 35M"   "36700160"      "$(to_bytes 35M)"
eq "to_bytes 35MiB" "36700160"      "$(to_bytes 35MiB)"
eq "to_bytes 2G"    "2147483648"    "$(to_bytes 2G)"
eq "to_bytes 1T"    "1099511627776" "$(to_bytes 1T)"
no "to_bytes rechaza basura" to_bytes "no-es-tamano"

# bwlimit must always be re-parseable: V3.1 emitted "36700160B", which neither
# rsync nor the parser could read back, freezing the governor after one change.
rate="$(bw_rate 36700160)"
eq "bw_rate 35M -> KiB"                "35840K"   "$rate"
eq "el bwlimit generado se relee"      "36700160" "$(to_bytes "$rate")"
eq "bw_rate nunca baja de 1K"          "1K"       "$(bw_rate 10)"
eq "human 1 GiB" "1.00 GiB" "$(human 1073741824)"
eq "human 0"     "0 B"      "$(human 0)"
eq "hms 3661"    "01h 01m 01s" "$(hms 3661)"
eq "jesc escapa comillas y backslash" 'a\\b\"c' "$(jesc 'a\b"c')"

# --- space margin ------------------------------------------------------------
MARGIN_PCT=20; MARGIN_MIN=$((1024*1024*1024))
eq "margen porcentual"      "$(( 107374182400 + 21474836480 ))" "$(space_needed 107374182400)"
eq "margen minimo absoluto" "$(( 2147483648 + 1073741824 ))"    "$(space_needed 2147483648)"

# --- inventory encoding: hostile Unix names ---------------------------------
for name in "simple.mkv" "con espacios.mkv" "con'comilla.mkv" 'con"doble.mkv' \
            "con\$dolar y \`backtick\`.mkv" "con
salto.mkv" "con	tab.mkv" "con-*-glob-[x].mkv"; do
    printf -v enc '%q' "$name"; unq "$enc"
    eq "roundtrip inventario: $(printf '%s' "$name" | tr '\n\t' '??')" "$name" "$QPATH"
done

# --- keys and tokens ---------------------------------------------------------
k1="$(state_key /mnt/a/peli.mkv)"; k2="$(state_key /mnt/b/peli.mkv)"
eq "la clave de estado mide 32 hex" "32" "${#k1}"
if [[ "$k1" == "$k2" ]]; then fail "rutas distintas con igual basename colisionan"
else pass "rutas distintas con igual basename no colisionan"; fi

JOB_SHORT=abc1234567
t="$(tmp_path /mnt/a/peli.mkv)"; a="$(anchor_path /mnt/a/peli.mkv)"
case "$t" in /mnt/a/.zrw-abc1234567-*.tmp) pass "el temporal lleva el token del job" ;;
             *) fail "nombre de temporal inesperado: $t" ;; esac
case "$a" in /mnt/a/.zrw-abc1234567-*.rollback) pass "el ancla lleva el token del job" ;;
             *) fail "nombre de ancla inesperado: $a" ;; esac
JOB_SHORT=otrojob999
if [[ "$t" == "$(tmp_path /mnt/a/peli.mkv)" ]]; then fail "dos jobs generan el mismo temporal"
else pass "cada job genera un temporal distinto"; fi

# --- job id ------------------------------------------------------------------
TARGET_DIR=/mnt/x; EXPECTED_RECORDSIZE=1M; THRESHOLD_BYTES=2147483648
j1="$(make_job_id)"; j2="$(make_job_id)"
case "$j1" in ZRW-*) pass "el job id tiene prefijo ZRW" ;; *) fail "job id inesperado: $j1" ;; esac
if [[ "$j1" == "$j2" ]]; then fail "dos job id consecutivos colisionan"
else pass "dos job id consecutivos no colisionan"; fi

# --- profiles ----------------------------------------------------------------
PROFILES_FILE="$DIR/../examples/profiles.conf"
PROFILE=fast-storage; load_profile
eq "el perfil se lee del archivo" "80M" "$BW_TARGET"
PROFILE=conservative; load_profile
eq "perfil conservative fija cooldown" "60" "$COOLDOWN"

# --- save_config/load_config: resuming must not roll back the live VERSION --
# Confirmed live: a job created under 4.4.7, resumed under 4.4.8, kept
# reporting "v4.4.7" everywhere (dashboard, --status, every log line) because
# load_config() sources config.env, and a field literally named VERSION
# clobbered the running binary's own constant. Fixed by writing it as
# JOB_VERSION instead -- a historical record, not a live override.
cfg_tmp="$(mktemp)"
CONFIG_FILE="$cfg_tmp"
JOB_ID=ZRW-test; TARGET_DIR=/t; ZFS_DATASET=t/t; ZFS_MOUNT=/t; EXPECTED_RECORDSIZE=1M
BW_TARGET=35M; BW_MIN=10M; BW_MAX=80M; ADAPTIVE=auto; INTEGRITY=strict
PROFILE=default; COOLDOWN_MODE=fixed; ADAPTIVE_PRIORITY=off
THRESHOLD_BYTES=1; NICE_VALUE=19; IONICE_CLASS=3; NICE_MIN=10; IONICE_MIN=2
COOLDOWN=30; HEALTH_INTERVAL=10; MARGIN_PCT=20; MARGIN_MIN=1; RETRIES=2; WORKERS=1
VERSION="4.4.7"
save_config
VERSION="4.4.8"   # simulates resuming an old job with an upgraded binary
load_config
eq "resumir un job viejo no hace retroceder el VERSION en vivo" "4.4.8" "$VERSION"
eq "el config guarda la version original como JOB_VERSION" "4.4.7" "$JOB_VERSION"
no_literal_version() { ! grep -qE '^VERSION=' "$cfg_tmp"; }
ok "config.env no escribe un campo VERSION que pueda pisar al binario" no_literal_version
rm -f "$cfg_tmp"

# --- load_config must not undo a flag the operator just typed ---------------
# Confirmed live: `--resume --adaptive off --bwlimit 80M` kept throttling
# anyway. Root cause: load_config() did a plain `source` of config.env,
# which reapplied the job's ORIGINAL saved ADAPTIVE=auto right after
# parse_args had already set it to off from this run's own command line.
cfg_tmp="$(mktemp)"
CONFIG_FILE="$cfg_tmp"
JOB_ID=ZRW-test2; TARGET_DIR=/t; ZFS_DATASET=t/t; ZFS_MOUNT=/t; EXPECTED_RECORDSIZE=1M
BW_TARGET=35M; BW_MIN=10M; BW_MAX=80M; ADAPTIVE=auto; INTEGRITY=strict
PROFILE=default; COOLDOWN_MODE=fixed; ADAPTIVE_PRIORITY=off
THRESHOLD_BYTES=1; NICE_VALUE=19; IONICE_CLASS=3; NICE_MIN=10; IONICE_MIN=2
COOLDOWN=30; HEALTH_INTERVAL=10; MARGIN_PCT=20; MARGIN_MIN=1; RETRIES=2; WORKERS=1
VERSION="4.4.11"
save_config   # a job created earlier with the defaults above (ADAPTIVE=auto)

# Simulates: zfs-reblock-worker.sh --job ZRW-test2 --resume --adaptive off
CLI_SET=([ADAPTIVE]=1)
ADAPTIVE=off   # what parse_args would have set from --adaptive off
COOLDOWN=99    # NOT passed on this resume -- must still come from the saved job
load_config
eq "un flag explicito en --resume gana sobre el config guardado" "off" "$ADAPTIVE"
eq "un campo no pasado en --resume sigue viniendo del job guardado" "30" "$COOLDOWN"
CLI_SET=()

# finalize_bw() has to run AFTER load_config -- confirmed live: a plain
# --resume of a job saved with a non-default BW_TARGET (20M here) used to
# start from the compiled default (35M) instead, because BW_BPS used to be
# computed inside validate(), before the job's real config was ever loaded.
BW_TARGET=20M; save_config   # a job saved earlier with a non-default BW_TARGET
BW_TARGET="$D_BW"            # what parse_args leaves it at when --bwlimit is NOT passed
load_config                  # plain --resume: no CLI_SET entry for BW_TARGET
finalize_bw
eq "un --resume sin --bwlimit toma el BW_TARGET guardado del job, no el default" \
    "$(to_bytes 20M)" "$BW_BPS"
rm -f "$cfg_tmp"

# --- adaptive cooldown -------------------------------------------------------
COOLDOWN_MODE=fixed; COOLDOWN=30; COOLDOWN_BASE=30; HEALTH=HEALTHY
adapt_cooldown; eq "en modo fixed el cooldown no se toca" "30" "$COOLDOWN"
COOLDOWN_MODE=adaptive; HEALTH=PRESSURE; adapt_cooldown
eq "adaptive alarga el cooldown bajo presion" "60" "$COOLDOWN"
HEALTH=EMERGENCY; adapt_cooldown
eq "adaptive cuadruplica en EMERGENCY" "120" "$COOLDOWN"
HEALTH=HEALTHY; adapt_cooldown
eq "adaptive acorta con el servidor sano" "15" "$COOLDOWN"

# --- adaptive priority: the operator's value is the aggressive bound ---------
ADAPTIVE_PRIORITY=off; NICE_VALUE=19; IONICE_CLASS=3; HEALTH=HEALTHY
adapt_priority; eq "con prioridad adaptativa off no cambia nada" "19" "$NICE_VALUE"
ADAPTIVE_PRIORITY=on; NICE_MIN=10; IONICE_MIN=2
apply_priority() { :; }   # no real renice/ionice inside the test
HEALTH=HEALTHY; adapt_priority
eq "HEALTHY baja el nice hasta nice-min"      "10" "$NICE_VALUE"
eq "HEALTHY sube la clase de I/O hasta el min" "2"  "$IONICE_CLASS"
HEALTH=CRITICAL; adapt_priority
eq "CRITICAL devuelve nice a 19"    "19" "$NICE_VALUE"
eq "CRITICAL devuelve ionice a idle" "3" "$IONICE_CLASS"
NICE_MIN=19; IONICE_MIN=3; HEALTH=HEALTHY; adapt_priority
eq "AUTO nunca supera el limite del operador (nice)"   "19" "$NICE_VALUE"
eq "AUTO nunca supera el limite del operador (ionice)" "3"  "$IONICE_CLASS"

# --- read_cpu_mem: ZFS ARC must be credited back as reclaimable memory ------
# MemAvailable does not know ARC is reclaimable on Linux: a ZFS host with ARC
# near its target reports as if that memory were pinned. Confirmed live
# against a real NAS: ARC ~20GiB/23.5GiB total, MemAvailable ~2GiB free, read
# as 92% "used" and feeding the health score even with CPU/iowait/disk idle.
# Runs before read_cpu_mem gets stubbed below, and only where /proc/meminfo is
# real (not on Windows/Git Bash), same guard the rest of this file relies on.
if [[ -r /proc/meminfo ]] && grep -q '^MemAvailable:' /proc/meminfo 2>/dev/null; then
    ARCSTATS_FILE=/no/such/path/zrw-test-fixture
    read_cpu_mem; mem_no_arc="$MEM"
    arc_fixture="$(mktemp)"
    printf 'size 4 %s\nc_min 4 %s\n' 53687091200 104857600 >"$arc_fixture"
    ARCSTATS_FILE="$arc_fixture"
    read_cpu_mem; mem_with_arc="$MEM"
    rm -f "$arc_fixture"
    if (( mem_with_arc < mem_no_arc )); then
        pass "ARC reclamable (50GiB size, 100MiB c_min) baja el MEM reportado (sin=$mem_no_arc con=$mem_with_arc)"
    else
        fail "el credito de ARC no bajo el MEM reportado (sin=$mem_no_arc con=$mem_with_arc)"
    fi
    (( mem_with_arc >= 0 && mem_with_arc <= 100 )) \
        && pass "MEM con credito de ARC queda dentro de 0..100" \
        || fail "MEM con credito de ARC fuera de rango: $mem_with_arc"
else
    pass "read_cpu_mem/ARC: sin MemAvailable real en este host (ej. Git Bash), se omite"
fi
ARCSTATS_FILE="${ZRW_ARCSTATS_FILE:-/proc/spl/kstat/zfs/arcstats}"

# --- health levels: storage outranks CPU ------------------------------------
# health_sample() also calls read_psi and read_swap, which read the real
# /proc/pressure and /proc/meminfo of whatever host runs this suite. Left
# unstubbed, "idle" was only true by accident: on a quiet WSL box /proc/pressure
# does not exist, so PSI reads as 0 and the test passed -- and on a live NAS
# doing real work, genuine non-zero PSI made this same assertion fail, not
# because the code was wrong but because the test was never actually hermetic.
read_cpu_mem() { CPU=0; IOWAIT=0; MEM=0; LOAD1=0.1; }
read_disk()    { DISK_UTIL=0; DISK_WAIT=0; }
read_psi()     { PSI_IO=0; PSI_CPU=0; PSI_MEM=0; }
read_swap()    { SWAP_USED=0; }
BASE_LOAD=0; BASE_IOWAIT=0; BASE_MEM=0; BASE_DISK=0; BASE_PSI=0
health_sample; eq "servidor ocioso -> HEALTHY" "HEALTHY" "$HEALTH"
read_disk() { DISK_UTIL=95; DISK_WAIT=60; }
health_sample
if [[ "$HEALTH" == CRITICAL || "$HEALTH" == EMERGENCY ]]; then
    pass "disco saturado dispara CRITICAL/EMERGENCY aunque la CPU este ociosa"
else fail "disco saturado no elevo la presion (HEALTH=$HEALTH score=$HEALTH_SCORE)"; fi
read_disk() { DISK_UTIL=0; DISK_WAIT=0; }

# --- health_sample: "goodput" credit -- productive saturation vs stuck ------
# Same idea TCP BBR and adaptive-concurrency limiters use: %util/PSI alone
# cannot tell "100% busy delivering real bytes" from "100% busy and stuck".
# Confirmed live: an isolated fio write saturated a single USB disk at
# 150+ MiB/s real sustained throughput and still scored EMERGENCY throughout,
# because nothing looked at what was actually getting done.
read_disk() { DISK_UTIL=100; DISK_WAIT=60; }
read_psi()  { PSI_IO=85; PSI_CPU=0; PSI_MEM=0; }
BW_MIN=10M
CUR_START=0
health_sample; score_no_copy="$HEALTH_SCORE"
if [[ "$HEALTH" == EMERGENCY ]]; then pass "sin copia en curso, la saturacion se lee como EMERGENCY (score=$score_no_copy)"
else fail "se esperaba EMERGENCY sin señal de goodput (HEALTH=$HEALTH score=$score_no_copy)"; fi

CUR_START=$(( $(date +%s) - 10 ))   # a real copy started 10s ago...
CUR_DONE=$(( 20*1024*1024*10 ))     # ...and has moved 20 MiB/s so far, well over BW_MIN=10M
health_sample
if (( HEALTH_SCORE < score_no_copy )); then
    pass "goodput por encima de BW_MIN baja la severidad (sin copia=$score_no_copy, con copia=$HEALTH_SCORE)"
else fail "el credito de goodput no bajo la severidad (sin copia=$score_no_copy, con copia=$HEALTH_SCORE)"; fi
eq "GOODPUT_BPS refleja bytes/seg reales, no un valor inventado" "$(( 20*1024*1024 ))" "$GOODPUT_BPS"

CUR_START=$(( $(date +%s) - 2 ))    # menos de 5s: demasiado pronto para confiar en la medicion
CUR_DONE=$(( 50*1024*1024*2 ))
health_sample
eq "goodput no se aplica en los primeros segundos de una copia" "$score_no_copy" "$HEALTH_SCORE"
CUR_START=0; CUR_DONE=0

# --- governor: operator authority is absolute -------------------------------
ADAPTIVE=auto; HEALTH_INTERVAL=10; BW_MIN=10M; BW_MAX=80M; AUTO_UNTIL=0
health_sample() { HEALTH=HEALTHY; HEALTH_WHY=test; HEALTH_SCORE=0; }
BW_BPS="$(to_bytes 20M)"; BW_CEIL_BPS="$BW_BPS"; BW_MANUAL=1
governor_step
eq "AUTO no supera el techo manual" "$(to_bytes 20M)" "$BW_BPS"

BW_MANUAL=0; AUTO_UNTIL=0; BW_BPS="$(to_bytes 20M)"; governor_step
if (( BW_BPS > $(to_bytes 20M) )); then pass "AUTO sube el BW con servidor sano"
else fail "AUTO no subio el BW estando sano"; fi

ADAPTIVE=guarded; AUTO_UNTIL=0; before="$BW_BPS"; governor_step
eq "GUARDED nunca aumenta por su cuenta" "$before" "$BW_BPS"

ADAPTIVE=auto; AUTO_UNTIL=0
health_sample() { HEALTH=PRESSURE; HEALTH_WHY=test; HEALTH_SCORE=5; }
before="$BW_BPS"; governor_step
if (( BW_BPS < before )); then pass "AUTO reduce el BW ante presion"
else fail "AUTO no redujo ante presion"; fi

BW_MANUAL=1; BW_CEIL_BPS="$(to_bytes 20M)"; AUTO_UNTIL=0; before="$BW_BPS"; governor_step
if (( BW_BPS < before )); then pass "AUTO puede bajar POR DEBAJO del techo manual"
else fail "AUTO no pudo bajar del techo manual"; fi
BW_MANUAL=0

# --- governor: --adaptive off measures but never acts -----------------------
# Confirmed live: with the ADAPTIVE-off gate BEFORE health_sample(), the
# dashboard's SERVIDOR panel froze at UNKNOWN/0 the instant --adaptive off
# was chosen -- not because the server was fine, but because the worker had
# stopped looking. off still means zero automatic action; it should no
# longer mean zero visibility.
ADAPTIVE=off; AUTO_UNTIL=0; HEALTH="UNKNOWN"; HEALTH_SCORE=0
health_sample() { HEALTH=CRITICAL; HEALTH_WHY=test; HEALTH_SCORE=9; }
before="$BW_BPS"; governor_step
eq "adaptive=off sigue midiendo (HEALTH se actualiza)" "CRITICAL" "$HEALTH"
eq "adaptive=off nunca actua sobre el BW" "$before" "$BW_BPS"
ADAPTIVE=auto

# --- governor: anti-flapping cooldown after a CRITICAL/EMERGENCY episode ----
# ZFS syncs dirty data on a ~5s timer; on a single slow disk that periodic
# sync is bursty enough to look like it pulses between healthy and critical
# (the "picket fence" pattern). Increasing BW the instant one good sample
# arrives right after a crisis just overshoots into the next pulse.
# Confirmed live against a real NAS: recover -> increase -> CRITICAL again,
# on nearly every file.
BW_MANUAL=0; ADAPTIVE=auto; HEALTH_INTERVAL=10; BW_BPS="$(to_bytes 20M)"; AUTO_UNTIL=0
LAST_CRIT_TS="$(date +%s)"
health_sample() { HEALTH=HEALTHY; HEALTH_WHY=test; HEALTH_SCORE=0; }
before="$BW_BPS"; governor_step
eq "tras una crisis reciente, HEALTHY no sube el BW de inmediato" "$before" "$BW_BPS"

AUTO_UNTIL=0; LAST_CRIT_TS=$(( $(date +%s) - HEALTH_INTERVAL*3 - 1 ))
before="$BW_BPS"; governor_step
if (( BW_BPS > before )); then pass "pasado el enfriamiento, AUTO vuelve a subir el BW"
else fail "el BW no subio tras pasar el enfriamiento post-crisis"; fi
LAST_CRIT_TS=0

# --- auto-resume: opt-in wait-and-continue on a protective pause -------------
# Without --auto-resume, EMERGENCY_SAMPLES consecutive bad samples leave
# PAUSE_REQ=1 forever (the operator must run --resume by hand). With it, the
# SAME run keeps sampling and clears the pause on its own once health
# recovers -- bounded by PAUSE_TIMEOUT_MIN so it can never hang silently.
ADAPTIVE=auto; AUTO_UNTIL=0; HEALTH_INTERVAL=0; WORKER_ID=0; TTY=0
AUTO_RESUME_PRESSURE=0; PAUSE_TIMEOUT_MIN=10; CRIT_COUNT=0; AUTO_PAUSED=0; PAUSE_REQ=0; EXIT_REQ=0
health_sample() { HEALTH=EMERGENCY; HEALTH_WHY=test; HEALTH_SCORE=12; }
governor_step; governor_step; governor_step
eq "sin --auto-resume, 3 muestras EMERGENCY dejan PAUSE_REQ activo" "1" "$PAUSE_REQ"

CRIT_COUNT=0; AUTO_PAUSED=0; PAUSE_REQ=0; EXIT_REQ=0
AUTO_RESUME_PRESSURE=1
_calls=0
health_sample() {
    _calls=$((_calls+1))
    if (( _calls <= 5 )); then HEALTH=EMERGENCY; HEALTH_WHY=test; HEALTH_SCORE=12
    else HEALTH=HEALTHY; HEALTH_WHY=test; HEALTH_SCORE=0; fi
}
governor_step; governor_step; governor_step   # 3rd call crosses EMERGENCY_SAMPLES and enters the wait
eq "con --auto-resume, la presion que despues cede no deja PAUSE_REQ activo" "0" "$PAUSE_REQ"
eq "y AUTO_PAUSED se limpia solo, sin --resume" "0" "$AUTO_PAUSED"

CRIT_COUNT=0; AUTO_PAUSED=0; PAUSE_REQ=0; EXIT_REQ=0
PAUSE_TIMEOUT_MIN=0
health_sample() { HEALTH=EMERGENCY; HEALTH_WHY=test; HEALTH_SCORE=12; }
governor_step; governor_step; governor_step
eq "--pause-timeout=0 se rinde igual, nunca queda colgado" "1" "$PAUSE_REQ"
eq "y AUTO_PAUSED sigue en 1 (nunca se recupero de verdad)" "1" "$AUTO_PAUSED"
PAUSE_TIMEOUT_MIN=120; AUTO_RESUME_PRESSURE=0

# --- baseline-suggested initial bandwidth ------------------------------------
BW_MIN=10M; BW_MAX=80M; HEALTH=HEALTHY
s="$(suggest_initial_bw "$(to_bytes 35M)")"
if (( s > $(to_bytes 35M) )); then pass "el baseline sugiere subir si el servidor esta libre"
else fail "el baseline no sugirio subir"; fi
HEALTH=CRITICAL; s="$(suggest_initial_bw "$(to_bytes 35M)")"
if (( s < $(to_bytes 35M) )); then pass "el baseline sugiere bajar si el servidor sufre"
else fail "el baseline no sugirio bajar"; fi

# --- stop conditions ---------------------------------------------------------
STOP_AFTER=3; N_DONE=2; STOP_AT=""; JOB_START_HM=00:00
no "no se detiene antes del limite" stop_now
N_DONE=3; ok "se detiene al alcanzar --stop-after" stop_now
STOP_AFTER=0

# --- progress accounting -----------------------------------------------------
BYTES_SEEN=0; count_bytes 1000; count_bytes 500; count_bytes "no-numero"
eq "el progreso por bytes ignora lo no numerico" "1500" "$BYTES_SEEN"

# --- recent-events window ----------------------------------------------------
LAST_EVENTS=(); for i in 1 2 3 4 5 6 7; do push_event "ev-$i"; done
eq "se conservan los ultimos 5 eventos" "5"    "${#LAST_EVENTS[@]}"
eq "el ultimo evento es el mas reciente" "ev-7" "${LAST_EVENTS[4]}"

# --- zdb hint: dblk, not lsize ----------------------------------------------
# lsize is the logical size of the file; dblk is the block size the data is
# actually stored in, which is the only one that answers "is this file already
# at the dataset recordsize?". Reading lsize is what the real discovery run on
# the NAS showed to be wrong, so these tests pin the right field.
have() { [[ "$1" == zdb ]]; }
ZFS_MOUNT=/mnt/pool; ZFS_DATASET=pool
EXPECTED_RECORDSIZE=1M

zdb() { printf '    Object  lvl   iblk   dblk  dsize  dnsize  lsize   %%%%full  type\n       128    2   128K   128K  1.06M     512  1.06M  100.00  ZFS plain file\n'; }
eq "zdb -O: se lee dblk (bloque real), no lsize" "128K" "$(zfs_hint /mnt/pool/x.mkv)"
no "un archivo con dblk=128K no coincide con el objetivo 1M" hint_matches_target "$(zfs_hint /mnt/pool/x.mkv)"

zdb() { printf '    Object  lvl   iblk   dblk  dsize  dnsize  lsize   %%%%full  type\n       130    2   128K     1M  2.00G     512  2.00G  100.00  ZFS plain file\n'; }
eq "zdb -O: dblk=1M se reporta tal cual" "1M" "$(zfs_hint /mnt/pool/x.mkv)"
ok "un archivo con dblk=1M coincide con el objetivo 1M" hint_matches_target "$(zfs_hint /mnt/pool/x.mkv)"

zdb() { printf 'cannot open /etc/zfs/zpool.cache\nDataset pool [ZPL], ID 54, cr_txg 1\n'; }
eq "salida de zdb sin columna dblk -> UNKNOWN" "UNKNOWN" "$(zfs_hint /mnt/pool/x.mkv)"
no "UNKNOWN nunca cuenta como coincidencia" hint_matches_target "UNKNOWN"
no "una pista vacia nunca cuenta como coincidencia" hint_matches_target ""

# La comparacion es por bytes, no por texto: 1024K y 1M son el mismo bloque.
ok "1024K coincide con el objetivo 1M (se comparan bytes)" hint_matches_target "1024K"

have() { false; }
eq "sin zdb la pista es UNKNOWN, no un error" "UNKNOWN" "$(zfs_hint /mnt/pool/x.mkv)"

# zdb -O reads pool metadata directly, and on the reference NAS it blocked for
# 7+ minutes under a concurrent scrub on spinning disk -- stalling the whole
# job over a call whose own design says it must never decide anything, let
# alone stall real work. `timeout` is what keeps that promise in practice.
have() { [[ "$1" == zdb || "$1" == timeout ]]; }
timeout() { shift; "$@"; }   # stub: drops the numeric budget, delegates straight through
zdb() { printf '    Object  lvl   iblk   dblk  dsize  dnsize  lsize   %%%%full  type\n       128    2   128K   128K  1.06M     512  1.06M  100.00  ZFS plain file\n'; }
eq "con timeout disponible, zdb sigue leyendose bien" "128K" "$(zfs_hint /mnt/pool/x.mkv)"
# The actual cutoff (a hung zdb genuinely gets killed, not just plumbed
# through) needs a real executable, not a shell function `timeout` can't
# fork+exec -- see tests/test_integration.sh for that one.

# --- capacidades del host -> politica del dataset -> verificador efectivo ----
# El modelo de tres capas existe porque un unico ACL_METHOD global permitia que
# el preflight dijera READY y despues fallara archivo por archivo, ya copiado y
# hasheado. Cada combinacion tiene que resolverse igual siempre.
CAP_NFS4=1 CAP_POSIX=1 CAP_XATTR=1
eq "nfsv4 con nfs4xdr+jq presentes" "nfs4xdr+jq"       "$(acl_verifier_for nfsv4)"
eq "posix con getfacl+getfattr presentes" "getfacl+getfattr" "$(acl_verifier_for posix)"
eq "posixacl es sinonimo de posix" "getfacl+getfattr" "$(acl_verifier_for posixacl)"
eq "acltype=off se verifica solo con getfattr" "getfattr" "$(acl_verifier_for off)"
eq "un acltype desconocido no resuelve verificador" "" "$(acl_verifier_for marciano)"
eq "un acltype vacio no resuelve verificador" "" "$(acl_verifier_for "")"

CAP_NFS4=0 CAP_POSIX=1 CAP_XATTR=1
eq "sin nfs4xdr/jq, nfsv4 queda sin verificador" "" "$(acl_verifier_for nfsv4)"
eq "y el motivo nombra la herramienta que falta" "faltan nfs4xdr_getfacl y/o jq" "$(acl_missing_for nfsv4)"

CAP_NFS4=0 CAP_POSIX=0 CAP_XATTR=0
eq "sin ninguna herramienta, posix no resuelve" "" "$(acl_verifier_for posix)"
eq "sin ninguna herramienta, off tampoco resuelve" "" "$(acl_verifier_for off)"
eq "el motivo de off nombra getfattr" "falta getfattr" "$(acl_missing_for off)"
eq "un dataset sin acltype se explica como tal" "el dataset no reporta acltype" "$(acl_missing_for "")"
CAP_NFS4=1 CAP_POSIX=1 CAP_XATTR=1

# --- usb_advisory: a lone USB disk has a much lower real write ceiling ------
# Confirmed live: BW kept overshooting into CRITICAL every file on a
# single-USB-disk pool until it settled, several files in, near the disk's
# real ~10-15MB/s limit. This is advisory only -- it never touches the hash,
# the commit path or the governor -- so it only needs to prove it fires when
# (and only when) the resolved leaf device is actually under /sys/.../usb*/.
ZFS_DATASET="toolbox/media"
have() { command -v -- "$1" >/dev/null 2>&1; }   # restored: the zdb-hint tests above leave it stubbed
zpool()  { printf '\tNAME       STATE\n\t  /dev/fakeleaf  ONLINE\n'; }
lsblk()  { printf 'fakeleaf\n'; }
readlink() { printf '/sys/devices/pci0000:00/.../usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0/block/fakeleaf\n'; }
before_warn="$N_WARN"; usb_advisory
if (( N_WARN > before_warn )); then pass "disco USB detectado -> avisa (no bloquea, no cambia BW)"
else fail "disco USB detectado pero no avisa"; fi

readlink() { printf '/sys/devices/pci0000:00/.../ata1/host0/target0:0:0/0:0:0:0/block/fakeleaf\n'; }
before_warn="$N_WARN"; usb_advisory
eq "disco SATA/interno -> sin aviso" "$before_warn" "$N_WARN"

unset -f zpool lsblk readlink

# --- hash_of: GNU coreutils escapes the checksum line for a filename that
# needs it (confirmed live: an embedded newline), prefixing the hash itself
# with a literal backslash. The generated temp filename never needs escaping,
# so its hash never carries that marker -- comparing "\<hash>" against
# "<hash>" fails even when the file content is byte-identical. Broke
# --integrity strict/maximum on the reference NAS for exactly this reason.
HASH_CMD=sha256sum
LAB="$(mktemp -d)"
NLFILE="$LAB/$(printf 'con newline\nreal.bin')"
printf 'contenido de prueba' >"$NLFILE"
PLAINFILE="$LAB/plano.bin"
printf 'contenido de prueba' >"$PLAINFILE"
RAW_NL="$(sha256sum -- "$NLFILE" | awk '{print $1}')"
[[ "$RAW_NL" == '\'* ]] \
    && pass "sha256sum antepone una barra invertida en un nombre con salto de linea (asi lo hace este host)" \
    || fail "este host no reprodujo el escapado de coreutils; el test no es concluyente aqui"
eq "hash_of() quita esa barra (mismo contenido, mismo hash real)" "$(hash_of "$PLAINFILE")" "$(hash_of "$NLFILE")"
rm -rf -- "$LAB"

# --- recover_temps: a crash mid-rsync-transfer leaves rsync's OWN scratch
# name on disk (CUR_TMP plus rsync's random suffix), not yet renamed to the
# exact ".tmp" name -- found live by a real machine reboot (ronda 12).
# A glob for exactly ".zrw-*.tmp" never sees it; --status did report it via
# a wider glob, but recover_temps() silently walked past it, leaving the
# operator with a count and no cleanup path.
LAB="$(mktemp -d)"
TARGET_DIR="$LAB/target"; JOB_DIR="$LAB/job"; JOB_SHORT="abc123"; JOURNAL=""
mkdir -p "$TARGET_DIR" "$JOB_DIR/quarantine"
OWN_PARTIAL="$TARGET_DIR/.zrw-${JOB_SHORT}-deadbeef.tmp.k6oOCo"
FOREIGN_PARTIAL="$TARGET_DIR/.zrw-otherjob99-cafef00d.tmp.xYz123"
printf 'contenido a mitad de camino' >"$OWN_PARTIAL"
printf 'contenido de otro job' >"$FOREIGN_PARTIAL"
N_FOREIGN=0 N_RECOV=0
recover_temps
[[ -e "$OWN_PARTIAL" ]] \
    && fail "el temporal parcial propio (con sufijo de rsync) sigue en el arbol" \
    || pass "el temporal parcial propio (con sufijo de rsync) se saco del arbol"
found_in_quarantine="$(find "$JOB_DIR/quarantine" -type f -name '*deadbeef*' 2>/dev/null | head -1)"
[[ -n "$found_in_quarantine" ]] \
    && eq "y su contenido llego intacto a cuarentena" "contenido a mitad de camino" "$(cat "$found_in_quarantine")" \
    || fail "no se encontro en cuarentena en absoluto"
eq "el temporal parcial de OTRO job se deja intacto, sin tocar" "1" "$N_FOREIGN"
[[ -e "$FOREIGN_PARTIAL" ]] \
    && pass "y sigue en su lugar original" \
    || fail "el temporal de otro job desaparecio (no deberia haberse tocado)"
rm -rf -- "$LAB"

# --- run_loop: the operator's keypress must never share a file descriptor
# with the inventory read -- found live, by a real [Q] keypress mid-copy
# (ronda de consola en vivo). process_one() runs deep inside the loop body
# while WORKER_ID==0, and poll_keys() (called from further down that same
# call chain) reads stdin with no fd of its own. If the inventory is also
# read from stdin, every keypress poll during a copy silently eats one byte
# of whatever inventory line comes next -- with enough of them, a later
# line turns into empty/garbage, and that file's path is lost. Simulated
# here without a real terminal: stdin is fed pure noise (more bytes than
# the whole test needs), process_one() is stubbed to do a poll_keys()-style
# read from stdin on every call, and every path from a 5-line inventory
# must still come through byte-for-byte.
# --- env_sane: the safety check must judge THIS run's frozen recordsize
# (RUN_RECORDSIZE), never the live EXPECTED_RECORDSIZE the operator's [C]
# menu mutates for the *next* job -- found live: [C] staged recordsize=128K
# for later, and the currently running job (real dataset still 1M, never
# touched) aborted mid-copy convinced its own dataset had changed underneath
# it, because env_sane() was comparing against the now-changed live value.
# Runs before env_sane() gets unset (below), so this is the real function.
LAB2="$(mktemp -d)"
TARGET_DIR="$LAB2" ZFS_DATASET="pool/ds"
map_datasets() { return 0; }
discover_dataset() { return 0; }
dataset_recordsize() { printf '1M\n'; }   # the real, unchanged dataset
dataset_for() { return 1; }               # skip the acltype branch
RUN_RECORDSIZE="1M"        # frozen for this run, matches the real dataset
EXPECTED_RECORDSIZE="128K" # operator staged this for the *next* job via [C]
env_sane
eq "env_sane() no aborta un job sano solo porque [C] cambio la config del proximo" "0" "$?"
rm -rf -- "$LAB2"
unset -f map_datasets discover_dataset dataset_recordsize dataset_for

LAB="$(mktemp -d)"
INVENTORY="$LAB/inventory.tsv"
: > "$INVENTORY"
for i in 1 2 3 4 5; do
    printf '1000\t2026-01-01 00:00:00.000000000 +0000\t100%s\tpool/ds\t%s/archivo-%s.bin\n' "$i" "$LAB" "$i" >>"$INVENTORY"
done
TTY=1 WORKER_ID=0 PAUSE_REQ=0 EXIT_REQ=0
seen_paths=()
process_one() {
    seen_paths+=("$1")
    # A real copy calls poll_keys() roughly once per second for as long as it
    # takes; one call here stands in for many, so it reads enough bytes to
    # matter within a 5-line inventory instead of one harmless byte.
    local k; read -r -t 0.05 -n 200 k 2>/dev/null || true
}
selectable() { return 0; }
env_sane() { return 0; }
stop_now() { return 1; }
dashboard() { :; }
run_loop < <(yes 'x' | head -c 200000)
eq "las 5 lineas del inventario llegaron completas, pese al ruido en stdin" "5" "${#seen_paths[@]}"
ok=1
for i in 1 2 3 4 5; do
    [[ "${seen_paths[$((i-1))]:-}" == "$LAB/archivo-$i.bin" ]] || ok=0
done
(( ok )) && pass "y cada una con su ruta exacta, ninguna vacia ni corrupta" \
         || fail "al menos una ruta llego vacia o corrupta: ${seen_paths[*]:-}"
rm -rf -- "$LAB"
unset -f process_one selectable env_sane stop_now dashboard

if (( fails )); then printf '\nunit tests: %s FALLOS\n' "$fails"; exit 1; fi
printf '\nunit tests: OK\n'
