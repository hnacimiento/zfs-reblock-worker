# Ronda 14 — b3sum real y verificador ACL ausente

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Los tres últimos ítems abiertos que no eran una decisión de rollout (dataset
completo) ni estaban prohibidos (llenar el pool). A diferencia de las rondas
anteriores, ninguno de estos tres pasos necesitaba al operador tecleando en
su propia consola: son `--dry-run` o un intento de job que muere antes de
tocar nada, así que se ejecutaron directamente por SSH de solo lectura /
no interactivo, con la salida redirigida a un log y revisada después, para
no hacerle repetir comandos que no requerían su intervención.

## A. `--hash b3` contra un `b3sum` real

El operador instaló `b3sum` en el NAS de referencia. Con eso, faltaba lo
único que la lógica de cascada (`b2 → b3 → sha256`, implementada desde
4.4.0) nunca pudo probar: el formato de salida real de `b3sum`.

```
zfs-reblock-worker.sh /mnt/toolbox/media/Musicales --dry-run --dry-sample 1 --hash b3
```

Mismo archivo real de la ronda 11 (`Álbum de Ejemplo
[...].ratDVD`, 2.19 GiB, ya reblockeado). Resultado: `Hash: b3` en el
reporte, sin ningún error, con lectura real medida en 2.19 GiB/s. Verificado
aparte, corriendo `b3sum` a mano sobre el mismo archivo: la salida es
`<hash>  <ruta>` (dos espacios), exactamente el mismo formato que
`sha256sum`/`b2sum` — el `awk '{print $1}'` de `hash_of()` la parsea sin
ningún cambio. Ver `A-b3sum.log` (local).

## B1. Dataset `nfsv4` real sin `nfs4xdr_getfacl`/`jq`

PATH sombra: un directorio con símlinks a cada herramienta real del worker,
salvo `nfs4xdr_getfacl` y `jq` — el mismo mecanismo de la ronda 5/13, pero
aplicado con `env PATH=...` acotado a un único proceso hijo en vez de
`export`, así que ni hace falta restaurar nada al terminar (el `PATH` real
de la sesión nunca se tocó). Los binarios reales del sistema tampoco se
tocan: son símlinks en un directorio aparte.

```
env PATH=<sombra> zfs-reblock-worker.sh /mnt/toolbox --dry-run
```

Apuntado a `/mnt/toolbox` (no a un dataset hijo) a propósito, para que el
árbol completo entre en el mismo reporte. Resultado real, no simulado:
**todos** los datasets bajo `/mnt/toolbox` resultaron ser `acltype=nfsv4` —
el único con `recordsize=1M` es `toolbox/media`, y quedó marcado
`OMITE (faltan nfs4xdr_getfacl y/o jq)` en el log, exactamente como pide el
ítem. El resto ya estaba fuera por recordsize distinto, sin relación con
este hallazgo. Cortado con `timeout 90` porque el recorrido de metadata de
los 12 TB del pool no llega a terminar en ese lapso — no hacía falta: el
reporte por dataset se imprime al principio, antes de recorrer un solo
archivo. Ver `B1-nfsv4-sin-verificador.log` (local).

## B2. Árbol entero sin ningún verificador → código `20`

A diferencia de A y B1, este comportamiento solo está conectado al camino
de un job real (`--check` y `--dry-run` solo avisan, no cortan) — así que
necesitaba un target donde fallar de verdad no arriesgara nada. Dataset de
laboratorio descartable, creado y destruido en la misma ronda:

```
zfs create -o acltype=posix -o atime=on -o recordsize=1M toolbox/zrw-lab
env PATH=<sombra-sin-getfacl-ni-getfattr> zfs-reblock-worker.sh /mnt/toolbox/zrw-lab
```

Resultado: código de salida `20` exacto, con
`[ERROR] Ningun dataset del arbol tiene un verificador de ACL/xattr disponible en este host (toolbox/zrw-lab:posix).`
en el log, y `toolbox/zrw-lab` sin ningún archivo tocado. Dataset destruido
al terminar (`zfs destroy toolbox/zrw-lab`). Ver
`B2-arbol-sin-verificador.log` (local).

**Corrección, hecha en la ronda 15:** la primera verificación de este ítem
decía "ni siquiera llegó a crear una carpeta de job" — eso estaba mal, por
chequear el directorio equivocado. `STATE_ROOT` real del worker es
`<directorio del script>/jobs` (`/mnt/toolbox/scripts/zrw/jobs`), no
`/mnt/toolbox/scripts/jobs` (una carpeta vieja de otra convención, de
rondas anteriores). Con la ruta correcta, sí quedaba una carpeta de job
vacía (`config.env`, `events.log`, sin `inventory.tsv` porque muere antes de
construirlo) — completamente inofensiva, sin ningún archivo real tocado,
pero sí un residuo. Se limpió en la ronda 15 junto con el resto.

## Limpieza

Todo lo creado para esta ronda era descartable por diseño: el directorio
PATH-sombra, el dataset de laboratorio y una carpeta temporal de logs en el
propio NAS. Los tres se borraron al terminar; lo único que queda es esta
carpeta con los tres logs, copiados al repo antes de borrar el original.

## Cierre

Con esto, de los cuatro puntos que quedaban "con cautela" en el README, tres
quedan cerrados con evidencia real: `b3sum`, y los dos escenarios de
verificador ACL ausente. El cuarto — reblockear el dataset completo — sigue
siendo una decisión de rollout del operador, no un test; y "llenar el pool"
sigue prohibido de forma permanente. Versión del worker sin cambios:
**4.4.7** (esta ronda no encontró ningún bug ni requirió tocar el código).

---

# English

The last three open items that were neither a rollout decision (the full
dataset) nor forbidden (filling the pool). Unlike previous rounds, none of
these three steps needed the operator typing on their own console: they are
either `--dry-run` runs or a job attempt that dies before touching anything,
so they were run directly over a read-only, non-interactive SSH session,
with the output redirected to a log and reviewed afterward, so as not to
make him repeat commands that didn't require his intervention.

## A. `--hash b3` against a real `b3sum`

The operator installed `b3sum` on the reference NAS. With that in place, the
only thing left that the cascade logic (`b2 → b3 → sha256`, implemented
since 4.4.0) could never test was `b3sum`'s real output format.

```
zfs-reblock-worker.sh /mnt/toolbox/media/Musicales --dry-run --dry-sample 1 --hash b3
```

Same real file from round 11 (`Sample Album
[...].ratDVD`, 2.19 GiB, already reblocked). Result: `Hash: b3` in the
report, with no errors, with real reading measured at 2.19 GiB/s. Verified
separately, running `b3sum` by hand on the same file: the output is
`<hash>  <path>` (two spaces), exactly the same format as
`sha256sum`/`b2sum` — `hash_of()`'s `awk '{print $1}'` parses it with no
changes needed. See `A-b3sum.log` (local).

## B1. Real `nfsv4` dataset without `nfs4xdr_getfacl`/`jq`

Shadow PATH: a directory with symlinks to every real worker tool, except
`nfs4xdr_getfacl` and `jq` — the same mechanism from round 5/13, but
applied with `env PATH=...` scoped to a single child process instead of
`export`, so there's nothing to restore afterward (the session's real
`PATH` was never touched). The system's real binaries aren't touched
either: they're symlinks in a separate directory.

```
env PATH=<sombra> zfs-reblock-worker.sh /mnt/toolbox --dry-run
```

Pointed at `/mnt/toolbox` (not a child dataset) on purpose, so the entire
tree would show up in the same report. Real, not simulated, result:
**every** dataset under `/mnt/toolbox` turned out to be `acltype=nfsv4` —
the only one with `recordsize=1M` is `toolbox/media`, and it was correctly
flagged `OMITE (faltan nfs4xdr_getfacl y/o jq)` ("SKIPPED (missing
nfs4xdr_getfacl and/or jq)") in the log, exactly as the item asks. The rest
were already excluded due to a different recordsize, unrelated to this
finding. Cut short with `timeout 90` because walking the metadata of the
pool's 12 TB doesn't finish within that window — that didn't matter: the
per-dataset report is printed at the start, before walking a single file.
See `B1-nfsv4-sin-verificador.log` (local).

## B2. Entire tree with no verifier at all → code `20`

Unlike A and B1, this behavior is only wired into the path of a real job
(`--check` and `--dry-run` only warn, they don't abort) — so it needed a
target where a real failure wouldn't risk anything. Disposable lab dataset,
created and destroyed within the same round:

```
zfs create -o acltype=posix -o atime=on -o recordsize=1M toolbox/zrw-lab
env PATH=<sombra-sin-getfacl-ni-getfattr> zfs-reblock-worker.sh /mnt/toolbox/zrw-lab
```

Result: exact exit code `20`, with
`[ERROR] Ningun dataset del arbol tiene un verificador de ACL/xattr disponible en este host (toolbox/zrw-lab:posix).`
in the log, and `toolbox/zrw-lab` with no file touched at all. Dataset
destroyed at the end (`zfs destroy toolbox/zrw-lab`). See
`B2-arbol-sin-verificador.log` (local).

**Correction, made in round 15:** this item's first verification claimed
"it didn't even get to create a job folder" — that was wrong, from checking
the wrong directory. The worker's real `STATE_ROOT` is
`<script directory>/jobs` (`/mnt/toolbox/scripts/zrw/jobs`), not
`/mnt/toolbox/scripts/jobs` (an old folder from a different, earlier
convention). With the correct path, there was in fact an empty job folder
left behind (`config.env`, `events.log`, no `inventory.tsv` since it dies
before building one) — completely harmless, with no real file touched, but
a leftover nonetheless. Cleaned up in round 15 along with the rest.

## Cleanup

Everything created for this round was disposable by design: the
shadow-PATH directory, the lab dataset, and a temporary log folder on the
NAS itself. All three were deleted at the end; the only thing that remains
is this folder with the three logs, copied into the repo before deleting
the original.

## Closing

With this, of the four points that were left "with caution" in the README,
three are now closed with real evidence: `b3sum`, and the two missing-ACL-
verifier scenarios. The fourth — reblocking the full dataset — remains a
rollout decision for the operator, not a test; and "filling the pool"
remains permanently forbidden. Worker version unchanged:
**4.4.7** (this round found no bugs and required no code changes).
