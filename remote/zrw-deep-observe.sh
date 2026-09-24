#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# zrw-deep-observe.sh - read-only, /proc-based deep introspection of a running
# zfs-reblock-worker.sh process and its children, for the live-console
# protocol, see "Live Console Protocol" in the project wiki:
# https://github.com/hnacimiento/zfs-reblock-worker/wiki/Live-Console-Protocol
#
# Everything here reads from /proc (and /sys/fs/cgroup, and zpool/iostat as
# thin wrappers over kernel counters) -- no ptrace, no strace, nothing that
# can alter the target process's behavior or timing. Safe to run alongside a
# live job without disturbing it.
#
# Subcommands:
#   tree   <PID>            process tree rooted at PID, with nice/ionice/state
#   io     <PID>             per-process I/O counters (PID + all descendants)
#   fds    <PID>             open file descriptors, resolved, with fdinfo
#   mem    <PID>             RSS/PSS per process
#   cgroup <PID>              cgroup v2 io.stat/cpu.stat for PID's session scope
#   disk   [DEVICE]           iostat -x + zpool iostat, one sample
#   snapshot <PID>            tree + io + fds + mem + disk, one shot, timestamped
#   watch  <PID> [INTERVAL]   snapshot on a loop (default 5s) until Ctrl-C
# -----------------------------------------------------------------------------
set -uo pipefail

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
ts()  { date '+%Y-%m-%d %H:%M:%S.%N'; }
hr()  { printf -- '-%.0s' $(seq 1 78); printf '\n'; }

descendants() {
    # All PIDs in the tree rooted at $1, root included, depth-first.
    local root="$1" pid
    printf '%s\n' "$root"
    for pid in $(pgrep -P "$root" 2>/dev/null); do
        descendants "$pid"
    done
}

proc_line() {
    local pid="$1" cmd state nice pri rss ion
    [[ -r "/proc/$pid/stat" ]] || return 0
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    [[ -n "$cmd" ]] || cmd="[$(< "/proc/$pid/comm" 2>/dev/null)]"
    read -r state _ < <(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    nice="$(ps -o ni= -p "$pid" 2>/dev/null | tr -d ' ')"
    pri="$(ps -o pri= -p "$pid" 2>/dev/null | tr -d ' ')"
    rss="$(awk '/VmRSS/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null)"
    ion="$(ionice -p "$pid" 2>/dev/null)"
    printf '  pid=%-8s state=%-3s nice=%-4s pri=%-4s rss=%-12s ionice=%-20s cmd=%s\n' \
        "$pid" "${state:-?}" "${nice:-?}" "${pri:-?}" "${rss:-?}" "${ion:-?}" "$cmd"
}

cmd_tree() {
    local pid="${1:?PID requerido}"
    [[ -d "/proc/$pid" ]] || die "pid $pid no existe"
    hr; printf '[%s] ARBOL DE PROCESOS (pstree -p %s)\n' "$(ts)" "$pid"; hr
    pstree -p -a "$pid" 2>/dev/null || echo "  (pstree no disponible o pid ya termino)"
    echo
    echo "Detalle por proceso (estado/nice/prioridad real/RSS/clase de I/O):"
    local p; for p in $(descendants "$pid"); do proc_line "$p"; done
}

cmd_io() {
    local pid="${1:?PID requerido}" p
    hr; printf '[%s] I/O POR PROCESO (/proc/<pid>/io)\n' "$(ts)" ; hr
    printf '  %-8s %-14s %-14s %-14s %-14s %s\n' pid rchar wchar read_bytes write_bytes cmd
    for p in $(descendants "$pid"); do
        [[ -r "/proc/$p/io" ]] || continue
        local rchar wchar rb wb cmd
        rchar="$(awk '/^rchar:/{print $2}' "/proc/$p/io" 2>/dev/null)"
        wchar="$(awk '/^wchar:/{print $2}' "/proc/$p/io" 2>/dev/null)"
        rb="$(awk '/^read_bytes:/{print $2}' "/proc/$p/io" 2>/dev/null)"
        wb="$(awk '/^write_bytes:/{print $2}' "/proc/$p/io" 2>/dev/null)"
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-40)"
        printf '  %-8s %-14s %-14s %-14s %-14s %s\n' "$p" "${rchar:-0}" "${wchar:-0}" "${rb:-0}" "${wb:-0}" "$cmd"
    done
}

cmd_fds() {
    local pid="${1:?PID requerido}" p
    hr; printf '[%s] DESCRIPTORES DE ARCHIVO ABIERTOS\n' "$(ts)"; hr
    for p in $(descendants "$pid"); do
        [[ -d "/proc/$p/fd" ]] || continue
        local cmd; cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-50)"
        echo "pid=$p  cmd=$cmd"
        local fd target flags pos
        for fd in /proc/"$p"/fd/*; do
            [[ -e "$fd" ]] || continue
            target="$(readlink -- "$fd" 2>/dev/null)"
            [[ "$target" == "anon_inode:"* || "$target" == socket:* || "$target" == pipe:* ]] && continue
            flags="$(awk '/^flags:/{print $2}' "/proc/$p/fdinfo/$(basename "$fd")" 2>/dev/null)"
            pos="$(awk '/^pos:/{print $2}' "/proc/$p/fdinfo/$(basename "$fd")" 2>/dev/null)"
            printf '    fd=%-4s flags=%-8s pos=%-12s -> %s\n' "$(basename "$fd")" "${flags:-?}" "${pos:-?}" "$target"
        done
    done
}

cmd_mem() {
    local pid="${1:?PID requerido}" p
    hr; printf '[%s] MEMORIA POR PROCESO (VmRSS / Pss de smaps_rollup)\n' "$(ts)"; hr
    for p in $(descendants "$pid"); do
        [[ -r "/proc/$p/status" ]] || continue
        local rss pss cmd
        rss="$(awk '/VmRSS/{print $2" "$3}' "/proc/$p/status" 2>/dev/null)"
        pss="$(awk '/^Pss:/{print $2" "$3}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-40)"
        printf '  pid=%-8s rss=%-14s pss=%-14s cmd=%s\n' "$p" "${rss:-?}" "${pss:-N/A}" "$cmd"
    done
}

cmd_cgroup() {
    local pid="${1:?PID requerido}" cg dir
    hr; printf '[%s] CGROUP v2 (io.stat / cpu.stat de la sesion completa)\n' "$(ts)"; hr
    cg="$(awk -F: '{print $3}' "/proc/$pid/cgroup" 2>/dev/null | head -1)"
    [[ -n "$cg" ]] || { echo "  no se pudo resolver el cgroup de $pid"; return 0; }
    dir="/sys/fs/cgroup${cg}"
    echo "  cgroup: $cg"
    [[ -r "$dir/io.stat"  ]] && { echo "  io.stat:";  sed 's/^/    /' "$dir/io.stat";  }
    [[ -r "$dir/cpu.stat" ]] && { echo "  cpu.stat:"; sed 's/^/    /' "$dir/cpu.stat"; }
    [[ -r "$dir/memory.current" ]] && echo "  memory.current: $(cat "$dir/memory.current")"
}

cmd_disk() {
    local dev="${1:-}"
    hr; printf '[%s] DISCO REAL (iostat -x, una muestra) y ZPOOL IOSTAT\n' "$(ts)"; hr
    if command -v iostat >/dev/null 2>&1; then
        iostat -x ${dev:+"$dev"} 1 2 2>/dev/null | tail -n +$(( $(iostat -x ${dev:+"$dev"} 1 2 2>/dev/null | wc -l) / 2 + 1 ))
    else
        echo "  iostat no disponible"
    fi
    echo
    zpool iostat -v toolbox 1 1 2>/dev/null || echo "  zpool iostat no disponible"
}

cmd_snapshot() {
    local pid="${1:?PID requerido}"
    cmd_tree "$pid"
    cmd_io "$pid"
    cmd_fds "$pid"
    cmd_mem "$pid"
    cmd_cgroup "$pid"
    cmd_disk
}

cmd_watch() {
    local pid="${1:?PID requerido}" interval="${2:-5}"
    trap 'echo; echo "(watch detenido)"; exit 0' INT TERM
    while [[ -d "/proc/$pid" ]]; do
        cmd_snapshot "$pid"
        echo
        sleep "$interval"
    done
    echo "pid $pid ya no existe, watch termina."
}

case "${1:-}" in
    tree)     shift; cmd_tree "$@" ;;
    io)       shift; cmd_io "$@" ;;
    fds)      shift; cmd_fds "$@" ;;
    mem)      shift; cmd_mem "$@" ;;
    cgroup)   shift; cmd_cgroup "$@" ;;
    disk)     shift; cmd_disk "$@" ;;
    snapshot) shift; cmd_snapshot "$@" ;;
    watch)    shift; cmd_watch "$@" ;;
    *) die "uso: $0 tree|io|fds|mem|cgroup|disk|snapshot|watch <PID> [...]" ;;
esac
