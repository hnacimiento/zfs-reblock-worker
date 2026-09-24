#!/usr/bin/env bash
# =============================================================================
# zrw-discovery.sh - capability discovery for the ZFS Reblock Worker.
#
# Answers the questions the worker's design currently has to GUESS. Read-only
# by default: it inspects, times and reports, and writes nothing outside its own
# output file.
#
# There is one optional write phase (--probe-write) that reproduces the worker's
# actual copy against a real file, because ACL/xattr round-trip behaviour cannot
# be observed any other way. It writes into the SOURCE FILE'S OWN DIRECTORY,
# because that is exactly what the worker does: copying anywhere else would
# measure a different ACL inheritance and give an answer that does not apply.
# The temporary copy is removed afterwards and the source is never modified.
#
# Sin argumentos elige solo el dataset de datos mas grande, igual que el
# pre_test original: se pega en la shell del TrueNAS y corre.
#
#   ./zrw-discovery.sh
#   ./zrw-discovery.sh /mnt/toolbox/media/Videos
#   ./zrw-discovery.sh /mnt/toolbox/media/Videos --probe-write
#   ./zrw-discovery.sh /mnt/toolbox/media/Videos --probe-write --state-dir /mnt/toolbox/scripts/jobs
#
# Produce DOS archivos:
#   .txt   informe legible, para que lo revises antes de enviarlo
#   .json  los mismos hechos en forma estructurada, para analisis y para
#          convertirse en fixture de los tests del worker
#
# --scratch DIR still exists, but it is NOT equivalent: it copies across
# directories (often across datasets), so its ACL result is only indicative.
#
# Output: a single plain-text report. Review it before sharing; it contains
# dataset names, paths and file names from your pool, but no credentials.
# =============================================================================
set -uo pipefail

TARGET=""
case "${1:-}" in
    --*) : ;;                       # no positional target: auto-detect below
    "")  : ;;
    *)   TARGET="$1"; shift ;;
esac
SCRATCH="" PROBE_WRITE=0 STATE_DIR=""
while (( $# )); do
    case "$1" in
        --probe-write) PROBE_WRITE=1; shift ;;
        --scratch)     SCRATCH="${2:-}"; PROBE_WRITE=1; shift 2 ;;
        --state-dir)   STATE_DIR="${2:-}"; shift 2 ;;
        --json)        JSON_OUT="${2:-}"; shift 2 ;;
        --no-json)     JSON_OUT=""; NO_JSON=1; shift ;;
        *) printf 'Opcion desconocida: %s\n' "$1"; exit 1 ;;
    esac
done

OUT="${ZRW_DISCOVERY_OUT:-/tmp/zrw-discovery-$(date '+%Y%m%d-%H%M%S').txt}"
NO_JSON="${NO_JSON:-0}"
JSON_OUT="${JSON_OUT-${OUT%.txt}.json}"

# -----------------------------------------------------------------------------
# Auto-detection. With no target the script behaves like the original pre_test:
# paste and run. It picks the mounted ZFS filesystem holding the most data,
# skipping the ones that are never reblock candidates (boot pool, system
# datasets, app/container storage). The choice is always printed so it can be
# overridden by passing the path explicitly.
# -----------------------------------------------------------------------------
autodetect_target() {
    local best="" bestb=0 name mp used
    while IFS=$'\t' read -r name mp used; do
        case "$mp" in -|legacy|none|/|/var/*|/usr/*|/etc/*|/boot/*) continue ;; esac
        case "$name" in
            boot-pool*|*/.system*|*/ix-apps*|*/.ix-virt*|*/.truenas_containers*) continue ;;
        esac
        [[ -d "$mp" ]] || continue
        [[ "$used" =~ ^[0-9]+$ ]] || continue
        (( used > bestb )) && { bestb="$used"; best="$mp"; }
    done < <(zfs list -H -p -o name,mountpoint,used -t filesystem 2>/dev/null)
    [[ -n "$best" ]] && printf '%s\n' "$best"
}

if [[ -z "$TARGET" ]]; then
    TARGET="$(autodetect_target || true)"
    AUTO_TARGET=1
    [[ -n "$TARGET" ]] || {
        printf 'No se pudo autodetectar un dataset de datos.\n'
        printf 'Indica el directorio a inspeccionar:\n    %s /mnt/pool/dataset\n' "$0"
        exit 1
    }
else
    AUTO_TARGET=0
fi

usage() {
    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}
[[ -d "$TARGET" ]] || {
    printf 'Uso: %s [directorio] [--probe-write] [--state-dir DIR] [--json FILE]\n\n' "$0"
    usage
}

# -----------------------------------------------------------------------------
# JSON accumulation. Only facts that are expensive or destructive to re-derive
# are captured while probing; everything cheap (command presence, dataset list,
# /proc availability) is re-read when the JSON is emitted at the end. That keeps
# the probe code readable instead of threading JSON calls through every branch.
# -----------------------------------------------------------------------------
J_HASH="" J_FLOCK=null J_FLOCK_EXCL=null J_RENICE=null J_IONICE=null
J_STATE_SYNC=null J_STATE_RENAME=null J_STATE_DS=""
J_RT_DONE=false J_RT_SAMEDIR=null J_RT_SHA=null J_RT_ACL=null J_RT_XATTR=null
J_RT_SPARSE=null J_RT_MTIME=null J_RT_ATIME=null J_RT_RENAME=null J_RT_HARDLINK=null
J_RT_SRCDS="" J_RT_DSTDS=""
J_ZDB_DBLK=null J_ZDB_DBLK_VALUE="" J_ACL_KEYS="" J_CAND=0 J_BYTES=0 J_SYNCF=null

# All output is tee'd so the operator sees progress and gets a file to send.
exec > >(tee "$OUT") 2>&1

sec()  { printf '\n============================================================\n %s\n============================================================\n' "$*"; }
sub()  { printf '\n--- %s ---\n' "$*"; }
kv()   { printf '%-28s %s\n' "$1:" "${2:-<vacio>}"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Runs a command, labelling it, and never lets a missing tool abort the report.
try() {
    local label="$1"; shift
    printf '\n[%s]\n$ %s\n' "$label" "$*"
    "$@" 2>&1 | sed 's/^/    /' || printf '    [exit %s]\n' "$?"
    return 0
}

sec "ZRW CAPABILITY DISCOVERY"
kv "fecha"       "$(date -Is)"
kv "objetivo"    "$TARGET"
kv "fase escritura" "$( (( PROBE_WRITE )) && echo "SI ${SCRATCH:+(scratch: $SCRATCH)}" || echo "NO (solo lectura)")"
kv "state dir"   "${STATE_DIR:-<no indicado>}"
kv "salida txt"  "$OUT"
kv "salida json" "$( (( NO_JSON )) && echo '<desactivada>' || echo "$JSON_OUT")"
(( AUTO_TARGET )) && {
    printf '\n    Objetivo AUTODETECTADO (el dataset de datos con mas uso).\n'
    printf '    Para inspeccionar otro:  %s /mnt/pool/otro-dataset\n' "$0"
}

# -----------------------------------------------------------------------------
sec "1. PLATAFORMA"
try platform uname -a
try os sh -c 'cat /etc/os-release 2>/dev/null | head -6'
try bash bash --version
kv "bash BASH_VERSION" "${BASH_VERSION:-?}"
kv "uid"               "$(id -u) ($(id -un))"
kv "shell del script"  "$0"

# -----------------------------------------------------------------------------
# Presence is not capability. For every command the worker runs, record the
# path and the version, so a later behaviour change can be attributed.
sec "2. INVENTARIO DE COMANDOS"
CRIT=(bash awk find sort grep sed head tail uniq stat df date sleep touch mv rm
      mkdir dirname basename ln rsync flock zfs sync sha256sum id kill)
OPT=(zdb nice renice ionice getfacl getfattr nfs4xdr_getfacl nfs4_getfacl jq
     realpath readlink whiptail dialog fzf nproc b2sum md5sum tmux lsof timeout
     numfmt setfacl setfattr)

printf '\n%-20s %-8s %s\n' "COMANDO" "ESTADO" "RUTA"
for c in "${CRIT[@]}"; do
    if have "$c"; then printf '%-20s %-8s %s\n' "$c" "OK" "$(command -v "$c")"
    else printf '%-20s %-8s %s\n' "$c" "FALTA" "*** CRITICO ***"; fi
done
for c in "${OPT[@]}"; do
    if have "$c"; then printf '%-20s %-8s %s\n' "$c" "OK" "$(command -v "$c")"
    else printf '%-20s %-8s %s\n' "$c" "--" "(opcional)"; fi
done

sub "versiones relevantes"
for c in rsync zfs jq b2sum md5sum sha256sum stat find awk; do
    have "$c" && printf '%-16s %s\n' "$c" "$("$c" --version 2>/dev/null | head -1)"
done
have nfs4xdr_getfacl && try nfs4xdr-version nfs4xdr_getfacl --version

# -----------------------------------------------------------------------------
# The worker asserts things about rsync and coreutils that it never verified on
# this host. Each probe below maps to one such assertion.
sec "3. CAPACIDADES FUNCIONALES"

sub "rsync: linea de capacidades completa"
try rsync-caps sh -c 'rsync --version 2>/dev/null | sed -n "1,12p"'
printf '\nprueba de la deteccion que usa el worker (sin pipeline, evita SIGPIPE):\n'
if [[ "$(rsync --version 2>/dev/null)" != *ACLs* ]]; then
    printf '    rsync NO declara ACLs\n'
else
    printf '    rsync declara ACLs -> OK\n'
fi
printf 'prueba de la construccion ANTIGUA (la que daba el falso aviso):\n'
( set -o pipefail; rsync --version 2>/dev/null | grep -qi 'ACLs' ) \
    && printf '    pipeline devolvio 0\n' || printf '    pipeline devolvio %s  <-- el bug reproducido\n' "$?"

sub "flock: prueba FUNCIONAL, no solo presencia"
# The entire concurrency model rests on this. Presence proves nothing: locking
# can be absent or a no-op depending on the filesystem holding the lock file.
FLOCK_DIR="${STATE_DIR:-$TARGET}"
if have flock; then
    FL="$FLOCK_DIR/.zrw-flock-probe.$$"
    if ( exec 200>"$FL" ) 2>/dev/null; then
        if flock -n -x "$FL" -c true 2>/dev/null; then
            printf '    flock exclusivo OK sobre %s\n' "$FLOCK_DIR"
            J_FLOCK=true
            # A second, non-blocking attempt while the first is held must fail.
            # The subshell records its verdict in a marker file, because a
            # variable set inside it would not survive back to the parent.
            ( exec 200>"$FL"; flock -x 200
              if flock -n -x "$FL" -c true 2>/dev/null; then
                  printf '    *** ATENCION: un segundo flock tuvo exito con el lock tomado\n'
                  printf '        el lock NO protege en este filesystem\n'
              else
                  printf '    exclusion mutua verificada -> el lock protege de verdad\n'
                  : >"$FL.excl"
              fi ) 2>/dev/null
            if [[ -f "$FL.excl" ]]; then J_FLOCK_EXCL=true; rm -f "$FL.excl"; else J_FLOCK_EXCL=false; fi
        else
            printf '    *** flock existe pero FALLO sobre %s\n' "$FLOCK_DIR"
            J_FLOCK=false
        fi
        rm -f "$FL"
    else
        printf '    no se pudo crear el archivo de lock en %s (permisos?)\n' "$FLOCK_DIR"
    fi
else
    printf '    flock NO disponible: dos workers podrian correr sobre el mismo job\n'
fi

sub "renice / ionice: ¿se aplican de verdad?"
# In a jail or under restrictive cgroups these commands exist and still fail.
if have renice; then
    if renice -n 19 -p $$ >/dev/null 2>&1; then printf '    renice 19 aplicado -> OK\n'; J_RENICE=true
    else printf '    *** renice existe pero NO pudo aplicarse\n'; J_RENICE=false; fi
    printf '    nice actual del proceso: %s\n' "$(ps -o ni= -p $$ 2>/dev/null | tr -d ' ')"
else printf '    renice no disponible\n'; fi
if have ionice; then
    if ionice -c 3 -p $$ >/dev/null 2>&1; then printf '    ionice idle aplicado -> OK\n'; J_IONICE=true
    else printf '    *** ionice existe pero NO pudo aplicarse\n'; J_IONICE=false; fi
    printf '    clase de I/O actual: %s\n' "$(ionice -p $$ 2>/dev/null)"
else printf '    ionice no disponible\n'; fi

sub "sync -f (durabilidad del checkpoint por archivo)"
# No pipeline: bajo pipefail, un grep -q que corta la lectura apenas encuentra
# la coincidencia puede recibir SIGPIPE al comando que todavia esta escribiendo
# el resto de --help. Es el mismo bug que este script ya prueba mas abajo contra
# 'rsync --version | grep -qi ACLs', ahora corregido tambien aqui.
if [[ "$(sync --help 2>&1)" == *-f* ]]; then printf '    sync soporta -f -> OK\n'; J_SYNCF=true
else printf '    sync NO soporta -f: el fsync del estado se degrada\n'; J_SYNCF=false; fi

sub "stat: formato que usa el worker"
try stat-fmt stat -c '%s %i %a %u %g %h | %x | %y' "$0"

sub "touch -d con nanosegundos (preservacion exacta de timestamps)"
T0="$(stat -c '%y' "$0")"
printf '    origen: %s\n' "$T0"
printf '    (el round-trip real se prueba en la fase scratch)\n'

sub "velocidad de hash sobre datos reales (decide el default de --hash)"
# Reads from the pool, writes nothing. Uses the largest file under the target
# that is still small enough to measure quickly.
PROBE_FILE="$(find "$TARGET" -type f -size +64M -size -512M -print -quit 2>/dev/null)"
[[ -n "$PROBE_FILE" ]] || PROBE_FILE="$(find "$TARGET" -type f -size +1M -print -quit 2>/dev/null)"
if [[ -n "$PROBE_FILE" ]]; then
    PSZ="$(stat -c '%s' "$PROBE_FILE")"
    kv "archivo de prueba" "$PROBE_FILE"
    kv "tamano"            "$PSZ bytes"
    for h in sha256sum b2sum md5sum; do
        have "$h" || { printf '%-10s no disponible\n' "$h"; continue; }
        S="$(date +%s%N)"; "$h" "$PROBE_FILE" >/dev/null 2>&1; E="$(date +%s%N)"
        MS=$(( (E-S)/1000000 )); (( MS < 1 )) && MS=1
        MBPS=$(( PSZ/1024/1024*1000/MS ))
        printf '%-10s %6s ms   %s MB/s\n' "$h" "$MS" "$MBPS"
        J_HASH="${J_HASH:+$J_HASH,}\"${h%sum}\":{\"present\":true,\"mbps\":$MBPS}"
    done
    printf '\n(la segunda pasada suele ir por ARC; lo relevante es la relacion entre algoritmos)\n'
else
    printf '    no se encontro un archivo adecuado bajo %s\n' "$TARGET"
fi

# -----------------------------------------------------------------------------
sec "4. ZFS: TOPOLOGIA Y PROPIEDADES"
try zfs-version zfs version
try zpool zpool list

sub "TODOS los datasets con las propiedades que el worker usa"
printf '(esto es lo que alimenta el mapa de datasets: recordsize, acltype, xattr, atime)\n'
try zfs-props zfs list -H -o name,mountpoint,recordsize,acltype,xattr,atime,relatime,compression -t filesystem

sub "datasets bajo el objetivo"
printf '%-42s %-10s %-9s %-6s %-6s %s\n' "DATASET" "RECORDSIZE" "ACLTYPE" "XATTR" "ATIME" "MOUNTPOINT"
zfs list -H -o name,mountpoint,recordsize,acltype,xattr,atime -t filesystem 2>/dev/null |
while IFS=$'\t' read -r n mp rs at xa am; do
    case "$mp" in "$TARGET"|"$TARGET"/*) printf '%-42s %-10s %-9s %-6s %-6s %s\n' "$n" "$rs" "$at" "$xa" "$am" "$mp" ;; esac
done

sub "dataset que contiene el objetivo"
try df-target df -P -- "$TARGET"
DS="$(zfs list -H -o name,mountpoint -t filesystem 2>/dev/null |
      awk -F'\t' -v t="$TARGET" '$2!="-" && (t==$2 || index(t,$2"/")==1){ if (length($2)>m){m=length($2);d=$1} } END{print d}')"
kv "dataset resuelto" "$DS"
if [[ -n "$DS" ]]; then
    try zfs-all-props zfs get -H -o property,value \
        recordsize,acltype,aclmode,aclinherit,xattr,atime,relatime,compression,casesensitivity,sync "$DS"
    sub "¿acepta 'zfs get' el separador --? (el fix1 lo usa)"
    if zfs get -H -o value acltype -- "$DS" >/dev/null 2>&1; then printf "    si, 'zfs get ... -- <ds>' funciona\n"
    else printf "    NO: 'zfs get ... -- <ds>' falla -> get_acl_type_for_dataset devolveria error\n"; fi
fi

sub "mount options reales (revelan noatime/nfs4acl aunque la propiedad diga otra cosa)"
try mounts sh -c "mount | grep -E ' on ${TARGET%/}' | head -5"

sub "zdb: forma REAL de la salida (valida como el worker lee dblk)"
if have zdb && [[ -n "$PROBE_FILE" && -n "$DS" ]]; then
    MP="$(zfs get -H -o value mountpoint "$DS" 2>/dev/null)"
    REL="${PROBE_FILE#"$MP"/}"
    kv "dataset" "$DS"; kv "ruta relativa" "$REL"
    # zdb -O walks pool metadata directly, competing for real disk I/O with
    # anything else touching the pool. Confirmed live on the reference NAS
    # during a scrub: a single call blocked over 7 minutes. Bounded here so
    # the probe itself can never hang the way it caught the worker doing.
    ZTO=""; have timeout && ZTO="timeout 5"
    try zdb-O sh -c "${ZTO:+$ZTO }zdb -O '$DS' '$REL' 2>&1 | head -40"
    printf '\nlineas que contienen un tamano de bloque:\n'
    $ZTO zdb -O "$DS" "$REL" 2>/dev/null | grep -Ei 'size|blk|dblk|lsize|psize' | sed 's/^/    /' | head -20

    # The decisive question: the worker locates the dblk column by its header
    # and reads that column from the first data row. If it cannot be found here,
    # the advisory hint stays UNKNOWN forever -- safe, but useless.
    #
    # dblk, not lsize: lsize is the file's logical size (a 2 GiB file reports
    # 2 GiB whether its blocks are 128K or 1M), so it answers nothing.
    ZDBLK="$($ZTO zdb -O "$DS" "$REL" 2>/dev/null | awk '
        /(^|[[:space:]])dblk([[:space:]]|$)/ { for (i=1;i<=NF;i++) if ($i=="dblk") col=i; next }
        col && NF >= col && $1 ~ /^[0-9]+$/  { print $col; exit }
    ')"
    if [[ -n "$ZDBLK" ]]; then
        J_ZDB_DBLK=true; J_ZDB_DBLK_VALUE="$ZDBLK"
        printf '\n    columna dblk localizada -> el worker leera: %s\n' "$ZDBLK"
        printf '    (recordsize del dataset: %s)\n' "$(zfs get -H -o value recordsize "$DS" 2>/dev/null)"
    else
        J_ZDB_DBLK=false
        printf '\n    no se localizo la columna dblk -> el hint quedara siempre en UNKNOWN\n'
    fi
else
    printf '    zdb no disponible o falta archivo/dataset de prueba\n'
fi

# -----------------------------------------------------------------------------
# This is the section that unblocks the pending ACL redesign.
sec "5. ACL Y XATTR: QUE SE PUEDE VERIFICAR REALMENTE"
if [[ -z "$PROBE_FILE" ]]; then
    printf 'Sin archivo de prueba; se omite.\n'
else
kv "archivo" "$PROBE_FILE"
kv "acltype del dataset" "$(zfs get -H -o value acltype "$DS" 2>/dev/null)"

sub "getfacl (modelo POSIX)"
if have getfacl; then try getfacl getfacl --absolute-names -n -- "$PROBE_FILE"
else printf '    getfacl no disponible\n'; fi

sub "nfs4xdr_getfacl (texto)"
if have nfs4xdr_getfacl; then try nfs4xdr nfs4xdr_getfacl -- "$PROBE_FILE"
else printf '    nfs4xdr_getfacl NO disponible\n'; fi

sub "nfs4xdr_getfacl -j (JSON: define que campos hay que ignorar)"
if have nfs4xdr_getfacl && have jq; then
    try nfs4xdr-json sh -c "nfs4xdr_getfacl -j -- '$PROBE_FILE' | jq ."
    J_ACL_KEYS="$(nfs4xdr_getfacl -j -- "$PROBE_FILE" 2>/dev/null | jq -c 'if type=="object" then keys else [] end' 2>/dev/null)"
    printf '\nclaves de primer nivel del JSON:\n'
    nfs4xdr_getfacl -j -- "$PROBE_FILE" 2>/dev/null | jq -r 'if type=="object" then (keys|join(", ")) else "tipo: \(type)" end' | sed 's/^/    /'
    printf '\ncomo queda tras del(.path, .fhandle) - lo que compara el fix1:\n'
    nfs4xdr_getfacl -j -- "$PROBE_FILE" 2>/dev/null | jq -c 'del(.path, .fhandle)' | sed 's/^/    /' | head -5
else
    printf '    falta nfs4xdr_getfacl y/o jq -> la verificacion NFSv4 no seria posible\n'
fi

sub "nfs4_getfacl (alternativa)"
if have nfs4_getfacl; then try nfs4-getfacl nfs4_getfacl "$PROBE_FILE"
else printf '    nfs4_getfacl no disponible\n'; fi

sub "getfattr (xattr)"
if have getfattr; then try getfattr getfattr -d -m - --absolute-names -- "$PROBE_FILE"
else printf '    getfattr no disponible\n'; fi
fi

# -----------------------------------------------------------------------------
# The job state does not live in the target tree. flock, sync -f, the atomic
# rename of every .state file and the anchor registry all happen here, so this
# filesystem deserves its own probe.
sec "5b. FILESYSTEM DEL ESTADO (jobs/)"
if [[ -z "$STATE_DIR" ]]; then
    printf 'No se indico --state-dir. Este es el directorio donde el worker guarda\n'
    printf 'jobs/, y donde ocurren flock, sync -f y el rename atomico del estado.\n'
    printf 'Puede estar en otro pool con otras propiedades. Para incluirlo:\n'
    printf '    %s %s --state-dir /ruta/donde/vive/jobs\n' "$0" "$TARGET"
elif [[ ! -d "$STATE_DIR" ]]; then
    printf 'El directorio indicado no existe: %s\n' "$STATE_DIR"
else
    kv "state dir" "$STATE_DIR"
    try state-df df -h -- "$STATE_DIR"
    SDS="$(zfs list -H -o name,mountpoint -t filesystem 2>/dev/null |
           awk -F'\t' -v t="$STATE_DIR" '$2!="-" && (t==$2 || index(t,$2"/")==1){ if (length($2)>m){m=length($2);d=$1} } END{print d}')"
    kv "dataset del estado" "${SDS:-<no es ZFS>}"; J_STATE_DS="$SDS"
    if [[ -n "$SDS" && -n "$DS" && "$SDS" != "$DS" ]]; then
        printf '\n    NOTA: el estado vive en OTRO dataset que los datos (%s vs %s).\n' "$SDS" "$DS"
        printf '    Es correcto y hasta recomendable, pero sus propiedades importan aparte.\n'
    fi
    [[ -n "$SDS" ]] && try state-props zfs get -H -o property,value recordsize,compression,sync,atime "$SDS"
    sub "escritura atomica + fsync del estado"
    ST="$STATE_DIR/.zrw-state-probe.$$"
    if printf 'status=PENDING\n' >"$ST.tmp" 2>/dev/null; then
        if sync -f "$ST.tmp" 2>/dev/null; then printf '    sync -f sobre el temporal: OK\n'; J_STATE_SYNC=true
        else printf '    sync -f fallo\n'; J_STATE_SYNC=false; fi
        if mv -f "$ST.tmp" "$ST" 2>/dev/null; then printf '    rename atomico: OK\n'; J_STATE_RENAME=true
        else printf '    rename fallo\n'; J_STATE_RENAME=false; fi
        printf '    lectura: %s\n' "$(head -n1 "$ST" 2>/dev/null)"
        rm -f "$ST" "$ST.tmp"
    else
        printf '    NO se puede escribir en %s\n' "$STATE_DIR"
    fi
fi

# -----------------------------------------------------------------------------
sec "6. METRICAS DEL KERNEL (governor)"
sub "PSI - /proc/pressure"
if [[ -d /proc/pressure ]]; then
    for f in io cpu memory; do
        printf '/proc/pressure/%s:\n' "$f"
        sed 's/^/    /' "/proc/pressure/$f" 2>/dev/null || printf '    <no legible>\n'
    done
else
    printf '    /proc/pressure NO existe: el governor perderia su mejor senal\n'
fi

sub "/proc/diskstats - nombres de dispositivo (valida el filtro awk del worker)"
printf 'dispositivos detectados:\n'
awk '{print "    " $3}' /proc/diskstats 2>/dev/null | head -40
printf '\nlos que matchea el filtro actual del worker (sd|nvme|vd|hd):\n'
awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$/ {print "    " $3}' /proc/diskstats 2>/dev/null
printf '\nzvols/particiones que el filtro EXCLUYE (correcto si son zd* o sdaN):\n'
awk '$3 !~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$/ {print "    " $3}' /proc/diskstats 2>/dev/null | head -20
printf '\nmuestra cruda (primeras 5 lineas, para los campos 10 y 11):\n'
head -5 /proc/diskstats 2>/dev/null | sed 's/^/    /'

sub "cpu / load / memoria"
try loadavg cat /proc/loadavg
try cpu-line sh -c "awk '/^cpu /{print;exit}' /proc/stat"
try meminfo sh -c "head -5 /proc/meminfo"
kv "cpus (/proc/cpuinfo)" "$(awk '/^processor[[:space:]]*:/{c++} END{print c+0}' /proc/cpuinfo 2>/dev/null)"
have nproc && kv "nproc" "$(nproc)"

# -----------------------------------------------------------------------------
sec "7. ESPACIO Y TAMANOS DEL OBJETIVO"
try df-h df -h -- "$TARGET"
printf '\ncandidatos > 2 GiB bajo el objetivo (solo cuenta, no lista):\n'
N=0; B=0
while IFS= read -r -d '' f; do
    s="$(stat -c '%s' -- "$f" 2>/dev/null)" || continue
    (( s > 2147483648 )) && { N=$((N+1)); B=$((B+s)); }
done < <(find "$TARGET" \( -name .zfs -prune \) -o -type f -print0 2>/dev/null)
kv "candidatos > 2 GiB" "$N"
kv "bytes totales"      "$B"
J_CAND="$N"; J_BYTES="$B"
kv "aprox"              "$(awk -v b="$B" 'BEGIN{printf "%.2f TiB", b/1024/1024/1024/1024}')"

# -----------------------------------------------------------------------------
# Optional write phase. Everything here happens inside SCRATCH and is removed.
sec "8. ROUND-TRIP REAL (opcional: --probe-write)"
if (( ! PROBE_WRITE )); then
    printf 'Omitido. Para ejecutarlo:\n'
    printf '    %s %s --probe-write\n\n' "$0" "$TARGET"
    printf 'Esta fase copia UN archivo real con las mismas opciones que el worker\n'
    printf '(rsync -aAXS) EN SU PROPIO DIRECTORIO, que es exactamente lo que hace el\n'
    printf 'worker, y compara ACL/xattr/timestamps origen vs copia.\n\n'
    printf 'El directorio importa: la ACL NFSv4 de un archivo nuevo hereda del\n'
    printf 'directorio padre. Copiar a otro lado mediria una herencia distinta y\n'
    printf 'daria una respuesta que no aplica al caso real.\n\n'
    printf 'El original NUNCA se modifica y la copia se borra al terminar.\n'
elif [[ -z "$PROBE_FILE" ]]; then
    printf 'No hay archivo de prueba bajo %s\n' "$TARGET"
else
    # Prefer a small file: this phase copies real data.
    SMALL="$(find "$TARGET" -type f -size +1M -size -64M -print -quit 2>/dev/null)"
    [[ -n "$SMALL" ]] || SMALL="$PROBE_FILE"
    SRCDIR="$(dirname -- "$SMALL")"

    # Default: same directory as the source, like the worker. --scratch only
    # overrides it, and the report says loudly that the ACL result then differs
    # in meaning.
    if [[ -n "$SCRATCH" ]]; then
        DSTDIR="$SCRATCH"
        SAME_DIR=0
    else
        DSTDIR="$SRCDIR"
        SAME_DIR=1
    fi
    DST="$DSTDIR/.zrw-discovery-probe.$$"

    kv "origen"            "$SMALL"
    kv "directorio origen" "$SRCDIR"
    kv "directorio copia"  "$DSTDIR"
    SRC_DS="$(zfs list -H -o name,mountpoint -t filesystem 2>/dev/null |
        awk -F'\t' -v t="$SRCDIR" '$2!="-" && (t==$2 || index(t,$2"/")==1){ if (length($2)>m){m=length($2);d=$1} } END{print d}')"
    DST_DS="$(zfs list -H -o name,mountpoint -t filesystem 2>/dev/null |
        awk -F'\t' -v t="$DSTDIR" '$2!="-" && (t==$2 || index(t,$2"/")==1){ if (length($2)>m){m=length($2);d=$1} } END{print d}')"
    kv "dataset origen" "$SRC_DS"
    kv "dataset copia"  "$DST_DS"

    J_RT_SRCDS="$SRC_DS"; J_RT_DSTDS="$DST_DS"
    J_RT_SAMEDIR="$( (( SAME_DIR )) && echo true || echo false)"
    if (( SAME_DIR )); then
        printf '\n    MISMO DIRECTORIO que el origen -> reproduce fielmente al worker.\n'
    else
        printf '\n    *** --scratch en uso: la copia va a OTRO directorio.\n'
        [[ "$SRC_DS" != "$DST_DS" ]] && printf '    *** y a OTRO DATASET (%s -> %s).\n' "$SRC_DS" "$DST_DS"
        printf '    El resultado de ACL es SOLO INDICATIVO: un archivo nuevo hereda la\n'
        printf '    ACL de su directorio padre, y aqui el padre no es el mismo que usara\n'
        printf '    el worker. Para una respuesta valida, usa --probe-write sin --scratch.\n'
    fi
    [[ -d "$DSTDIR" ]] || { printf '\n    El directorio de copia no existe: %s\n' "$DSTDIR"; DST=""; }

    # Space check before writing anything: the same margin the worker itself
    # uses (tamano + 20%, piso 1 GiB), applied here too so a probe never runs
    # into a full destination mid-copy.
    if [[ -n "$DST" ]]; then
        SPROBE_SIZE="$(stat -c '%s' -- "$SMALL" 2>/dev/null || echo 0)"
        SPROBE_AVAIL="$(df -B1 --output=avail -- "$DSTDIR" 2>/dev/null | tail -n1 | tr -dc '0-9')"
        SPROBE_MARGIN=$(( SPROBE_SIZE/5 )); (( SPROBE_MARGIN < 1073741824 )) && SPROBE_MARGIN=1073741824
        SPROBE_NEED=$(( SPROBE_SIZE + SPROBE_MARGIN ))
        printf '\n    espacio requerido (tamano+20%%/min 1GiB): %s\n' "$SPROBE_NEED"
        printf '    espacio disponible en el destino       : %s\n' "${SPROBE_AVAIL:-0}"
        if [[ -z "$SPROBE_AVAIL" ]] || (( SPROBE_AVAIL < SPROBE_NEED )); then
            printf '    *** ESPACIO INSUFICIENTE en %s -- se omite la copia de prueba.\n' "$DSTDIR"
            DST=""
        fi
    fi

    if [[ -n "$DST" ]]; then
    sub "copia con las mismas opciones del worker"
    try rsync-copy rsync -aAXS --no-compress -- "$SMALL" "$DST"

    if [[ -f "$DST" ]]; then
        sub "comparacion de metadatos"
        printf '%-14s %-32s %s\n' "campo" "origen" "copia"
        for fmt in '%s:tamano' '%a:mode' '%u:uid' '%g:gid' '%h:nlink' '%b:bloques'; do
            k="${fmt%%:*}"; lbl="${fmt#*:}"
            printf '%-14s %-32s %s\n' "$lbl" "$(stat -c "$k" "$SMALL")" "$(stat -c "$k" "$DST")"
        done
        printf '%-14s %-32s %s\n' "mtime" "$(stat -c '%y' "$SMALL")" "$(stat -c '%y' "$DST")"
        printf '%-14s %-32s %s\n' "atime" "$(stat -c '%x' "$SMALL")" "$(stat -c '%x' "$DST")"

        sub "sparse: asignacion real en disco"
        # Without this sync the copy's %b is read while the write is still in
        # an uncommitted transaction group, so the number means nothing.
        sync -f "$DST" 2>/dev/null || sync
        SB="$(stat -c '%b' "$SMALL")"; DB="$(stat -c '%b' "$DST")"
        SAP="$(stat -c '%s' "$SMALL")"; DAP="$(stat -c '%s' "$DST")"
        COMPR="$(zfs get -H -o value compression "$DST_DS" 2>/dev/null || echo desconocida)"
        printf '    tamano aparente : origen %s / copia %s%s\n' \
            "$SAP" "$DAP" "$( [[ "$SAP" == "$DAP" ]] && echo '  -> igual' || echo '  -> *** DIFIERE')"
        printf '    bloques (%%b)    : origen %s / copia %s\n' "$SB" "$DB"
        printf '    compression     : %s\n' "$COMPR"
        if [[ "$COMPR" != off && "$COMPR" != desconocida ]]; then
            # %b counts blocks allocated after compression: two equally sparse
            # files can differ, and two with different sparseness can match. It
            # is not a verdict on a dataset that compresses.
            printf '    -> INDICATIVO: el dataset comprime (%s), asi que %%b mide compresion,\n' "$COMPR"
            printf '       no agujeros. La preservacion de sparse no se puede afirmar desde aqui.\n'
            J_RT_SPARSE=null
        elif [[ "$SB" == "$DB" ]]; then
            printf '    -> preservado (compression=off: %%b si refleja la asignacion real)\n'
            J_RT_SPARSE=true
        else
            printf '    -> *** DIFIERE con compression=off: la copia perdio o gano asignacion\n'
            J_RT_SPARSE=false
        fi

        sub "hash origen vs copia"
        HA="$(sha256sum "$SMALL" | awk '{print $1}')"; HB="$(sha256sum "$DST" | awk '{print $1}')"
        printf '    origen: %s\n    copia : %s\n' "$HA" "$HB"
        if [[ "$HA" == "$HB" ]]; then printf '    -> IDENTICO\n'; J_RT_SHA=true
        else printf '    -> *** DIFIERE\n'; J_RT_SHA=false; fi
        J_RT_DONE=true

        sub "ACL NFSv4: ¿sobrevive al copiado?"
        if have nfs4xdr_getfacl && have jq; then
            A="$(nfs4xdr_getfacl -j -- "$SMALL" 2>/dev/null | jq -S -c 'del(.path,.fhandle)')"
            B="$(nfs4xdr_getfacl -j -- "$DST"  2>/dev/null | jq -S -c 'del(.path,.fhandle)')"
            printf '    origen: %s\n' "${A:0:400}"
            printf '    copia : %s\n' "${B:0:400}"
            if [[ -z "$A" || -z "$B" ]]; then
                printf '\n    RESULTADO: no se pudo obtener la ACL de uno de los dos\n'
            elif [[ "$A" == "$B" ]]; then
                J_RT_ACL=true
                printf '\n    RESULTADO: ACL NFSv4 IDENTICA tras rsync -A%s\n' \
                    "$( (( SAME_DIR )) && echo ' (prueba valida: mismo directorio)' || echo ' (SOLO INDICATIVO: otro directorio)')"
            else
                J_RT_ACL=false
                printf '\n    RESULTADO: DIFIEREN. Diferencia campo a campo:\n'
                diff <(nfs4xdr_getfacl -j -- "$SMALL" 2>/dev/null | jq -S 'del(.path,.fhandle)') \
                     <(nfs4xdr_getfacl -j -- "$DST"  2>/dev/null | jq -S 'del(.path,.fhandle)') | sed 's/^/      /'
                (( SAME_DIR )) || printf '      (recordar: --scratch invalida esta comparacion)\n'
            fi
        else
            printf '    sin nfs4xdr_getfacl/jq: no se puede comparar ACL NFSv4\n'
        fi

        sub "xattr: ¿sobreviven?"
        if have getfattr; then
            A="$(getfattr -d -m - --absolute-names -- "$SMALL" 2>/dev/null | sed '1d')"
            B="$(getfattr -d -m - --absolute-names -- "$DST"  2>/dev/null | sed '1d')"
            if [[ "$A" == "$B" ]]; then printf '    xattr identicos\n'; J_RT_XATTR=true
            else J_RT_XATTR=false; printf '    DIFIEREN:\n'; diff <(printf '%s' "$A") <(printf '%s' "$B") | sed 's/^/      /'; fi
        fi

        sub "touch -d round-trip: mtime Y atime con nanosegundos"
        # atime is the one that historically broke, so it gets tested too.
        OM="$(stat -c '%y' "$SMALL")"; OA="$(stat -c '%x' "$SMALL")"
        touch -m -d "$OM" "$DST" 2>/dev/null
        touch -a -d "$OA" "$DST" 2>/dev/null
        NM="$(stat -c '%y' "$DST")"; NA="$(stat -c '%x' "$DST")"
        if [[ "$NM" == "$OM" ]]; then printf '    mtime restaurado exacto -> OK\n'; J_RT_MTIME=true
        else J_RT_MTIME=false; printf '    mtime PERDIO PRECISION:\n      esperado %s\n      obtenido %s\n' "$OM" "$NM"; fi
        if [[ "$NA" == "$OA" ]]; then printf '    atime restaurado exacto -> OK\n'; J_RT_ATIME=true
        else J_RT_ATIME=false; printf '    atime PERDIO PRECISION:\n      esperado %s\n      obtenido %s\n' "$OA" "$NA"; fi

        sub "rename atomico dentro del mismo directorio (la frontera de commit)"
        if mv -f "$DST" "$DST.renamed" 2>/dev/null; then
            printf '    mv dentro del directorio: OK -> el commit del worker es viable aqui\n'; J_RT_RENAME=true
            mv -f "$DST.renamed" "$DST" 2>/dev/null
        else
            printf '    *** mv fallo: la frontera de commit NO funcionaria aqui\n'; J_RT_RENAME=false
        fi

        sub "hardlink y nlink (ancla de rollback)"
        if ln "$DST" "$DST.rollback" 2>/dev/null; then
            printf '    hardlink creado; nlink=%s -> el ancla de rollback es viable\n' "$(stat -c '%h' "$DST")"; J_RT_HARDLINK=true
            rm -f "$DST.rollback"
            printf '    tras borrar el ancla, nlink=%s\n' "$(stat -c '%h' "$DST")"
        else
            printf '    *** NO se pudo crear hardlink: el ancla de rollback NO funcionaria aqui\n'; J_RT_HARDLINK=false
        fi

        sub "sync -f sobre el archivo"
        sync -f "$DST" 2>/dev/null && printf '    sync -f OK\n' || printf '    sync -f fallo\n'

        sub "limpieza"
        rm -f "$DST" "$DST.rollback" "$DST.renamed"
        [[ -e "$DST" ]] && printf '    *** QUEDO UN RESIDUO: %s\n' "$DST" || printf '    temporales eliminados\n'
        printf '    origen intacto: %s\n' "$( [[ "$(sha256sum "$SMALL" | awk '{print $1}')" == "$HA" ]] && echo SI || echo '*** NO')"
    else
        printf '    la copia no se creo; revisar permisos de %s\n' "$DSTDIR"
    fi
    fi
fi

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# JSON emission.
#
# The expensive or one-shot facts were captured while probing (J_* above);
# everything cheap is re-read here. The result is meant to be machine-read and
# to become a fixture for the worker's own capability tests, so the shape is
# stable and every unprobed field is explicitly null rather than absent.
# -----------------------------------------------------------------------------
jq_str() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g')"; }

emit_json() {
    local f="$1" c first
    {
    printf '{\n'
    printf '  "schema": "zrw-discovery/1",\n'
    printf '  "generated": %s,\n' "$(jq_str "$(date -Is)")"
    printf '  "host": {"kernel": %s, "os": %s, "bash": %s, "uid": %s, "cpus": %s},\n' \
        "$(jq_str "$(uname -r)")" \
        "$(jq_str "$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null)")" \
        "$(jq_str "${BASH_VERSION:-}")" "$(id -u)" \
        "$(awk '/^processor[[:space:]]*:/{c++} END{print c+0}' /proc/cpuinfo 2>/dev/null || echo 0)"

    # Commands: presence and resolved path for every one the worker may run.
    printf '  "commands": {'
    first=1
    for c in "${CRIT[@]}" "${OPT[@]}"; do
        (( first )) || printf ', '; first=0
        if have "$c"; then printf '%s: {"present": true, "path": %s}' "$(jq_str "$c")" "$(jq_str "$(command -v "$c")")"
        else printf '%s: {"present": false, "path": null}' "$(jq_str "$c")"; fi
    done
    printf '},\n'

    printf '  "rsync": {"version": %s, "acls": %s, "xattrs": %s},\n' \
        "$(jq_str "$(rsync --version 2>/dev/null | head -1)")" \
        "$( [[ "$(rsync --version 2>/dev/null)" == *ACLs* ]] && echo true || echo false)" \
        "$( [[ "$(rsync --version 2>/dev/null)" == *xattrs* ]] && echo true || echo false)"

    printf '  "hash": {%s},\n' "$J_HASH"

    printf '  "acl": {"backends": {"nfs4xdr_getfacl": %s, "nfs4_getfacl": %s, "getfacl": %s, "getfattr": %s, "jq": %s},\n' \
        "$(have nfs4xdr_getfacl && echo true || echo false)" \
        "$(have nfs4_getfacl && echo true || echo false)" \
        "$(have getfacl && echo true || echo false)" \
        "$(have getfattr && echo true || echo false)" \
        "$(have jq && echo true || echo false)"
    printf '          "json_keys": %s},\n' "${J_ACL_KEYS:-null}"

    # Full dataset map: the input the worker's DS_* arrays would be built from.
    printf '  "zfs": {"version": %s, "datasets": [' "$(jq_str "$(zfs version 2>/dev/null | head -1)")"
    first=1
    while IFS=$'\t' read -r n mp rs at xa am cp; do
        [[ -n "$n" ]] || continue
        (( first )) || printf ', '; first=0
        printf '{"name": %s, "mountpoint": %s, "recordsize": %s, "acltype": %s, "xattr": %s, "atime": %s, "compression": %s}' \
            "$(jq_str "$n")" "$(jq_str "$mp")" "$(jq_str "$rs")" "$(jq_str "$at")" "$(jq_str "$xa")" "$(jq_str "$am")" "$(jq_str "$cp")"
    done < <(zfs list -H -o name,mountpoint,recordsize,acltype,xattr,atime,compression -t filesystem 2>/dev/null)
    printf ']},\n'

    printf '  "target": {"path": %s, "auto_selected": %s, "dataset": %s, "candidates_over_2g": %s, "bytes": %s, "free_bytes": %s},\n' \
        "$(jq_str "$TARGET")" "$( (( AUTO_TARGET )) && echo true || echo false)" \
        "$(jq_str "${DS:-}")" "${J_CAND:-0}" "${J_BYTES:-0}" \
        "$(df -B1 --output=avail -- "$TARGET" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"

    printf '  "state_dir": {"path": %s, "dataset": %s, "flock": %s, "sync_f": %s, "atomic_rename": %s},\n' \
        "$(jq_str "${STATE_DIR:-}")" "$(jq_str "${J_STATE_DS:-}")" \
        "$J_FLOCK" "${J_STATE_SYNC}" "${J_STATE_RENAME}"

    printf '  "metrics": {"psi": %s, "diskstats": %s, "devices_matched": [' \
        "$( [[ -d /proc/pressure ]] && echo true || echo false)" \
        "$( [[ -r /proc/diskstats ]] && echo true || echo false)"
    first=1
    while read -r d; do (( first )) || printf ', '; first=0; printf '%s' "$(jq_str "$d")"; done \
        < <(awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$/ {print $3}' /proc/diskstats 2>/dev/null)
    printf ']},\n'

    printf '  "primitives": {"flock": %s, "flock_mutual_exclusion": %s, "sync_f": %s, "renice": %s, "ionice": %s},\n' \
        "$J_FLOCK" "$J_FLOCK_EXCL" "$J_SYNCF" "$J_RENICE" "$J_IONICE"

    printf '  "zdb": {"present": %s, "dblk_column_found": %s, "dblk_value": %s},\n' \
        "$(have zdb && echo true || echo false)" "$J_ZDB_DBLK" "$(jq_str "${J_ZDB_DBLK_VALUE:-}")"

    printf '  "roundtrip": {"performed": %s, "same_directory": %s, "src_dataset": %s, "dst_dataset": %s,\n' \
        "$J_RT_DONE" "$J_RT_SAMEDIR" "$(jq_str "${J_RT_SRCDS:-}")" "$(jq_str "${J_RT_DSTDS:-}")"
    printf '                "sha_identical": %s, "acl_identical": %s, "xattr_identical": %s, "sparse_preserved": %s,\n' \
        "$J_RT_SHA" "$J_RT_ACL" "$J_RT_XATTR" "$J_RT_SPARSE"
    printf '                "mtime_exact": %s, "atime_exact": %s, "rename_same_dir": %s, "hardlink": %s}\n' \
        "$J_RT_MTIME" "$J_RT_ATIME" "$J_RT_RENAME" "$J_RT_HARDLINK"
    printf '}\n'
    } >"$f"
}

sec "FIN"
kv "reporte txt" "$OUT"
if (( NO_JSON )) || [[ -z "$JSON_OUT" ]]; then
    kv "reporte json" "<desactivado>"
else
    if emit_json "$JSON_OUT"; then
        kv "reporte json" "$JSON_OUT"
        if have jq && jq empty "$JSON_OUT" 2>/dev/null; then
            kv "json valido" "si (verificado con jq)"
        elif have jq; then
            kv "json valido" "*** NO - revisar $JSON_OUT"
        else
            kv "json valido" "sin jq para verificarlo"
        fi
    else
        kv "reporte json" "*** fallo la generacion"
    fi
fi
printf '\nConserve ambos archivos: el .txt es para inspeccion humana, el .json es el\n'
printf 'formato estructurado, pensado para automatizacion y para usarse como\n'
printf 'fixture en los tests.\n'
printf '\nReviselos antes de compartirlos fuera de este entorno: contienen nombres\n'
printf 'de datasets, rutas y nombres de archivos del pool (no contienen\n'
printf 'credenciales).\n\n'
