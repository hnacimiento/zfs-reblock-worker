# Ronda 9 — investigación de `zdb -O`, governor con servidor genuinamente ocioso, y cierre de ACL POSIX/`atime`

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Continuación autónoma sobre lo que quedaba abierto tras la 4.4.0, mismo
protocolo (espacio verificado antes, todo dentro de un directorio o dataset
descartable, eliminado al final, logs al repo). Cuatro frentes: uno de
investigación pura, tres de cierre de ítems abiertos del `TEST-PLAN.md`.
Deliberadamente **no** se tocó `--auto-resume` contra presión real en esta
ronda: eso requeriría generar carga sintética a propósito sobre el pool de
producción, y quedó pendiente de autorización explícita en vez de darse por
sentado.

## Resultado

- **Causa raíz de `zdb -O`, encontrada** (`00-investigacion-...txt`): no era
  el scrub ni un bug. `zdb -O` lee las etiquetas del pool en disco, que solo
  se actualizan en el siguiente ciclo de sincronización de TXG
  (`zfs_txg_timeout`, 5s por defecto). Un archivo recién comprometido es
  invisible para `zdb -O` durante ~5-10s después de su `sync`, aunque ya
  esté completamente persistido. Confirmado con una prueba de retraso
  escalonado (falla hasta +5s, funciona siempre desde +10s) y contra un
  archivo real de producción de julio (funciona perfecto, sin esperar nada —
  ya estaba viejo). Con la espera correcta, se confirmó `dblk=1M` sobre un
  archivo recién reblockeado, cerrando por fin el ítem original de la
  sección C del plan. No requiere ningún cambio de código: `zfs_hint()` sigue
  siendo advisory-only por diseño, y esperar ese ciclo antes de cada hint
  sería un mal tradeoff para una pista que nunca decide nada.

- **Governor con servidor genuinamente ocioso** (`01-batchU2-...txt`): el
  primer intento (`batchU`) quedó contaminado por mi propio setup — generar
  15 GiB con `/dev/urandom` justo antes de arrancar el job creó presión real
  que el baseline capturó (`load=1.87`, `estado=PRESSURE`), disparando
  throttle y hasta una pausa protectiva real, en vez de medir un servidor
  ocioso. Corregido generando los archivos con `/dev/zero` y esperando
  explícitamente a que `load1` bajara de 0.5 antes de arrancar. Con esa
  metodología: baseline `HEALTHY` (load=0.44, disco=0%), el BW subió limpio
  en 4 pasos hasta **exactamente 80.0M** (`--bw-max`), 0 eventos `THROTTLE`.

- **ACL POSIX no trivial, xattr y `atime=on` real** (`02-batchV-...txt`),
  usando `zrw-lab-dataset.sh` (creado y verificado en la sesión anterior):
  dataset descartable `toolbox/zrw-lab` con `acltype=posix atime=on`. Un ACL
  no trivial (`setfacl -m u:truenas_admin:rwx`, `-m g:libvirt-qemu:r--`)
  quedó idéntico antes/después; un xattr fijado a mano quedó idéntico; y se
  confirmó primero que este dataset realmente tiene `atime=on` en efecto
  (leer el archivo de referencia cambió su atime), y después que el worker
  lo restauró exactamente al valor forzado (2020-01-01), pese a eso. Dataset
  destruido limpio al terminar.

## Índice

- `00-investigacion-zdb-O-causa-raiz.txt` — la investigación completa: path
  vs raíz del dataset, archivo viejo vs nuevo, medición del retraso exacto,
  y el cierre del ítem original con `dblk=1M` confirmado.
- `01-batchU2-governor-ocioso-hasta-bwmax.txt` — incluye el primer intento
  fallido (contaminado por el propio setup) documentado en el log completo
  del monitor, seguido de la corrida corregida con el resultado limpio.
- `02-batchV-acl-posix-xattr-atime-dataset-lab.txt` — ACL POSIX, xattr y
  `atime=on` cerrados usando el dataset de laboratorio descartable.

## Qué queda después de esta ronda

Del `TEST-PLAN.md` completo, solo quedan sin marcar los ítems que
explícitamente necesitan consola interactiva en vivo (secciones H parcial e
I), o una decisión/autorización del operador (reinicio real de la máquina,
llenar el pool, producción real, instalar `b3sum`, y generar carga sintética
para validar `--auto-resume` contra presión real).

---

# English

Autonomous continuation of what was still open after 4.4.0, same protocol
(space checked beforehand, everything inside a disposable directory or
dataset, deleted at the end, logs committed to the repo). Four fronts: one
of pure investigation, three closing out open items from `TEST-PLAN.md`.
`--auto-resume` against real pressure was deliberately **not** touched in
this round: that would require deliberately generating synthetic load on
the production pool, and it was left pending explicit authorization rather
than assumed.

## Result

- **Root cause of `zdb -O`, found** (`00-investigacion-...txt`): it wasn't
  the scrub or a bug. `zdb -O` reads the pool's on-disk labels, which only
  get updated on the next TXG sync cycle (`zfs_txg_timeout`, 5s by
  default). A file that was just committed is invisible to `zdb -O` for
  ~5-10s after its `sync`, even though it's already fully persisted.
  Confirmed with a staggered-delay test (fails up to +5s, always works from
  +10s on) and against a real production file from July (works perfectly,
  no wait needed — it was already old). With the correct wait, `dblk=1M`
  was confirmed on a freshly reblocked file, finally closing the original
  item from section C of the plan. No code change is required: `zfs_hint()`
  remains advisory-only by design, and waiting out that cycle before every
  hint would be a bad tradeoff for a hint that never decides anything.

- **Governor with a genuinely idle server** (`01-batchU2-...txt`): the
  first attempt (`batchU`) was contaminated by my own setup — generating 15
  GiB with `/dev/urandom` right before starting the job created real
  pressure that the baseline captured (`load=1.87`, `estado=PRESSURE`),
  triggering throttling and even a real protective pause, instead of
  measuring an idle server. Fixed by generating the files with `/dev/zero`
  and explicitly waiting for `load1` to drop below 0.5 before starting.
  With that methodology: `HEALTHY` baseline (load=0.44, disk=0%), the BW
  climbed cleanly in 4 steps up to **exactly 80.0M** (`--bw-max`), 0
  `THROTTLE` events.

- **Non-trivial POSIX ACL, xattr, and real `atime=on`**
  (`02-batchV-...txt`), using `zrw-lab-dataset.sh` (created and verified in
  the previous session): disposable dataset `toolbox/zrw-lab` with
  `acltype=posix atime=on`. A non-trivial ACL (`setfacl -m
  u:truenas_admin:rwx`, `-m g:libvirt-qemu:r--`) was identical
  before/after; a manually-set xattr was identical; and it was first
  confirmed that this dataset really does have `atime=on` in effect
  (reading the reference file changed its atime), and then that the worker
  restored it exactly to the forced value (2020-01-01) despite that.
  Dataset cleanly destroyed when done.

## Index

- `00-investigacion-zdb-O-causa-raiz.txt` — the full investigation: path
  vs. dataset root, old file vs. new file, measuring the exact delay, and
  closing out the original item with `dblk=1M` confirmed.
- `01-batchU2-governor-ocioso-hasta-bwmax.txt` — includes the first failed
  attempt (contaminated by the setup itself) documented in the full monitor
  log, followed by the corrected run with the clean result.
- `02-batchV-acl-posix-xattr-atime-dataset-lab.txt` — POSIX ACL, xattr, and
  `atime=on` closed out using the disposable lab dataset.

## What's left after this round

Of the entire `TEST-PLAN.md`, the only items left unchecked are the ones
that explicitly need a live interactive console (partial section H and
section I), or an operator decision/authorization (a real machine reboot,
filling the pool, real production, installing `b3sum`, and generating
synthetic load to validate `--auto-resume` against real pressure).
