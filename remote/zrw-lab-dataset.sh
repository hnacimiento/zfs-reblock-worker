#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# zrw-lab-dataset.sh - create/destroy a disposable ZFS dataset for cases that
# docs/TEST-PLAN.md cannot verify inside an existing production dataset:
#   - ACL POSIX no trivial (needs acltype=posix; the real pool's only posix
#     datasets are toolbox/.ix-virt/* system datasets, not safe to touch)
#   - atime preservation (needs atime=on; the real dataset has atime=off)
#
# This is a deliberate, operator-run tool. It NEVER runs on its own, and it
# never touches an existing dataset -- it only creates a brand new child
# dataset under the parent you name, and can only destroy a dataset whose
# name it recognizes as one it (or a previous run of it) created.
#
# Usage:
#   zrw-lab-dataset.sh create  [--parent POOL[/PATH]] [--name NAME]
#                               [--acltype posix|nfsv4] [--atime on|off]
#                               [--recordsize SIZE]
#   zrw-lab-dataset.sh destroy [--parent POOL[/PATH]] [--name NAME] [--yes]
#   zrw-lab-dataset.sh status  [--parent POOL[/PATH]] [--name NAME]
#
# Defaults: --name zrw-lab, --acltype posix, --atime on, --recordsize 1M.
# --parent has no default on purpose: name the pool you mean, every time.
#
# Example, to close the two open TEST-PLAN.md items:
#   ./zrw-lab-dataset.sh create --parent toolbox --acltype posix --atime on
#   setfacl -m u:truenas_admin:rwx /mnt/toolbox/zrw-lab/algo.bin   # ACL no trivial
#   ...run the worker against /mnt/toolbox/zrw-lab, compare before/after...
#   ./zrw-lab-dataset.sh destroy --parent toolbox --yes
# -----------------------------------------------------------------------------
set -euo pipefail

PARENT="" NAME="zrw-lab" ACLTYPE="posix" ATIME="on" RECORDSIZE="1M" ASSUME_YES=0
ACTION="${1:-}"; shift || true

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --parent)     PARENT="$2"; shift 2 ;;
        --name)       NAME="$2"; shift 2 ;;
        --acltype)    ACLTYPE="$2"; shift 2 ;;
        --atime)      ATIME="$2"; shift 2 ;;
        --recordsize) RECORDSIZE="$2"; shift 2 ;;
        --yes)        ASSUME_YES=1; shift ;;
        *)            die "opcion desconocida: $1" ;;
    esac
done

[[ "$(id -u)" == 0 ]] || die "correr como root (necesita 'zfs create'/'zfs destroy')."
[[ -n "$PARENT" ]] || die "falta --parent POOL[/PATH] (ej: --parent toolbox). No hay default a proposito: nombra el pool siempre, para no crear en el lugar equivocado."
have() { command -v -- "$1" >/dev/null 2>&1; }
have zfs || die "zfs no esta en el PATH."

# Safety net for destroy: only ever touch a dataset whose leaf name looks like
# ours. This does not depend on --name matching what the operator typed for
# create; it is a hard floor so a typo in --parent can never reach something
# that was never a lab dataset to begin with.
case "$NAME" in
    zrw-lab*) : ;;
    *) die "--name debe empezar con 'zrw-lab' (es la unica garantia de que 'destroy' nunca toque otra cosa). Recibido: $NAME" ;;
esac

DS="$PARENT/$NAME"

case "$ACTION" in
    create)
        zfs list -H -o name "$DS" >/dev/null 2>&1 \
            && die "$DS ya existe. Corre 'destroy' primero si queres recrearlo."
        case "$ACLTYPE" in posix|nfsv4) ;; *) die "--acltype debe ser posix|nfsv4" ;; esac
        case "$ATIME"   in on|off)      ;; *) die "--atime debe ser on|off" ;; esac
        echo "Creando $DS  (acltype=$ACLTYPE atime=$ATIME recordsize=$RECORDSIZE)"
        zfs create -o acltype="$ACLTYPE" -o atime="$ATIME" -o recordsize="$RECORDSIZE" -- "$DS"
        MP="$(zfs list -H -o mountpoint -- "$DS")"
        echo "Listo: $DS  ->  $MP"
        echo "Destruilo cuando termines:  $0 destroy --parent '$PARENT' --name '$NAME' --yes"
        ;;
    destroy)
        zfs list -H -o name "$DS" >/dev/null 2>&1 \
            || die "$DS no existe (nada que destruir)."
        if (( ! ASSUME_YES )); then
            read -r -p "Esto DESTRUYE $DS y todo su contenido, sin vuelta atras. Escribi el nombre exacto para confirmar: " confirm
            [[ "$confirm" == "$DS" ]] || die "confirmacion no coincide, no se destruyo nada."
        fi
        echo "Destruyendo $DS"
        zfs destroy -r -- "$DS"
        echo "Listo: $DS ya no existe."
        ;;
    status|"")
        if zfs list -H -o name,mountpoint,acltype,atime,recordsize -- "$DS" 2>/dev/null; then
            :
        else
            echo "$DS no existe."
        fi
        ;;
    *)
        die "accion desconocida: '$ACTION' (create|destroy|status)"
        ;;
esac
