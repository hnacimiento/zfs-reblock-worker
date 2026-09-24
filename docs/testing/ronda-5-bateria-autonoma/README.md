# Ronda 5 — auditoría de `sync`/`sync -f`, batería autónoma, y dos bugs reales con nombres de archivo con salto de línea

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Ronda ejecutada de forma autónoma (sin supervisión en vivo), siempre dentro
del directorio de prueba dedicado `ZRW-PRUEBAS-TEMPORAL-20260919` (eliminado
al final de cada prueba), con los logs traídos de vuelta a este repositorio
para análisis posterior. Cubrió tres frentes:

1. **Auditoría de código de `sync`/`sync -f`**: se revisó cada punto donde el
   worker declara algo durable, para confirmar que sincroniza la ruta
   correcta en el momento correcto. No se encontró ningún bug; sí se
   documentaron en el código dos precisiones que valía la pena dejar
   explícitas (semántica real de `sync -f`, y por qué el commit rename no
   necesita su propio `sync` gracias a la atomicidad de TXG en ZFS).

2. **Batería autónoma contra ZFS real**, bajo un scrub real corriendo en el
   pool durante buena parte de la ronda: governor adaptativo (`off`/`guarded`)
   bajo presión real, `--integrity standard` vs `maximum`, `--stop-after` /
   `--stop-at`, `STALE` en ambos checkpoints (antes de copiar y durante la
   copia), ACL con `fhandle` cambiado pero contenido idéntico, archivos
   sparse, archivos de solo lectura, y una serie de nombres de archivo límite
   (tab, comillas, `$`/backtick, emoji/acentos, nombre de 227 caracteres, y
   un salto de línea literal).

3. **Dos bugs reales, encontrados por el caso del salto de línea**, ambos con
   la misma causa raíz — código que asumía una forma fija en la salida de una
   herramienta externa (`sha256sum`, `getfattr`, `getfacl`), sin contar con
   que esa forma cambia cuando el nombre del archivo tiene un salto de línea:
   - `hash_of()` no le quitaba la barra invertida que `sha256sum` antepone al
     hash cuando el nombre necesita escaparse, así que la comparación de
     integridad fallaba siempre para estos archivos.
   - `xattr_equal()` y `acl_equal_posix()` usaban `sed '1d'` / `sed '1,3d'`
     para descartar el encabezado de `getfattr`/`getfacl`, asumiendo un
     número fijo de líneas; un nombre con salto de línea parte ese
     encabezado en líneas adicionales y rompe el corte posicional.

   En ambos casos el efecto era seguro (el original nunca se tocaba, el
   archivo terminaba en `FAILED` tras agotar reintentos) pero silencioso: un
   archivo real con un salto de línea en su nombre nunca se hubiera
   reblockeado. Corregido y liberado como **4.2.3**.

## Índice

- `01-batchA-governor-integrity-stopafter.txt` — governor `off`/`guarded` con
  scrub real activo, `--integrity standard` (sin doble hash, más rápido) vs
  `maximum`, `--stop-after`/`--stop-at`.
- `02-batchB-stale-checkpoint1-corto.txt` — primer intento de `STALE`
  "antes de copiar": el sleep fue demasiado corto y el archivo cambió antes
  de lo esperado (documentado, no un bug).
- `03-batchB2-stale-checkpoint2-durante-copia.txt` — repetición con sleep
  ajustado: `STALE` detectado correctamente "durante la copia".
- `04-batchC-acl-fhandle-dispositivos.txt` — ACL con `fhandle` cambiado pero
  el resto idéntico: el worker no lo marca como diferencia (ítem de
  TEST-PLAN.md que quedaba sin verificar).
- `05-batchD-nombres-limite-primera-corrida-1-fallo.txt` — primera corrida
  real de los 6 nombres límite + sparse + solo-lectura: 7/8 reescritos, el
  del salto de línea falla (el hallazgo que dispara todo lo demás).
- `06-batchD2-aislamiento-uno-por-uno.txt` — cada nombre límite corrido solo
  (`--cooldown 0`) para aislar cuál falla sin ambigüedad: confirma que es
  específicamente el del salto de línea.
- `07-newline-isolate-diagnostico-hash-escapado.txt` — diagnóstico dirigido:
  `cat -A` sobre la salida cruda de `sha256sum`, confirmando la barra
  invertida antepuesta y el `\n` literal en el nombre.
- `08-verify423-newline-real-zfs.txt` — con `hash_of()` y `xattr_equal()`
  corregidos (4.2.3 recién desplegado), corrida real contra
  `toolbox/media` (acltype=nfsv4, camino distinto al del laboratorio): SHA
  idéntico, mtime preservado, RC=0.
- `09-batchD-repro-8-archivos-4.2.3-todos-ok.txt` — re-corrida completa del
  lote original de 8 archivos, ahora con las tres correcciones (`hash_of`,
  `xattr_equal`, `acl_equal_posix`) desplegadas: 8/8 reescritos, 0 fallidos.
- `10-batchF-estado-forzado-y-dos-workers-reales.txt` — un `.state` forzado a
  mano a `PROCESSING` se recupera (`RECOVERED`) y reprocesa correctamente al
  hacer `--resume`; y dos workers reales, vivos al mismo tiempo sobre el
  mismo job: el segundo recibe `EX_LOCKED` (11) sin tocar al primero, que
  termina solo con RC=0 y contenido idéntico al original.
- `11-batchE-preflight-negativo.txt` — `--check` sin `rsync` en el PATH
  (dependencia crítica) sale con `EX_DEP_MISSING` (20) sin modificar nada;
  sin `ionice` (opcional) sigue `READY` con una advertencia; corrido como
  `truenas_admin` (no root) sale con `EX_NOT_ROOT` (10).

## Por qué esto importa

El caso del salto de línea es exactamente el tipo de arista que un
laboratorio simulado con nombres "normales" nunca hubiera ejercitado, y que
solo apareció por incluir deliberadamente nombres límite en la batería. Los
dos bugs que reveló eran reales, reproducibles, y silenciosamente seguros
(nunca hubo riesgo de pérdida de datos) pero habrían dejado sin reblockear,
para siempre, cualquier archivo real con un salto de línea en su nombre.

---

# English

Round run autonomously (without live supervision), always inside
the dedicated test directory `ZRW-PRUEBAS-TEMPORAL-20260919` (deleted
at the end of each test), with the logs brought back into this repository
for later analysis. It covered three fronts:

1. **Code audit of `sync`/`sync -f`**: every point where the worker declares
   something durable was reviewed, to confirm it syncs the right path at the
   right time. No bug was found; two clarifications worth stating
   explicitly were documented in the code (the real semantics of `sync -f`,
   and why the commit rename doesn't need its own `sync` thanks to ZFS's
   TXG atomicity).

2. **Autonomous battery against real ZFS**, under a real scrub running on
   the pool for much of the round: adaptive governor (`off`/`guarded`)
   under real pressure, `--integrity standard` vs `maximum`, `--stop-after` /
   `--stop-at`, `STALE` at both checkpoints (before copying and during the
   copy), ACL with a changed `fhandle` but identical content, sparse
   files, read-only files, and a series of edge-case file names
   (tab, quotes, `$`/backtick, emoji/accents, a 227-character name, and
   a literal newline).

3. **Two real bugs, found via the newline case**, both with
   the same root cause — code that assumed a fixed shape for the output of
   an external tool (`sha256sum`, `getfattr`, `getfacl`), without accounting
   for that shape changing when the file name contains a newline:
   - `hash_of()` wasn't stripping the backslash that `sha256sum` prepends to
     the hash when the name needs escaping, so the integrity comparison
     always failed for these files.
   - `xattr_equal()` and `acl_equal_posix()` used `sed '1d'` / `sed '1,3d'`
     to discard the `getfattr`/`getfacl` header, assuming a
     fixed number of lines; a name with a newline splits that
     header into extra lines and breaks the positional cut.

   In both cases the effect was safe (the original was never touched, the
   file ended up `FAILED` after exhausting retries) but silent: a
   real file with a newline in its name would never have been
   reblocked. Fixed and released as **4.2.3**.

## Index

- `01-batchA-governor-integrity-stopafter.txt` — governor `off`/`guarded` with
  a real scrub active, `--integrity standard` (no double hash, faster) vs
  `maximum`, `--stop-after`/`--stop-at`.
- `02-batchB-stale-checkpoint1-corto.txt` — first attempt at `STALE`
  "before copying": the sleep was too short and the file changed before
  expected (documented, not a bug).
- `03-batchB2-stale-checkpoint2-durante-copia.txt` — repeated with an
  adjusted sleep: `STALE` correctly detected "during the copy".
- `04-batchC-acl-fhandle-dispositivos.txt` — ACL with a changed `fhandle` but
  everything else identical: the worker does not flag it as a difference
  (a TEST-PLAN.md item that remained unverified).
- `05-batchD-nombres-limite-primera-corrida-1-fallo.txt` — first real run of
  the 6 edge-case names + sparse + read-only: 7/8 rewritten, the
  newline one fails (the finding that triggers everything else).
- `06-batchD2-aislamiento-uno-por-uno.txt` — each edge-case name run alone
  (`--cooldown 0`) to unambiguously isolate which one fails: confirms it's
  specifically the newline one.
- `07-newline-isolate-diagnostico-hash-escapado.txt` — targeted diagnosis:
  `cat -A` on the raw `sha256sum` output, confirming the prepended
  backslash and the literal `\n` in the name.
- `08-verify423-newline-real-zfs.txt` — with `hash_of()` and `xattr_equal()`
  fixed (4.2.3 freshly deployed), a real run against
  `toolbox/media` (acltype=nfsv4, a different path than the lab's): SHA
  identical, mtime preserved, RC=0.
- `09-batchD-repro-8-archivos-4.2.3-todos-ok.txt` — full re-run of
  the original batch of 8 files, now with all three fixes (`hash_of`,
  `xattr_equal`, `acl_equal_posix`) deployed: 8/8 rewritten, 0 failed.
- `10-batchF-estado-forzado-y-dos-workers-reales.txt` — a `.state` forced by
  hand to `PROCESSING` recovers (`RECOVERED`) and reprocesses correctly on
  `--resume`; and two real workers, alive at the same time on the
  same job: the second receives `EX_LOCKED` (11) without touching the first,
  which finishes on its own with RC=0 and content identical to the original.
- `11-batchE-preflight-negativo.txt` — `--check` with no `rsync` in the PATH
  (a critical dependency) exits with `EX_DEP_MISSING` (20) without modifying
  anything; without `ionice` (optional) it stays `READY` with a warning;
  run as `truenas_admin` (not root) it exits with `EX_NOT_ROOT` (10).

## Why this matters

The newline case is exactly the kind of edge that a simulated lab with
"normal" names would never have exercised, and it only surfaced from
deliberately including edge-case names in the battery. The two bugs it
revealed were real, reproducible, and silently safe (there was never any
risk of data loss) but would have left any real file with a newline in
its name un-reblocked, forever.
