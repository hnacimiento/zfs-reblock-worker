#!/usr/bin/env bash
# End-to-end bench for the state machine, WITHOUT touching ZFS.
#
# Builds its own temporary tree, replaces `zfs` and `zdb` with stubs on PATH and
# runs the full worker against laboratory files. Exercises the real cycle:
# inventory, copy, SHA-256, timestamps, commit, rollback anchor, resume, STALE,
# hardlinks, orphan temps, lock, parallel workers and exit codes.
#
# This does NOT replace docs/TEST-PLAN.md on the real TrueNAS: ZFS is simulated,
# so it proves nothing about zdb, real ACLs or transaction-group durability.
#
# Requires Linux with: rsync, flock, sha256sum, stat, touch, find, ln.
set -u
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
W="$DIR/../zfs-reblock-worker.sh"
fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
eq()   { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (esperado [$2], obtenido [$3])"; fi; }

for c in rsync flock sha256sum stat touch find ln df; do
    command -v "$c" >/dev/null 2>&1 || { printf 'SKIP: falta %s; este banco requiere Linux.\n' "$c"; exit 0; }
done

# This bench replaces `zfs`/`zdb`/etc. with executable stub scripts on PATH, so
# the directory they live in has to allow exec(). The plain system /tmp is not
# a safe default: on a hardened host it can be mounted `noexec` (confirmed on
# the project's reference TrueNAS -- tmpfs, rw,nosuid,nodev,noexec). There the
# stubs silently fail to run, bash's PATH search falls through to the REAL
# zfs/zdb with no error message, and every scenario in this file fails with
# EX_NOT_ZFS because the real system does not know about the lab's fake paths.
# No test data is at risk either way (the fallback still can't see real ZFS
# datasets under the lab's fake mountpoints), but the whole suite goes red for
# a reason that has nothing to do with the worker. Probe for a working spot
# instead of assuming: ZRW_TEST_LAB_DIR wins if set, then plain mktemp -d, then
# next to this script -- which is guaranteed exec-capable, since the worker
# binary itself runs from there.
pick_lab_parent() {
    local d canary sys_tmp
    sys_tmp="$(mktemp -d 2>/dev/null)"
    for d in "${ZRW_TEST_LAB_DIR:-}" "$sys_tmp" "$DIR"; do
        [[ -n "$d" && -d "$d" ]] || continue
        canary="$d/.zrw-exec-probe.$$"
        printf '#!/usr/bin/env bash\nexit 0\n' >"$canary" 2>/dev/null || continue
        chmod +x "$canary" 2>/dev/null
        if "$canary" 2>/dev/null; then
            rm -f -- "$canary"
            [[ "$d" != "$sys_tmp" ]] && rm -rf -- "$sys_tmp" 2>/dev/null
            printf '%s' "$d"; return 0
        fi
        rm -f -- "$canary"
    done
    rm -rf -- "$sys_tmp" 2>/dev/null
    return 1
}
LAB_PARENT="$(pick_lab_parent)" || { printf 'SKIP: no encontre un directorio donde ejecutar scripts (todos noexec o no escribibles).\n'; exit 0; }
LAB="$(mktemp -d -p "$LAB_PARENT")"; trap 'rm -rf -- "$LAB"' EXIT
DATA="$LAB/pool/data"; mkdir -p "$DATA" "$LAB/bin" "$LAB/jobs"

cat >"$LAB/bin/zfs" <<STUB
#!/usr/bin/env bash
RS="\$(cat "$LAB/recordsize" 2>/dev/null || echo 1M)"
case "\$1" in
  version) echo "zfs-stub-1" ;;
  list)
    # Emulates both shapes the worker asks for.
    ACL="\$(cat "$LAB/acltype" 2>/dev/null || echo posix)"
    ACL_OTRO="\$(cat "$LAB/acltype_otro" 2>/dev/null || echo nfsv4)"
    if printf '%s ' "\$@" | grep -q 'mountpoint,name,recordsize'; then
      # Four columns: the worker reads acltype from the same query, because it
      # is a dataset property and asking once here replaces a zfs get per file.
      printf '%s\tpool/data\t%s\t%s\n'    "$LAB/pool/data" "\$RS" "\$ACL"
      printf '%s\tpool/otro\t128K\t%s\n'  "$LAB/pool/data/otro" "\$ACL_OTRO"
      cat "$LAB/extra_ds" 2>/dev/null
    else
      printf 'pool/data\t%s\n' "$LAB/pool/data"
      printf 'pool/otro\t%s\n' "$LAB/pool/data/otro"
      awk -F'\t' '{ print \$2 "\t" \$1 }' "$LAB/extra_ds" 2>/dev/null
    fi ;;
  get)  echo "\$RS" ;;
  *) exit 0 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$LAB/bin/zdb"

# ACL / xattr stubs.
#
# The lab runs on ext4 or tmpfs, where these tools are often not installed at
# all, and where there are no NFSv4 ACLs to read even when they are. What the
# suite has to prove is that the worker resolves a verifier and that the
# verifier is actually consulted -- not that ext4 stores ACLs.
#
# So both stubs derive their answer from something the rewrite genuinely has to
# preserve (mode, uid, gid). A copy that lost permissions makes them differ and
# the comparison fails, exactly as a real getfacl would.
cat >"$LAB/bin/getfacl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -*) ;; *) f="$a" ;; esac; done
[[ -e "${f:-}" ]] || exit 1
stat -c 'mode=%a owner=%u group=%g' -- "$f"
STUB
cat >"$LAB/bin/getfattr" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -*) ;; *) f="$a" ;; esac; done
[[ -e "${f:-}" ]] || exit 1
printf '# file: %s\nuser.zrw.lab="%s"\n' "${f##*/}" "$(stat -c '%a' -- "$f")"
STUB
chmod +x "$LAB/bin/zfs" "$LAB/bin/zdb" "$LAB/bin/getfacl" "$LAB/bin/getfattr"
echo 1M >"$LAB/recordsize"
echo posix >"$LAB/acltype"
: >"$LAB/extra_ds"
export PATH="$LAB/bin:$PATH" ZRW_STATE_ROOT="$LAB/jobs" ZRW_TEST_MODE=1

run() { "$W" "$@" </dev/null 2>&1; }
RC=0
run_rc() { "$W" "$@" </dev/null >"$LAB/out" 2>&1; RC=$?; cat "$LAB/out"; }

mk() { head -c "$2" /dev/urandom >"$DATA/$1"; }
mk normal.bin 200000; mk otro.bin 150000; mk "con espacios.bin" 120000
mk chico.bin 500                      # below the threshold: must not be picked
mk hard-origen.bin 130000; ln "$DATA/hard-origen.bin" "$DATA/hard-enlace.bin"

declare -A SHA0 MT0 INO0
for f in "$DATA"/*.bin; do
    SHA0["$f"]="$(sha256sum -- "$f" | awk '{print $1}')"
    MT0["$f"]="$(stat -c '%y' -- "$f")"; INO0["$f"]="$(stat -c '%i' -- "$f")"
done

printf 'ZFS Reblock Worker - integration (ZFS simulado)\n'
COMMON=(--threshold 1K --cooldown 0 --adaptive off --health-interval 1 --integrity maximum)

# --- 1. dry-run modifies nothing --------------------------------------------
out="$(run "$DATA" "${COMMON[@]}" --dry-run)"
[[ -z "$(ls -A "$ZRW_STATE_ROOT" 2>/dev/null)" ]] && pass "dry-run no crea job ni estado" || fail "dry-run creo un job"
ch=0; for f in "${!SHA0[@]}"; do [[ "$(sha256sum -- "$f"|awk '{print $1}')" == "${SHA0[$f]}" ]] || ch=1; done
(( ch )) && fail "dry-run modifico archivos" || pass "dry-run no modifica archivos"
grep -q 'chico.bin' <<<"$out" && fail "dry-run incluyo un archivo bajo el umbral" || pass "el umbral excluye los chicos"
out2="$(run "$DATA" "${COMMON[@]}" --dry-run --estimate)"
grep -q 'ESTIMACION' <<<"$out2" && pass "dry-run --estimate compara varios BW" || fail "dry-run sin comparativa"

# --- 2. dry-run unattended / machine-readable -------------------------------
out="$(run "$DATA" "${COMMON[@]}" --dry-run --ui json)"
grep -q '"mode":"dry-run"' <<<"$out" && pass "dry-run --ui json emite JSON" || fail "dry-run json invalido"
grep -q '"recordsize_match":true' <<<"$out" && pass "el JSON reporta el match de recordsize" || fail "falta recordsize_match"
out="$(run "$DATA" "${COMMON[@]}" --dry-run --quiet)"
[[ "$(grep -c 'DRY-RUN' <<<"$out")" -le 2 ]] && pass "dry-run --quiet no lista archivo por archivo" || fail "--quiet demasiado verboso"
out="$(run "$DATA" "${COMMON[@]}" --dry-run --dry-sample 2)"
grep -qi 'lectura real medida' <<<"$out" && pass "dry-sample mide throughput real de lectura" || fail "dry-sample no midio"

# --- 3. full run -------------------------------------------------------------
run_rc "$DATA" "${COMMON[@]}" >/dev/null
eq "exit code 0 en una corrida limpia" "0" "$RC"
JOB="$(ls -1 "$ZRW_STATE_ROOT" | grep '^ZRW-' | head -n1)"
[[ -n "$JOB" ]] && pass "se creo el job $JOB" || fail "no se creo job"

bad=0; for f in "${!SHA0[@]}"; do
    [[ -f "$f" ]] || { bad=$((bad+1)); continue; }
    [[ "$(sha256sum -- "$f"|awk '{print $1}')" == "${SHA0[$f]}" ]] || bad=$((bad+1)); done
eq "contenido identico en todos los archivos" "0" "$bad"
bad=0; for f in "${!MT0[@]}"; do [[ "$(stat -c '%y' -- "$f")" == "${MT0[$f]}" ]] || bad=$((bad+1)); done
eq "mtime preservado en todos los archivos" "0" "$bad"
[[ "$(stat -c '%i' -- "$DATA/normal.bin")" != "${INO0[$DATA/normal.bin]}" ]] \
    && pass "normal.bin fue reescrito (cambio el inode)" || fail "normal.bin no fue reescrito"
[[ "$(stat -c '%i' -- "$DATA/hard-origen.bin")" == "${INO0[$DATA/hard-origen.bin]}" ]] \
    && pass "el hardlink no fue reescrito" || fail "se reescribio un hardlink"
eq "el hardlink sigue enlazado" "2" "$(stat -c '%h' -- "$DATA/hard-origen.bin")"
eq "no quedan temporales" "0" "$(find "$DATA" -name '.zrw-*.tmp' | wc -l)"
eq "no quedan anclas de rollback" "0" "$(find "$DATA" -name '.zrw-*.rollback' | wc -l)"
eq "el registro de anclas quedo vacio" "0" "$(find "$ZRW_STATE_ROOT/$JOB/anchors" -type f | wc -l)"
[[ -s "$ZRW_STATE_ROOT/$JOB/summary.json" ]] && pass "se escribio summary.json" || fail "falta summary.json"
[[ -s "$ZRW_STATE_ROOT/$JOB/journal.tsv" ]] && pass "se escribio el journal" || fail "falta journal.tsv"
grep -q 'bytes_planned' "$ZRW_STATE_ROOT/$JOB/summary.tsv" && pass "el resumen incluye progreso por bytes" || fail "falta bytes_planned"

# --- 4. resume does not redo work -------------------------------------------
declare -A INO1; for f in "$DATA"/*.bin; do INO1["$f"]="$(stat -c '%i' -- "$f")"; done
out="$(run --job "$JOB" --resume "${COMMON[@]}")"
bad=0; for f in "${!INO1[@]}"; do [[ "$(stat -c '%i' -- "$f")" == "${INO1[$f]}" ]] || bad=$((bad+1)); done
eq "el resume no reescribe nada" "0" "$bad"

# --- 5. the checkpoint is not the authority ---------------------------------
head -c 210000 /dev/urandom >"$DATA/normal.bin"
out="$(run --job "$JOB" --resume "${COMMON[@]}")"
grep -q 'RECOVERY' <<<"$out" && pass "un DONE que ya no coincide se reevalua" || fail "confio ciegamente en el estado DONE"

# --- 6. orphan temps ---------------------------------------------------------
touch "$DATA/.zrw-deadbeef99-1122334455667788.tmp"
out="$(run --job "$JOB" --resume "${COMMON[@]}")"
find "$DATA" -name '.zrw-deadbeef99-*.tmp' | grep -q . \
    && pass "un temporal de OTRO job no se toca" || fail "se movio un temporal ajeno"
rm -f "$DATA"/.zrw-deadbeef99-*.tmp
SHORT="$(printf '%s' "$JOB" | sha256sum | cut -c1-10)"
touch "$DATA/.zrw-${SHORT}-aabbccddeeff0011.tmp"
out="$(run --job "$JOB" --resume "${COMMON[@]}")"
find "$ZRW_STATE_ROOT/$JOB/quarantine" -name '.zrw-*' 2>/dev/null | grep -q . \
    && pass "el temporal propio huerfano va a cuarentena" || fail "no fue puesto en cuarentena"

# --- 7. orphan rollback anchor: must not leave the file unprocessable -------
# Simulates a crash after linking the anchor but before the commit.
mk anclado.bin 140000
SHA_ANC="$(sha256sum -- "$DATA/anclado.bin" | awk '{print $1}')"
TOK="$(printf '%s' "$DATA/anclado.bin" | sha256sum | cut -c1-16)"
ln "$DATA/anclado.bin" "$DATA/.zrw-${SHORT}-${TOK}.rollback"
printf '%q\n' "$DATA/anclado.bin" >"$ZRW_STATE_ROOT/$JOB/anchors/$TOK"
eq "nlink tras el corte simulado" "2" "$(stat -c '%h' -- "$DATA/anclado.bin")"
out="$(run --job "$JOB" --resume --refresh-inventory "${COMMON[@]}")"
eq "el ancla huerfana fue limpiada" "0" "$(find "$DATA" -name '*.rollback' | wc -l)"
eq "el archivo volvio a nlink=1 y es procesable" "1" "$(stat -c '%h' -- "$DATA/anclado.bin")"
eq "el contenido del archivo anclado esta intacto" "$SHA_ANC" "$(sha256sum -- "$DATA/anclado.bin" | awk '{print $1}')"
grep -q 'Ancla huerfana' <<<"$out" && pass "la recuperacion reporta el ancla huerfana" || fail "no reporto el ancla"

# --- 8. lock ------------------------------------------------------------------
( exec 200>"$ZRW_STATE_ROOT/$JOB/job.lock"; flock 200
  "$W" --job "$JOB" --resume "${COMMON[@]}" </dev/null >"$LAB/o2" 2>&1; rc=$?
  grep -q 'ya esta en ejecucion' "$LAB/o2" && pass "el lock impide dos workers" || fail "el lock no impidio"
  [[ "$rc" == 11 ]] && pass "exit code 11 con el job bloqueado" || fail "exit code inesperado con lock: $rc" ) || true

# --- 9. parallel workers ------------------------------------------------------
rm -rf "$ZRW_STATE_ROOT"/ZRW-*
for i in 1 2 3 4 5 6; do mk "par$i.bin" 90000; done
declare -A SHAP; for f in "$DATA"/par*.bin; do SHAP["$f"]="$(sha256sum -- "$f"|awk '{print $1}')"; done
run_rc "$DATA" "${COMMON[@]}" --workers 3 >/dev/null
eq "exit code 0 con workers en paralelo" "0" "$RC"
bad=0; for f in "${!SHAP[@]}"; do [[ "$(sha256sum -- "$f"|awk '{print $1}')" == "${SHAP[$f]}" ]] || bad=$((bad+1)); done
eq "paralelo: contenido intacto" "0" "$bad"
eq "paralelo: sin temporales residuales" "0" "$(find "$DATA" -name '.zrw-*' | wc -l)"
JOB2="$(ls -1 "$ZRW_STATE_ROOT" | grep '^ZRW-' | head -n1)"
dup="$(grep -h '^status=DONE' "$ZRW_STATE_ROOT/$JOB2"/state/*.state 2>/dev/null | wc -l)"
[[ "$dup" -ge 6 ]] && pass "paralelo: todos los candidatos quedaron DONE" || fail "paralelo: solo $dup DONE"

# --- 10. recordsize mismatch --------------------------------------------------
echo 128K >"$LAB/recordsize"
run_rc "$DATA" "${COMMON[@]}" --new-job >/dev/null
eq "exit code 23 con recordsize distinto" "23" "$RC"
grep -q 'zfs set recordsize' "$LAB/out" && pass "sugiere el comando pero no lo ejecuta" || fail "no explico como corregirlo"
echo 1M >"$LAB/recordsize"

# --- 11. --check and --explain ------------------------------------------------
run_rc --check >/dev/null; eq "exit code 0 en --check" "0" "$RC"
out="$(run --explain "$DATA/otro.bin" --threshold 1K)"
grep -q 'ancla de rollback' <<<"$out" && pass "--explain menciona el ancla de rollback" || fail "--explain incompleto"

# --- 12. --status --json ------------------------------------------------------
out="$(run --status --json)"
grep -q '"jobs":\[' <<<"$out" && pass "--status --json emite JSON" || fail "--status --json invalido"

# --- 13. a tree spanning several datasets -----------------------------------
# pool/otro has recordsize 128K, so its files must be excluded from the job
# instead of being rewritten against the wrong target.
mkdir -p "$DATA/otro"
mk "otro/ajeno.bin" 110000
SHA_AJENO="$(sha256sum -- "$DATA/otro/ajeno.bin" | awk '{print $1}')"
INO_AJENO="$(stat -c '%i' -- "$DATA/otro/ajeno.bin")"
out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run)"
grep -q 'el arbol abarca 2 datasets' <<<"$out" && pass "el dry-run detecta varios datasets" || fail "no detecto el segundo dataset"
grep -q 'ajeno.bin' <<<"$out" && fail "un archivo de otro dataset entro al inventario" || pass "el archivo de otro dataset queda fuera"
rm -rf "$ZRW_STATE_ROOT"/ZRW-*
run_rc "$DATA" "${COMMON[@]}" --new-job >/dev/null
eq "el archivo del dataset ajeno no fue tocado" "$INO_AJENO" "$(stat -c '%i' -- "$DATA/otro/ajeno.bin")"
eq "y su contenido esta intacto" "$SHA_AJENO" "$(sha256sum -- "$DATA/otro/ajeno.bin" | awk '{print $1}')"
JOB3="$(ls -1 "$ZRW_STATE_ROOT" | grep '^ZRW-' | head -n1)"
grep -q 'skipped_recordsize' "$ZRW_STATE_ROOT/$JOB3/summary.tsv" && pass "el resumen reporta exclusiones por dataset" || fail "falta el desglose por dataset"

# --- 14. .zfs is never walked into -------------------------------------------
mkdir -p "$DATA/.zfs/snapshot/auto-1"
mk ".zfs/snapshot/auto-1/snap.bin" 120000
out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run)"
grep -q 'snap.bin' <<<"$out" && fail "el dry-run entro en .zfs" || pass ".zfs nunca se recorre"
rm -rf "$DATA/.zfs"

# --- 15. hash algorithms ------------------------------------------------------
rm -rf "$ZRW_STATE_ROOT"/ZRW-*
mk hashme.bin 100000
SHA_H="$(sha256sum -- "$DATA/hashme.bin" | awk '{print $1}')"
for algo in sha256 md5 b2; do
    command -v "${algo/sha256/sha256sum}" >/dev/null 2>&1 || true
    rm -rf "$ZRW_STATE_ROOT"/ZRW-*
    run_rc "$DATA" "${COMMON[@]}" --new-job --hash "$algo" >/dev/null
    [[ "$RC" == 0 ]] && pass "corrida completa con --hash $algo" || fail "fallo con --hash $algo (rc=$RC)"
done
eq "el contenido sobrevive a todos los algoritmos" "$SHA_H" "$(sha256sum -- "$DATA/hashme.bin" | awk '{print $1}')"

# --- 16. integrity default is strict, maximum warns about its cost -----------
out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run --integrity maximum)"
grep -q 'relee completo' <<<"$out" && pass "maximum avisa de su coste en stdout" || fail "maximum no avisa de su coste"
out="$(run "$DATA" --threshold 1K --cooldown 0 --adaptive off --new-job --dry-run)"
grep -qiE 'Integridad *: *strict' <<<"$out" && pass "el default de integridad es strict" || fail "el default de integridad no es strict"

# --- 17. --estimate is opt-in -------------------------------------------------
out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run)"
grep -q 'ESTIMACION' <<<"$out" && fail "la estimacion aparece sin pedirla" || pass "la estimacion no sale por defecto"
out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run --estimate)"
grep -q 'ESTIMACION' <<<"$out" && pass "--estimate muestra la estimacion" || fail "--estimate no mostro nada"

# --- 18. dry-run classifies advisory already-target vs needs reblock ---------
grep -q 'Necesitan reblock' <<<"$out" && pass "el dry-run clasifica ya-1M vs reblock" || fail "falta la clasificacion"

# --- 19. no color when asked --------------------------------------------------
out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run --no-color)"
printf '%s' "$out" | grep -q $'\033\[' && fail "--no-color siguio emitiendo ANSI" || pass "--no-color no emite ANSI"

# --- 20. current-job pointer --------------------------------------------------
rm -rf "$ZRW_STATE_ROOT"/ZRW-*
run_rc "$DATA" "${COMMON[@]}" --new-job >/dev/null
[[ -s "$ZRW_STATE_ROOT/.runtime/current" ]] && pass "se registro el trabajo actual" || fail "no hay puntero al trabajo actual"
out="$(run --resume "${COMMON[@]}")"
grep -q 'Usando el trabajo actual' <<<"$out" && pass "--resume sin --job usa el puntero" || fail "--resume sin --job no encontro el trabajo"

# --- 21. unattended runs never prompt on STALE -------------------------------
JOB4="$(head -n1 "$ZRW_STATE_ROOT/.runtime/current")"
head -c 260000 /dev/urandom >"$DATA/otro.bin"     # changes size vs the inventory
out="$(run --job "$JOB4" --resume "${COMMON[@]}" --ui quiet --stale-policy skip)"
[[ "$out" != *"Opcion:"* ]] && pass "en modo desatendido no se pregunta por STALE" || fail "pregunto estando desatendido"

# --- 22. acltype que este host no puede verificar -----------------------------
# acltype=nfsv4 no sirve para esto: nfs4xdr_getfacl y jq son parte de TrueNAS
# SCALE por defecto, asi que en el propio servidor de referencia ese dataset
# SI es verificable y el escenario dejaria de existir. En cambio, un acltype
# que el worker directamente no reconoce cae siempre en la rama "fail closed"
# de acl_verifier_for, sea cual sea el host -- exactamente lo que hace a este
# escenario reproducible en cualquier parte, CI o produccion.
rm -rf "$ZRW_STATE_ROOT"/ZRW-*
mkdir -p "$DATA/rara"
printf '%s\tpool/rara\t1M\tacltype-desconocido\n' "$DATA/rara" >"$LAB/extra_ds"
mk "rara/protegido.bin" 140000
SHA_N4="$(sha256sum -- "$DATA/rara/protegido.bin" | awk '{print $1}')"
INO_N4="$(stat -c '%i' -- "$DATA/rara/protegido.bin")"

out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run)"
grep -qi 'acltype no soportado' <<<"$out" \
    && pass "el dry-run nombra el acltype no soportado" \
    || fail "el dry-run no explica por que el dataset queda fuera"
grep -q 'protegido.bin' <<<"$out" \
    && fail "un archivo sin verificador entro al inventario" \
    || pass "el archivo sin verificador queda fuera del inventario"

run_rc "$DATA" "${COMMON[@]}" --new-job >/dev/null
eq "el archivo sin verificador no fue tocado" "$INO_N4" "$(stat -c '%i' -- "$DATA/rara/protegido.bin")"
eq "y su contenido esta intacto" "$SHA_N4" "$(sha256sum -- "$DATA/rara/protegido.bin" | awk '{print $1}')"

# --- 23. ningun dataset verificable: se para antes de tocar nada --------------
# Mismo motivo que arriba: un acltype inventado, no nfsv4, para que "ningun
# dataset es verificable" sea cierto sin importar que herramientas trae el host.
# pool/otro (el dataset de recordsize distinto que usan los tests de arriba)
# tambien tiene que quedar sin verificador aqui: en un host que SI trae
# nfs4xdr_getfacl/jq, su acltype=nfsv4 por defecto lo volveria verificable y
# taparia el punto del escenario, aunque ese dataset ni siquiera sea el que se
# esta reescribiendo.
rm -rf "$ZRW_STATE_ROOT"/ZRW-*
: >"$LAB/extra_ds"
rm -rf "$DATA/rara"
echo acltype-desconocido >"$LAB/acltype"
echo acltype-desconocido >"$LAB/acltype_otro"
SHA_PRE="$(sha256sum -- "$DATA/normal.bin" | awk '{print $1}')"
run_rc "$DATA" "${COMMON[@]}" --new-job >/dev/null
eq "sin verificador para ningun dataset, sale con EX_DEP_MISSING" "20" "$RC"
eq "y no toco el archivo que iba a reescribir" "$SHA_PRE" "$(sha256sum -- "$DATA/normal.bin" | awk '{print $1}')"
echo posix >"$LAB/acltype"
echo nfsv4 >"$LAB/acltype_otro"

# --- 24. acltype=nfsv4 SI verificable: no debe excluirse por las dudas -------
# El escenario opuesto al 22, y el que realmente importa en un TrueNAS real: si
# nfs4xdr_getfacl y jq estan instalados (caso normal ahi), un dataset nfsv4 se
# procesa como cualquier otro. Antes solo se probaba la mitad de este if.
#
# Tiene que ser el dataset DEL PROPIO TARGET (via $LAB/acltype), no uno extra
# via extra_ds: un dataset extra queda excluido de todos modos por ser "otro
# dataset" bajo la politica default --cross-dataset=skip, lo cual no dice nada
# sobre si su ACL es verificable o no -- ese fue justamente el primer intento
# de este test, y probaba lo que no queria probar.
if command -v nfs4xdr_getfacl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    rm -rf "$ZRW_STATE_ROOT"/ZRW-*
    echo nfsv4 >"$LAB/acltype"
    out="$(run "$DATA" "${COMMON[@]}" --new-job --dry-run)"
    grep -q 'normal.bin' <<<"$out" \
        && pass "con nfs4xdr_getfacl y jq instalados, nfsv4 SI se procesa" \
        || fail "un dataset nfsv4 verificable quedo excluido igual"
    echo posix >"$LAB/acltype"
else
    printf '  --   sin nfs4xdr_getfacl/jq en este host: escenario 24 omitido\n'
fi
echo posix >"$LAB/acltype"

# --- 25. un zdb colgado no bloquea el dry-run -------------------------------
# Encontrado en vivo: zdb -O compite por I/O de metadata con cualquier otra
# cosa que toque el pool, y bajo un scrub real en disco unico se lo vio
# bloqueado mas de 7 minutos -- congelando el job entero por una pista que su
# propio diseno dice que nunca debe decidir nada, y mucho menos bloquear
# trabajo real. `timeout` es lo que sostiene esa promesa: un `zdb` que nunca
# retorna no puede tardar el dry-run mas que unos segundos.
if command -v timeout >/dev/null 2>&1; then
    # A directory of its own, with exactly one candidate: $DATA by this point
    # has accumulated every fixture the earlier scenarios created, and each
    # one costs its own bounded zdb call. This isolates the assertion to
    # "one call, one timeout" instead of "N calls, N timeouts", which would
    # make the wall-clock budget below scale with unrelated test history.
    HANGDIR="$LAB/pool/data-hang"; mkdir -p "$HANGDIR"
    head -c 2000 /dev/urandom >"$HANGDIR/solo.bin"
    printf '%s\tpool/hang\t1M\tposix\n' "$HANGDIR" >"$LAB/extra_ds"
    cat >"$LAB/bin/zdb" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
    chmod +x "$LAB/bin/zdb"
    t0="$(date +%s)"
    timeout 20 "$W" "$HANGDIR" --threshold 1K --cooldown 0 --adaptive off --integrity maximum --dry-run >/dev/null 2>&1
    elapsed=$(( $(date +%s) - t0 ))
    if (( elapsed <= 12 )); then pass "un zdb colgado no bloquea el dry-run mas alla del timeout (${elapsed}s)"
    else fail "el dry-run tardo ${elapsed}s: el timeout interno de zdb no corto el cuelgue"; fi
    printf '#!/usr/bin/env bash\nexit 0\n' >"$LAB/bin/zdb"; chmod +x "$LAB/bin/zdb"
    rm -rf -- "$HANGDIR"; : >"$LAB/extra_ds"
else
    printf '  --   sin binario timeout en este host: escenario 25 omitido\n'
fi

# --- 26. un nombre con salto de linea real, de punta a punta -----------------
# Encontrado en vivo: GNU coreutils antepone una barra invertida al hash
# cuando el nombre de archivo necesita escaparse en la linea de salida (un
# salto de linea embebido es exactamente ese caso), y el temporal generado
# (cuyo nombre nunca necesita escaparse) nunca lleva esa marca -- comparar
# "\<hash>" contra "<hash>" fallaba aunque el contenido fuera identico. Las
# pruebas de "roundtrip inventario" de test_units.sh solo validan que el path
# sobrevive el viaje por el inventario; esta es la primera que corre el ciclo
# real completo (rsync + hash + commit) sobre un nombre asi.
#
# Directorio propio, no el $DATA compartido: para el escenario 26 ese
# directorio ya acumulo el historial completo de los 25 anteriores (hardlinks,
# temporales, estados), y un exit code agregado ahi no diria de forma
# inequivoca si ESTE archivo especifico fallo o fue otro completamente ajeno.
rm -rf "$ZRW_STATE_ROOT"/ZRW-*
NLDIR="$LAB/pool/data-nl"; mkdir -p "$NLDIR"
NLNAME="$(printf 'con salto\nde linea.bin')"
head -c 140000 /dev/urandom >"$NLDIR/$NLNAME"
NL_SHA="$(sha256sum -- "$NLDIR/$NLNAME" | awk '{print $1}')"
printf '%s\tpool/nl\t1M\tposix\n' "$NLDIR" >"$LAB/extra_ds"
run_rc "$NLDIR" "${COMMON[@]}" --new-job >/dev/null
eq "exit code 0 con un nombre que tiene salto de linea real" "0" "$RC"
eq "sha256 identico tras el reblock" "$NL_SHA" "$(sha256sum -- "$NLDIR/$NLNAME" | awk '{print $1}')"
rm -rf -- "$NLDIR"; : >"$LAB/extra_ds"

if (( fails )); then printf '\nintegration: %s FALLOS\n' "$fails"; exit 1; fi
printf '\nintegration: OK\n'
