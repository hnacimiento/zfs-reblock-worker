#!/usr/bin/env bash
# =============================================================================
# zrw-disk-health.sh - diagnostico de hardware de almacenamiento y ZFS.
#
# NO es parte del ZFS Reblock Worker: no lo usa, no lo necesita, y no debe
# importarse desde el. Es una herramienta de descubrimiento aparte, para el
# ecosistema TrueNAS en general - discos, bus USB, y el pool ZFS que los
# contiene - pensada para responder "donde esta el cuello de botella" y
# "que tan sano esta el disco", no para validar el worker.
#
# 100% de solo lectura. Ningun comando de este script escribe, modifica ni
# borra nada del pool, de un dataset ni de un disco. Es seguro correrlo con
# un job real del worker corriendo al mismo tiempo (los comandos son livianos:
# lecturas de /sys, /proc, smartctl -i/-a, zpool status/get/iostat).
#
# Que hace:
#   1. Identifica cada pool no-boot y sus vdevs de datos (disco fisico, bus,
#      si es USB/SATA/NVMe, virtualizacion del host).
#   2. Intenta SMART por cada variante conocida de bridge USB-SATA.
#   3. Topologia y velocidad de enlace USB negociada.
#   4. Historial de resets/desconexiones USB desde el arranque.
#   5. Driver de bloque en uso (uas/usb-storage/ahci/nvme) y gestion de
#      energia (autosuspend).
#   6. Scheduler y profundidad de cola de cada disco.
#   7. Propiedades y salud del pool (ashift, fragmentacion, errores).
#   8. Historial de eventos ZFS filtrado a error/checksum/degraded/vdev.
#   9. Memoria, swap y estadisticas de ARC (cuello de botella de ZFS).
#  10. CPU y load promedio.
#  11. Muestras en vivo de iostat / zpool iostat (throughput y latencia
#      real, con y sin desglose por vdev).
#
# Uso:
#   ./zrw-disk-health.sh                    # todos los pools no-boot
#   ./zrw-disk-health.sh --pool toolbox      # solo ese pool
#   ./zrw-disk-health.sh --samples 5 --interval 2   # mas muestras en vivo
#
# Salida: texto plano a stdout Y a un archivo con marca de tiempo
# (ZRW_DISKHEALTH_OUT lo puede fijar; si no, /tmp/zrw-disk-health-<ts>.txt).
# Revisalo antes de compartirlo: incluye nombres de pool/dataset y modelos
# de disco, no credenciales.
# =============================================================================
set -uo pipefail

POOL_FILTER="" SAMPLES=3 INTERVAL=2
while (( $# )); do
    case "$1" in
        --pool)     POOL_FILTER="$2"; shift 2 ;;
        --samples)  SAMPLES="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        *) printf 'Opcion desconocida: %s\n' "$1" >&2; exit 1 ;;
    esac
done

OUT="${ZRW_DISKHEALTH_OUT:-/tmp/zrw-disk-health-$(date '+%Y%m%d-%H%M%S').txt}"
exec > >(tee "$OUT") 2>&1

hr()   { printf '%s\n' "══════════════════════════════════════════════════════════════════════════"; }
section() { printf '\n'; hr; printf '  %s\n' "$1"; hr; }
why()  { printf '\n  Por que: %s\n' "$1"; }
run()  { printf '\n  $ %s\n' "$*"; printf -- '  ----------------------------------------------------------------\n'; "$@" 2>&1 | sed 's/^/  /'; }
raw()  { printf '\n  $ %s\n' "$1"; printf -- '  ----------------------------------------------------------------\n'; eval "$1" 2>&1 | sed 's/^/  /'; }

hr
printf '  ZFS / DISCO - INFORME DE SALUD Y CUELLOS DE BOTELLA\n'
printf '  %s   host=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(hostname)"
hr

# -----------------------------------------------------------------------------
# 0. Pools a analizar y sus vdevs de datos.
# -----------------------------------------------------------------------------
section "0. Pools detectados"
why "punto de partida: que pools no-boot existen y que discos los respaldan."
raw "zpool list -H -o name,size,health"

mapfile -t POOLS < <(zpool list -H -o name 2>/dev/null | grep -v '^boot-pool$')
if [[ -n "$POOL_FILTER" ]]; then POOLS=("$POOL_FILTER"); fi
if (( ${#POOLS[@]} == 0 )); then
    printf '\n  Sin pools de datos (solo boot-pool, o ninguno). Nada que analizar.\n'
    exit 0
fi
printf '\n  Pools a analizar: %s\n' "${POOLS[*]}"

# Leaf block devices for each pool (best-effort: parses `zpool status -PL`,
# then resolves each leaf to its PARENT whole disk via `lsblk -no pkname` --
# a partition like /dev/sdb1 has to become "sdb" for smartctl/sysfs lookups
# to work; a device that already IS a whole disk has no parent, and keeps
# its own name).
declare -A POOL_DEVS
for p in "${POOLS[@]}"; do
    resolved=""
    while IFS= read -r full; do
        [[ -n "$full" ]] || continue
        short="${full#/dev/}"
        parent="$(lsblk -no pkname "/dev/$short" 2>/dev/null | head -1)"
        resolved+=" ${parent:-$short}"
    done < <(zpool status -PL "$p" 2>/dev/null | awk '/\/dev\// {print $1}')
    POOL_DEVS["$p"]="$resolved"
done

# -----------------------------------------------------------------------------
# 1. Identificacion de cada disco: transporte, modelo, virtualizacion del host.
# -----------------------------------------------------------------------------
section "1. Identificacion de discos y contexto de virtualizacion"
why "un 'disco USB' esconde varias capas (bridge USB-SATA, controlador del \
host, y a veces una capa de virtualizacion) - cada una es un punto de falla \
o de cuello de botella distinto. Hay que saber cuales aplican antes de medir."
run lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,ROTA
raw "systemd-detect-virt || echo 'no detectado / bare metal'"
raw "dmesg | grep -iE 'hypervisor detected|dmi:.*qemu|dmi:.*vmware|dmi:.*virtualbox' | head -5"

# -----------------------------------------------------------------------------
# 2. SMART, probando cada variante de bridge conocida.
# -----------------------------------------------------------------------------
section "2. SMART por disco"
why "SMART es la senal estandar de salud de un disco mecanico (sectores \
reasignados, horas de uso, temperatura, errores acumulados). Muchos \
enclosures USB necesitan indicarle a smartctl el tipo de bridge para \
pasarlo; se prueban todas las variantes conocidas antes de darlo por \
no disponible."
have_smartctl=0; command -v smartctl >/dev/null 2>&1 && have_smartctl=1
if (( ! have_smartctl )); then
    printf '\n  smartctl no esta instalado en este host. Sin datos SMART posibles.\n'
else
    for p in "${POOLS[@]}"; do
        for d in ${POOL_DEVS[$p]:-}; do
            dev="/dev/$d"
            [[ -b "$dev" ]] || continue
            printf '\n  --- %s (pool %s) ---\n' "$dev" "$p"
            ok=0
            for variant in "" "-d sat" "-d sat,12" "-d sat,16" "-d usbjmicron" "-d usbsunplus" "-d usbprolific" "-d scsi"; do
                out="$(smartctl -a $variant "$dev" 2>&1)"
                if [[ "$out" =~ SMART\ support\ is:[[:space:]]*(Enabled|Available) || "$out" == *'Health Status:'* ]]; then
                    printf '\n  $ smartctl -a %s %s   <- funciono\n' "$variant" "$dev"
                    printf '%s\n' "$out" | sed 's/^/  /'
                    ok=1; break
                fi
            done
            if (( ! ok )); then
                printf '\n  Ninguna variante devolvio datos SMART utilizables. Ultimo intento (-d scsi):\n'
                smartctl -a -d scsi "$dev" 2>&1 | sed 's/^/  /'
            fi
        done
    done
fi

# -----------------------------------------------------------------------------
# 3. Topologia y velocidad de enlace USB.
# -----------------------------------------------------------------------------
section "3. Topologia y velocidad de enlace USB"
why "un disco USB 3.0 negociando a velocidad USB 2.0 (cable, hub o puerto \
defectuoso) es una causa comun y silenciosa de bajo rendimiento que se \
atribuye por error al disco o a ZFS."
run lsusb
printf '\n  Velocidad negociada por dispositivo (Mbps):\n'
while IFS= read -r d; do
    spd="$(cat "$d/speed" 2>/dev/null)" || continue
    [[ -n "$spd" ]] && printf '    %s: %s\n' "$d" "$spd"
done < <(find /sys/bus/usb/devices -maxdepth 1 -mindepth 1 -type d)

# -----------------------------------------------------------------------------
# 4. Historial de resets/desconexiones USB.
# -----------------------------------------------------------------------------
section "4. Historial de eventos USB (resets, desconexiones)"
why "un disco USB que se cae del bus bajo carga es uno de los problemas mas \
comunes y peligrosos de este tipo de setup - suele aparecer como I/O errors \
intermitentes sin aviso previo."
raw "uptime"
raw "dmesg | grep -iE 'usb.*(reset|disconnect)|i/o error' | grep -viE 'kvm-clock|systemd|bluetooth' | tail -40"

# -----------------------------------------------------------------------------
# 5. Driver de bloque y gestion de energia.
# -----------------------------------------------------------------------------
section "5. Driver de bloque y gestion de energia (por disco)"
why "UAS es mas rapido que usb-storage bulk-only pero mas sensible a \
firmwares de bridge defectuosos. El autosuspend de USB puede introducir \
latencia de 'despertar' el disco justo cuando hace falta escribir."
for p in "${POOLS[@]}"; do
    for d in ${POOL_DEVS[$p]:-}; do
        usbdev="$(readlink -f "/sys/class/block/$d/device" 2>/dev/null)"
        # Walk up to find a USB interface node with power/ and driver/.
        node="$usbdev"
        found=""
        for _ in 1 2 3 4 5 6; do
            [[ -z "$node" || "$node" == "/" ]] && break
            if [[ -e "$node/power/control" ]]; then found="$node"; break; fi
            node="$(dirname "$node")"
        done
        printf '\n  --- %s (pool %s) ---\n' "$d" "$p"
        if [[ -n "$found" ]]; then
            printf '  driver: %s\n' "$(readlink -f "$found/driver" 2>/dev/null || echo '?')"
            printf '  power/control: %s   autosuspend_delay_ms: %s\n' \
                "$(cat "$found/power/control" 2>/dev/null || echo '?')" \
                "$(cat "$found/power/autosuspend_delay_ms" 2>/dev/null || echo 'n/a')"
        else
            printf '  no es un dispositivo USB (SATA/NVMe/virtio directo), o no se pudo resolver la ruta sysfs.\n'
        fi
    done
done

# -----------------------------------------------------------------------------
# 6. Cola de bloque por disco.
# -----------------------------------------------------------------------------
section "6. Cola de bloque (scheduler, profundidad, tipo)"
why "el scheduler de I/O por defecto no siempre es el ideal para un disco \
mecanico bajo carga secuencial sostenida como la de un reescritor de \
archivos grandes."
for p in "${POOLS[@]}"; do
    for d in ${POOL_DEVS[$p]:-}; do
        [[ -d "/sys/block/$d/queue" ]] || continue
        printf '\n  --- %s (pool %s) ---\n' "$d" "$p"
        printf '  scheduler: %s\n' "$(cat "/sys/block/$d/queue/scheduler" 2>/dev/null)"
        printf '  nr_requests: %s   rotational: %s\n' \
            "$(cat "/sys/block/$d/queue/nr_requests" 2>/dev/null)" \
            "$(cat "/sys/block/$d/queue/rotational" 2>/dev/null)"
    done
done

# -----------------------------------------------------------------------------
# 7. Propiedades y salud del pool ZFS.
# -----------------------------------------------------------------------------
section "7. Propiedades y salud de cada pool ZFS"
why "mas alla del disco fisico, ZFS mismo reporta fragmentacion, ashift, \
uso de log/cache separados, y errores acumulados a nivel de pool."
for p in "${POOLS[@]}"; do
    printf '\n  === %s ===\n' "$p"
    run zpool status "$p"
    raw "zpool get ashift,fragmentation,capacity,autotrim,health,size,free,allocated '$p' | grep -v '^NAME'"
done

# -----------------------------------------------------------------------------
# 8. Eventos ZFS de error/checksum/degradacion.
# -----------------------------------------------------------------------------
section "8. Historial de eventos ZFS (errores, checksum, degradacion)"
why "mas granular que el contador acumulado de zpool status: cada evento \
individual desde el ultimo import del pool."
for p in "${POOLS[@]}"; do
    printf '\n  === %s ===\n' "$p"
    matches="$(zpool events -v "$p" 2>/dev/null | grep -iE 'class = .*(error|io_failure|checksum|degraded|vdev)')"
    if [[ -n "$matches" ]]; then
        printf '%s\n' "$matches" | sed 's/^/  /'
    else
        printf '  Sin eventos de error/checksum/degradacion en el historial registrado.\n'
    fi
done

# -----------------------------------------------------------------------------
# 9. Memoria, swap y ARC.
# -----------------------------------------------------------------------------
section "9. Memoria, swap y cache ARC de ZFS"
why "el ARC (cache de lectura de ZFS) vive en RAM y compite con todo lo \
demas del sistema. Memoria justa o swap activo es una causa tipica de \
degradacion de I/O que se confunde con un problema del disco."
run free -h
if [[ -r /proc/spl/kstat/zfs/arcstats ]]; then
    printf '\n  ARC (bytes, de /proc/spl/kstat/zfs/arcstats):\n'
    awk '$1=="size"||$1=="c"||$1=="c_max"||$1=="c_min"||$1=="hits"||$1=="misses"||$1=="arc_meta_used" {printf "    %-16s %s\n",$1,$3}' \
        /proc/spl/kstat/zfs/arcstats | sed 's/^/  /'
    h="$(awk '$1=="hits"{print $3}' /proc/spl/kstat/zfs/arcstats)"
    m="$(awk '$1=="misses"{print $3}' /proc/spl/kstat/zfs/arcstats)"
    if [[ "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ && $((h+m)) -gt 0 ]]; then
        printf '  ARC hit ratio (acumulado desde el boot): %s%%\n' "$(( h*100/(h+m) ))"
    fi
else
    printf '\n  /proc/spl/kstat/zfs/arcstats no disponible.\n'
fi
command -v arc_summary >/dev/null 2>&1 && run arc_summary -p 1

# -----------------------------------------------------------------------------
# 10. CPU y load.
# -----------------------------------------------------------------------------
section "10. CPU y load promedio"
why "un cuello de botella de CPU (hash, compresion) se confunde facil con \
uno de disco si no se mira por separado."
raw "nproc"
run uptime
raw "grep -m1 'model name' /proc/cpuinfo"

# -----------------------------------------------------------------------------
# 11. Muestras en vivo: iostat y zpool iostat.
# -----------------------------------------------------------------------------
section "11. Muestras en vivo de I/O ($SAMPLES x ${INTERVAL}s)"
why "todo lo anterior es estatico. El throughput y la latencia real, \
muestreados varias veces, son lo que de verdad dice si hay un cuello de \
botella ahora mismo (por ejemplo, mientras el worker esta corriendo)."
devlist=""
for p in "${POOLS[@]}"; do devlist+=" ${POOL_DEVS[$p]:-}"; done
if command -v iostat >/dev/null 2>&1 && [[ -n "${devlist// }" ]]; then
    run iostat -x $devlist "$INTERVAL" "$SAMPLES"
fi
for p in "${POOLS[@]}"; do
    printf '\n  === zpool iostat -v %s ===\n' "$p"
    zpool iostat -v "$p" "$INTERVAL" "$SAMPLES" 2>&1 | sed 's/^/  /'
    printf '\n  === zpool iostat -vl %s (desglose de latencia) ===\n' "$p"
    zpool iostat -vl "$p" 1 1 2>&1 | sed 's/^/  /'
done

hr
printf '  Fin del informe. Guardado en: %s\n' "$OUT"
hr
