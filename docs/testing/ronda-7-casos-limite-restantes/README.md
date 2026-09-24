# Ronda 7 — el resto del TEST-PLAN que no necesitaba consola en vivo ni tu autorización

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Continuación autónoma, mismo protocolo (espacio verificado antes, todo dentro
de `ZRW-PRUEBAS-TEMPORAL-20260919`, eliminado al final, logs al repo). Cubre
los puntos de `docs/TEST-PLAN.md` que quedaban abiertos y que se podían
resolver sin intervención — quedaron fuera a propósito los que requieren
consola interactiva en vivo (`[P]`/`[Q]`/`[C]`, wizard, explorador) o tu
autorización (reinicio real, llenar el pool, producción).

## Resultado

Cinco de seis frentes dieron exactamente lo esperado. Uno (`zdb` post-commit)
quedó inconcluso por una causa externa ya conocida, no por un problema del
worker.

- **Hardlink → `SKIPPED`** (batch J): `nlink=2` antes y después, mismo inode,
  contenido intacto, "2 hardlink(s) omitidos: requieren decisión manual" en
  el resumen. Confirmado.
- **UID/GID de un usuario real no root preservados** (batch J): archivo con
  `chown truenas_admin:truenas_admin` (950:950) mantiene el mismo owner tras
  el reblock.
- **Directorio anidado profundo (8 niveles)** (batch J): el archivo en el
  fondo del árbol fue encontrado, reescrito (inode cambió) y su contenido
  quedó intacto.
- **Salida redirigida a un archivo, sin `--ui plain`** (batch J): cero
  ocurrencias del carácter ESC (`\x1b`) — el worker detectó correctamente que
  no había tty y no emitió color/control ANSI.
- **`zdb -O` post-commit para confirmar bloques de 1M** (batch J, ítem J9):
  **inconcluso**. `zdb -O` se colgó incluso con 60s de timeout, verificado
  también con una prueba aparte fuera del batch. Es la misma contención de
  I/O real bajo scrub que ya motivó el fix de la ronda 4 (timeout de 5s
  alrededor del hint advisory) — no un bug nuevo, simplemente no se puede
  hacer esta inspección puntual mientras el scrub siga corriendo. Queda
  pendiente para cuando termine.
- **Temporal `.zrw-` de OTRO job presente** (batch O): el resultado real
  **corrigió mi propia expectativa** al escribir la prueba. El código
  (`recover_temps()`) trata esto como un caso distinto de un huérfano propio:
  un temporal cuyo nombre no coincide con el `job-short` actual se deja
  **completamente intacto** (no se mueve a cuarentena, no se toca en
  absoluto), se cuenta como "temporal ajeno" y se registra una advertencia.
  La cuarentena es exclusivamente para huérfanos **del mismo job** dejados
  por una corrida anterior interrumpida. El log lo confirma línea por línea:
  `[RECOVERY] Temporal de OTRO job; no se toca`. Comportamiento correcto,
  ítem cerrado.
- **Corromper el temporal antes de la verificación → `FAILED`** (batch N): un
  proceso vigía corrompió 64 bytes del temporal justo cuando rsync terminó de
  escribirlo (confirmado por timestamp), antes de que el worker llegara a
  leerlo para el hash de verificación. Resultado: `FAILED`, motivo exacto en
  el journal ("SHA-256 no coincide antes del commit"), sin commit, original
  bit a bit intacto. Un archivo de control corrido aparte (sin vigía) pasó
  normal, confirmando que la prueba no contaminó el resto del comportamiento.
- **`DONE` forzado a mano + modificación posterior → `RECOVERED`** (batch P):
  se forzó `status=DONE` en un `.state` que en realidad nunca se procesó, se
  modificó el archivo real después, y `--resume` lo detectó
  (`estado DONE no coincide con el filesystem`), lo reevaluó desde cero y lo
  reblockeó — preservando el contenido modificado, no el que el estado falso
  daba por sentado. El checkpoint no es la autoridad; el filesystem sí, tal
  como promete el README.
- **`guarded` nunca sube el BW** (batch T): bajo presión real crítica del
  scrub (load=2.57, disco 99%, `psi-io`=58%), se registraron 3 eventos
  `THROTTLE` y **cero** eventos `INCREASE` durante toda la corrida — el job
  terminó pausado protectivamente (mismo comportamiento ya documentado en la
  ronda 6), pero el invariante de `guarded` ("baja pero nunca sube") se
  sostuvo todo el tiempo.

## Índice

- `01-batchJ-hardlink-uidgid-anidado-sinansi.txt`
- `02-batchO-temporal-de-otro-job-no-se-toca.txt`
- `03-batchN-temporal-corrompido-failed.txt`
- `04-batchP-done-forzado-recovered.txt`
- `05-batchT-guarded-nunca-sube.txt`

## Lo que sigue sin poder probarse de forma autónoma

- **`zdb -O` post-commit** — bloqueado por el scrub real en curso; reintentar
  cuando termine (`zpool status` reportaba ~23% de avance al momento de esta
  ronda).
- **ACL POSIX no trivial (`setfacl`) y `atime=on`** — el dataset real
  (`toolbox/media`) tiene `atime=off`, y el único `acltype=posix` real en
  este pool es `toolbox/.ix-virt/*` (datasets de sistema para VMs/contenedores
  de TrueNAS, no aptos para pruebas). Probar esto de verdad requeriría o bien
  cambiar una propiedad de un dataset de producción (aunque sea
  transitoriamente) o crear y destruir un dataset de laboratorio dedicado —
  ambas son decisiones de infraestructura, no solo escritura de archivos, así
  que quedaron fuera de esta ronda a propósito, pendientes de tu decisión.

---

# English

Autonomous continuation, same protocol (space checked beforehand, everything
inside `ZRW-PRUEBAS-TEMPORAL-20260919`, deleted at the end, logs committed
to the repo). Covers the points from `docs/TEST-PLAN.md` that were still
open and could be resolved without intervention — deliberately left out
were the ones that require a live interactive console (`[P]`/`[Q]`/`[C]`,
wizard, explorer) or your authorization (a real reboot, filling the pool,
production).

## Result

Five out of six fronts gave exactly the expected result. One (`zdb`
post-commit) was left inconclusive due to an already-known external cause,
not a worker problem.

- **Hardlink → `SKIPPED`** (batch J): `nlink=2` before and after, same
  inode, content intact, "2 hardlink(s) omitidos: requieren decisión
  manual" in the summary. Confirmed.
- **UID/GID of a real non-root user preserved** (batch J): a file with
  `chown truenas_admin:truenas_admin` (950:950) keeps the same owner after
  the reblock.
- **Deeply nested directory (8 levels)** (batch J): the file at the bottom
  of the tree was found, rewritten (inode changed), and its content stayed
  intact.
- **Output redirected to a file, without `--ui plain`** (batch J): zero
  occurrences of the ESC character (`\x1b`) — the worker correctly detected
  there was no tty and didn't emit ANSI color/control codes.
- **`zdb -O` post-commit to confirm 1M blocks** (batch J, item J9):
  **inconclusive**. `zdb -O` hung even with a 60s timeout, also verified
  with a separate test outside the batch. It's the same real I/O
  contention under scrub that already motivated the round 4 fix (a 5s
  timeout around the advisory hint) — not a new bug, this particular
  inspection just can't be done while the scrub keeps running. Left
  pending until it finishes.
- **`.zrw-` temp file from ANOTHER job present** (batch O): the real result
  **corrected my own expectation** while writing the test. The code
  (`recover_temps()`) treats this as a different case from an orphan of its
  own: a temp file whose name doesn't match the current `job-short` is left
  **completely untouched** (not moved to quarantine, not touched at all),
  counted as a "foreign temp" ("temporal ajeno"), and logs a warning.
  Quarantine is exclusively for orphans **of the same job** left behind by
  a previously interrupted run. The log confirms it line by line:
  `[RECOVERY] Temporal de OTRO job; no se toca`. Correct behavior, item
  closed.
- **Corrupting the temp file before verification → `FAILED`** (batch N): a
  watcher process corrupted 64 bytes of the temp file right when rsync
  finished writing it (confirmed by timestamp), before the worker got to
  read it for the verification hash. Result: `FAILED`, exact reason in the
  journal ("SHA-256 no coincide antes del commit"), no commit, original
  bit-for-bit intact. A control file run separately (without the watcher)
  passed normally, confirming the test didn't contaminate the rest of the
  behavior.
- **`DONE` forced by hand + later modification → `RECOVERED`** (batch P):
  `status=DONE` was forced on a `.state` file that had actually never been
  processed, the real file was then modified, and `--resume` detected it
  (`estado DONE no coincide con el filesystem`), re-evaluated it from
  scratch, and reblocked it — preserving the modified content, not the
  content the false state assumed. The checkpoint isn't the authority; the
  filesystem is, exactly as the README promises.
- **`guarded` never raises the BW** (batch T): under real critical scrub
  pressure (load=2.57, disk 99%, `psi-io`=58%), 3 `THROTTLE` events were
  logged and **zero** `INCREASE` events during the entire run — the job
  ended up protectively paused (same behavior already documented in round
  6), but the `guarded` invariant ("lowers but never raises") held the
  whole time.

## Index

- `01-batchJ-hardlink-uidgid-anidado-sinansi.txt`
- `02-batchO-temporal-de-otro-job-no-se-toca.txt`
- `03-batchN-temporal-corrompido-failed.txt`
- `04-batchP-done-forzado-recovered.txt`
- `05-batchT-guarded-nunca-sube.txt`

## What still can't be tested autonomously

- **`zdb -O` post-commit** — blocked by the real scrub currently running;
  retry once it finishes (`zpool status` reported ~23% progress at the time
  of this round).
- **Non-trivial POSIX ACL (`setfacl`) and `atime=on`** — the real dataset
  (`toolbox/media`) has `atime=off`, and the only real `acltype=posix` in
  this pool is `toolbox/.ix-virt/*` (TrueNAS system datasets for
  VMs/containers, not suitable for testing). Actually testing this would
  require either changing a production dataset property (even if only
  transiently) or creating and destroying a dedicated lab dataset — both
  are infrastructure decisions, not just file writes, so they were
  deliberately left out of this round, pending your decision.
