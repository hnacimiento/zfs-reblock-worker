#!/usr/bin/env bash
# =============================================================================
# zrw-env.sh - one-page picture of the host the worker is about to run on.
#
# Strictly read-only. Runs on the NAS, takes the target directory as its only
# argument, and answers the three questions that decide whether the worker can
# do its job there at all:
#
#   1. is the platform the one we expect (bash, rsync, zfs versions)
#   2. is the tool present for each dataset's acltype -- without it that
#      dataset cannot be verified, so it will not be processed
#   3. what recordsize, acltype, compression and xattr do the datasets around
#      the target actually have
#
# This used to be a one-liner embedded in zrw-remote.sh. It needed three levels
# of quote escaping to survive the trip through ssh, and the awk filter it
# carried was wrong in a way nobody could see: it matched only datasets mounted
# UNDER the target, while the common case is the opposite -- the target is a
# plain subdirectory of the dataset that contains it.
# =============================================================================
set -uo pipefail

TARGET="${1:-/}"

sec() { printf '\n--- %s %s\n' "$1" "$(printf '%.0s-' $(seq 1 $((60 - ${#1}))))"; }

sec "plataforma"
uname -a
head -5 /etc/os-release 2>/dev/null
bash --version | head -1
rsync --version 2>/dev/null | head -1
zfs version 2>&1 | head -2

sec "herramientas de verificacion de ACL / xattr"
# Presence here is not cosmetic: the worker refuses to process a dataset whose
# acltype it cannot verify, so a missing tool is a dataset that stays untouched.
for c in nfs4xdr_getfacl nfs4_getfacl jq getfacl getfattr; do
    printf '  %-20s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo AUSENTE)"
done
printf '\n'
for c in b2sum sha256sum md5sum zdb flock tmux renice ionice; do
    printf '  %-20s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo AUSENTE)"
done

sec "datasets relacionados con $TARGET"
# Same relation the worker uses: a dataset matters if its mountpoint contains
# the target, or if it is mounted somewhere under it.
{
    printf 'DATASET\tMOUNTPOINT\tRECSIZE\tACLTYPE\tCOMPRESS\tXATTR\tRELACION\n'
    zfs list -H -o name,mountpoint,recordsize,acltype,compression,xattr 2>/dev/null |
    awk -F'\t' -v t="$TARGET" '
        $2 == "-" || $2 == "legacy" || $2 == "none" { next }
        $2 == t                { print $0 "\tcontiene el objetivo"; next }
        index(t, $2 "/") == 1  { print $0 "\tcontiene el objetivo"; next }
        index($2, t "/") == 1  { print $0 "\tcuelga del objetivo" }
    '
} | column -t -s "$(printf '\t')"

sec "espacio"
df -h "$TARGET" 2>/dev/null

sec "atime del dataset que contiene el objetivo"
# atime=on means reading a file changes its atime, which is precisely why the
# worker captures atime before any read instead of relying on touch -r.
DS="$(df -P "$TARGET" 2>/dev/null | awk 'NR==2 {print $1}')"
if [[ -n "${DS:-}" ]]; then
    printf '  dataset: %s\n' "$DS"
    zfs get -H -o property,value atime,relatime,recordsize,acltype,xattr,compression,sync "$DS" 2>/dev/null |
        sed 's/^/  /'
fi
printf '\n'
