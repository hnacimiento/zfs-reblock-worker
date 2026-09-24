# Ronda 15 — pausa segura por espacio, sin llenar el pool real

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

El único ítem que quedaba en la sección G del `TEST-PLAN.md` ("Llenar el
pool → pausa segura...") estaba prohibido de forma permanente por Hernán:
llenar el pool real de producción para esta prueba no es aceptable bajo
ninguna autorización general. En esta ronda, el propio Hernán propuso el
reemplazo: en vez de llenar el pool, ponerle una `quota` chica a un dataset
descartable y llenar **esa cuota**. El worker mide el espacio libre por
dataset (no por pool), así que un dataset con cuota agotada dispara la misma
lógica de pausa segura que un pool real lleno, sin que el pool de
producción (varios TB libres) se entere. Confirmado explícitamente como el
reemplazo definitivo de este ítem, no una excepción puntual — la
prohibición sobre el pool real sigue vigente sin cambios.

Ejecutada, como la ronda 14, directamente por SSH no interactivo (sin
necesitar la consola del operador).

## Preparación

```bash
zfs create -o recordsize=1M -o quota=1200M toolbox/zrw-lab
dd if=/dev/urandom of=/mnt/toolbox/zrw-lab/candidate.bin bs=1M count=10   # candidato real
dd if=/dev/urandom of=/mnt/toolbox/zrw-lab/filler.bin    bs=1M count=250  # relleno
```

`/dev/urandom` a propósito: el pool tiene `compression=lz4`, y datos
compresibles (ceros) no hubieran consumido espacio real contra la cuota. El
margen mínimo del worker es fijo (1 GiB, no configurable por CLI), así que
el cálculo fue: candidato 10 MiB + margen 1024 MiB = 1034 MiB requeridos;
con cuota 1200 MiB y ~260 MiB usados, quedaron 965 MiB libres — por debajo
del requisito, sin necesidad de escribir casi nada.

## C1. Disparo de la pausa

```bash
zfs-reblock-worker.sh /mnt/toolbox/zrw-lab --threshold 5M --ui plain
```

Resultado: código de salida `13` (`EX_PAUSED`) exacto.
`[ERROR] Pausado por falta de espacio en /mnt/toolbox/zrw-lab (libres: 939.00 MiB).`
en el log. El candidato quedó `PENDING` en el journal, con la razón
`espacio insuficiente; lote pausado` — nunca `FAILED`, y su hash SHA-256
idéntico al de antes de la corrida: no se le tocó un byte. Sin temporales
huérfanos. Ver `C1-pausa-espacio.log` (local).

## C2. Liberar espacio y reanudar

```bash
rm /mnt/toolbox/zrw-lab/filler.bin
zfs-reblock-worker.sh --job <JOB_ID> --resume --ui plain
```

Resultado: código de salida `0`. El candidato pasó a `PROCESSING` →
`VERIFYING` → `DONE` (`commit verificado`), mismo hash SHA-256 que antes de
empezar. El resumen final del job: `failed=0`, `processed=1`,
`missing=1` (el `filler.bin` borrado antes del resume, correctamente
`MISSING` y no `FAILED` — estaba en el inventario original, snapshot del
job, como documenta el contrato de invariantes). Ver
`C2-resume.log` (local).

## Un error propio, encontrado y corregido en esta misma ronda

Verificando el estado de los `jobs/` durante esta ronda apareció una carpeta
de job de la **ronda anterior** (el intento de job real del ítem B2, árbol
sin verificador) que se había dado por borrada. La causa: `STATE_ROOT` del
worker es `<directorio del script>/jobs`
(`/mnt/toolbox/scripts/zrw/jobs`), y la verificación de la ronda 14 había
mirado `/mnt/toolbox/scripts/jobs` — una ruta distinta, vieja, de otra
convención. La carpeta residual era inofensiva (sin `inventory.tsv`, ningún
archivo real tocado, exactamente lo que predice el código), pero la
afirmación "no dejó ninguna carpeta" en el README de la ronda 14 estaba mal.
Corregido ahí mismo, y ambas carpetas (la de la ronda 14 y la de esta ronda)
se borraron en la limpieza final de esta ronda.

## Limpieza

Dataset de laboratorio destruido (`zfs destroy toolbox/zrw-lab`), las dos
carpetas de job residuales borradas, sin residuos en el NAS. Confirmado con
`zfs list` que no queda ningún dataset `zrw-lab`.

## Cierre

Con esto, los cuatro puntos "con cautela" del README original quedan todos
resueltos de una forma u otra: tres cerrados con evidencia real (`b3sum`,
los dos escenarios de verificador ausente, y ahora la pausa por espacio), y
uno (dataset completo) que sigue siendo, como siempre, una decisión de
rollout de Hernán y no un test. La prohibición sobre llenar el pool real
sigue permanente y sin excepciones. Versión del worker sin cambios:
**4.4.7** (ninguna ronda de esta serie encontró un bug de código).

---

# English

The one item still left in section G of `TEST-PLAN.md` ("Fill the pool →
safe pause...") was permanently forbidden by Hernán: filling the real
production pool for this test is not acceptable under any general
authorization. In this round, Hernán himself proposed the substitute:
instead of filling the pool, put a small `quota` on a disposable dataset
and fill **that quota**. The worker measures free space per dataset (not
per pool), so a dataset with an exhausted quota triggers the same safe-pause
logic as a full real pool, without the production pool (several TB free)
ever noticing. Explicitly confirmed as the definitive substitute for this
item, not a one-off exception — the prohibition on the real pool remains in
force unchanged.

Run, like round 14, directly over non-interactive SSH (with no need for the
operator's console).

## Setup

```bash
zfs create -o recordsize=1M -o quota=1200M toolbox/zrw-lab
dd if=/dev/urandom of=/mnt/toolbox/zrw-lab/candidate.bin bs=1M count=10   # candidato real
dd if=/dev/urandom of=/mnt/toolbox/zrw-lab/filler.bin    bs=1M count=250  # relleno
```

`/dev/urandom` on purpose: the pool has `compression=lz4`, and compressible
data (zeros) wouldn't have consumed real space against the quota. The
worker's minimum margin is fixed (1 GiB, not configurable via CLI), so the
math was: 10 MiB candidate + 1024 MiB margin = 1034 MiB required; with a
1200 MiB quota and ~260 MiB used, 965 MiB were left free — below the
requirement, without needing to write almost anything.

## C1. Triggering the pause

```bash
zfs-reblock-worker.sh /mnt/toolbox/zrw-lab --threshold 5M --ui plain
```

Result: exact exit code `13` (`EX_PAUSED`).
`[ERROR] Pausado por falta de espacio en /mnt/toolbox/zrw-lab (libres: 939.00 MiB).`
in the log. The candidate stayed `PENDING` in the journal, with the reason
`espacio insuficiente; lote pausado` ("insufficient space; batch paused")
— never `FAILED`, and its SHA-256 hash identical to before the run: not a
byte was touched. No orphaned temp files. See
`C1-pausa-espacio.log` (local).

## C2. Freeing space and resuming

```bash
rm /mnt/toolbox/zrw-lab/filler.bin
zfs-reblock-worker.sh --job <JOB_ID> --resume --ui plain
```

Result: exit code `0`. The candidate moved to `PROCESSING` →
`VERIFYING` → `DONE` (`commit verificado`), same SHA-256 hash as before it
started. The job's final summary: `failed=0`, `processed=1`,
`missing=1` (the `filler.bin` deleted before the resume, correctly
reported as `MISSING` and not `FAILED` — it was in the original inventory,
the job's snapshot, exactly as the invariants contract documents). See
`C2-resume.log` (local).

## A mistake of my own, found and corrected in this same round

Checking the state of `jobs/` during this round turned up a job folder from
the **previous round** (the real job attempt for item B2, the
verifier-less tree) that had been assumed deleted. The cause:
the worker's `STATE_ROOT` is `<script directory>/jobs`
(`/mnt/toolbox/scripts/zrw/jobs`), and round 14's verification had checked
`/mnt/toolbox/scripts/jobs` — a different, old path, from an earlier
convention. The leftover folder was harmless (no `inventory.tsv`, no real
file touched, exactly what the code predicts), but the claim "it left no
folder behind" in round 14's README was wrong. Corrected right there, and
both folders (round 14's and this round's) were deleted in this round's
final cleanup.

## Cleanup

Lab dataset destroyed (`zfs destroy toolbox/zrw-lab`), both leftover job
folders deleted, no residue left on the NAS. Confirmed with `zfs list` that
no `zrw-lab` dataset remains.

## Closing

With this, all four "with caution" points from the original README are now
resolved one way or another: three closed with real evidence (`b3sum`, the
two missing-verifier scenarios, and now the space-pause), and one (full
dataset) that remains, as always, a rollout decision for Hernán and not a
test. The prohibition on filling the real pool remains permanent and
without exceptions. Worker version unchanged:
**4.4.7** (no round in this series found a code bug).
