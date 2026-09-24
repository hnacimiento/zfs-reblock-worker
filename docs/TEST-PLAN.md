# Plan de pruebas

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Este paquete **no** afirma que estas pruebas se hayan ejecutado sobre su TrueNAS. Los bancos automáticos de `tests/` sí se ejecutaron y pasan, pero simulan ZFS con stubs: no prueban ZFS real. Ejecute este plan antes de apuntar el worker a producción.

## Preparación del laboratorio

Cree un dataset de pruebas con el mismo recordsize que el dataset objetivo, y un árbol de archivos pequeños (unos pocos MiB alcanzan para casi todo). Baje el umbral con `--threshold 1M` para que los archivos chicos entren al inventario.

```bash
zfs create -o recordsize=1M toolbox/reblock-lab
mkdir -p /mnt/toolbox/reblock-lab/tree
```

Para cada prueba, capture antes y después: `sha256sum`, `stat -c '%s %i %x %y %a %u %g %h'`, `getfacl` y `getfattr -d -m -`.

---

## A. Estático

- [x] `bash tests/test_static.sh`
- [x] `bash tests/test_units.sh`
- [x] `bash tests/test_integration.sh`
- [x] `shellcheck zfs-reblock-worker.sh` (opcional) — cubierto por `tests/test_static.sh` ("shellcheck sin warnings"), corrido en cada ronda desde la 2

## B. Preflight y entorno

- [x] `--check` lista todos los comandos y termina en `READY`
- [x] `--check` ejecutado como usuario no root falla (código real: `10`/`EX_NOT_ROOT`, no `2` como decía este plan — corregido)
- [x] Renombrar temporalmente `ionice` fuera del PATH: el worker continúa y **avisa** en el log
- [x] Renombrar temporalmente `rsync`: el worker se detiene, no improvisa
- [x] `--explain` sobre un archivo grande y sobre uno por debajo del umbral

## C. Funcional básico

- [x] `--dry-run`: no crea `jobs/`, no modifica nada, lista candidatos y estimación
- [x] Corrida completa sobre el árbol de laboratorio
- [x] El inode de cada archivo procesado **cambió** (hubo rename)
- [x] `zdb` reporta bloques de 1M después del reblock — causa raíz encontrada
      (ronda 9): no era el scrub ni un bug. `zdb -O` lee las etiquetas del pool
      en disco, que solo se actualizan en el siguiente ciclo de sincronización
      de TXG (`zfs_txg_timeout`, 5s por defecto); un archivo recién comprometido
      no es visible para `zdb -O` hasta ~5-10s después de su `sync`, aunque
      `sync` ya haya retornado. Confirmado con una prueba de retraso escalonado
      (0/2/5/10/20/40s): falla hasta el segundo 5, funciona desde el segundo
      10 en adelante, siempre. Con esa espera, `zdb -O` confirma `dblk=1M`
      sobre un archivo real recién reescrito. `zfs_hint()` sigue siendo
      advisory-only por diseño — no necesita ni debe esperar este ciclo, ya
      que nunca decide nada por su cuenta — pero el ítem del plan, para
      inspección manual del operador, ya queda cerrado: esperar ~10s después
      del commit antes de invocar `zdb -O` a mano.
- [x] Un archivo por debajo del umbral no fue tocado
- [x] `--status` refleja el progreso correctamente

## D. Integridad

- [x] SHA-256 idéntico antes y después, para todos los archivos
- [x] Modificar el origen **durante** la copia (`dd` sobre el archivo mientras corre) → `STALE`, original no reemplazado
- [x] Corromper el temporal antes de la verificación → no hay commit, queda `FAILED` (ronda 7)
- [x] `--integrity standard` es notablemente más rápido y sigue verificando tamaño
- [x] `--integrity maximum` relee el archivo después del commit
- [x] **`--hash b3` (BLAKE3) contra un `b3sum` real** — ronda 14, con `b3sum`
      ya instalado en el NAS: `--dry-run --dry-sample 1 --hash b3` sobre un
      archivo real de 2.19 GiB (`Musicales/.../....ratDVD`) terminó sin
      errores, con throughput real medido (2.19 GiB/s). Formato de salida de
      `b3sum` confirmado manualmente: `<hash>  <ruta>` (dos espacios), idéntico
      al de `sha256sum`/`b2sum` — el mismo `awk '{print $1}'` de `hash_of()`
      lo parsea sin cambios.

## E. Metadatos

- [x] `atime` preservado (probar con `atime=on` en el dataset) — ronda 9,
      dataset de laboratorio descartable (`zrw-lab-dataset.sh`, `atime=on`
      real): confirmado que leer el archivo SÍ cambia el atime en este
      dataset (2020-01-01 → fecha real, como se espera con `atime=on`), y que
      el worker lo restaura exactamente al valor original pese a eso.
- [x] `mtime` preservado
- [x] `mode` preservado
- [x] `UID` / `GID` preservados (probado con un archivo de otro usuario real, ronda 7)
- [x] ACL preservada, `acltype=posix` — fijar una ACL no trivial con `setfacl` y comparar con `getfacl` (ronda 9, dataset de laboratorio: `user:950:rwx`, `group:986:r--` idénticos antes/después)
- [x] ACL preservada, `acltype=nfsv4` — fijar una ACE con `nfs4xdr_setfacl` y comparar con
      `nfs4xdr_getfacl -j | jq -S -c 'del(.path,.fhandle)'`. **`fhandle` debe diferir**: el archivo
      reescrito es un inode nuevo. Si no difiere, algo no se reescribió.
- [x] xattr preservados — fijar uno con `setfattr` y comparar
- [x] Dataset `acltype=nfsv4` **sin `nfs4xdr_getfacl` instalado**: sus archivos deben quedar
      fuera del inventario, con el nombre de la herramienta que falta, y **sin tocarse** — ronda 14,
      PATH sombra real ocultando `nfs4xdr_getfacl`+`jq` (sin tocar los binarios reales, de solo
      lectura), `--dry-run` sobre `/mnt/toolbox` real: `toolbox/media` (el único dataset con
      recordsize=1M del árbol) quedó `OMITE (faltan nfs4xdr_getfacl y/o jq)`, con el nombre exacto
      de la herramienta faltante en el log, sin tocar ningún archivo.
- [x] Árbol entero sin verificador disponible: salida `20` antes de copiar nada — ronda 14, dataset
      de laboratorio descartable (`toolbox/zrw-lab`, `acltype=posix`), PATH sombra ocultando
      `getfacl`+`getfattr`, intento de job real: murió con código `20` exacto, `jobs/` sin ninguna
      carpeta nueva y el dataset de laboratorio vacío — cero archivos tocados.

## F. Casos límite de nombres y archivos

- [x] espacios
- [x] tabs
- [x] comillas simples y dobles
- [x] `$`, backticks, `!` (ronda 8)
- [x] **salto de línea dentro del nombre**
- [x] caracteres UTF-8 y emoji
- [x] basename de más de 200 caracteres
- [x] hardlink → `SKIPPED`, `nlink` intacto, enlace no roto (ronda 7)
- [x] archivo sparse → el tamaño asignado (`du`) no crece
- [x] archivo de solo lectura
- [x] directorios anidados profundos (ronda 7)

## G. Recuperación

- [x] `kill -9` al worker durante una copia → reanudar: sin `EX_LOCKED`, SHA-256 idéntico, sin temporales huérfanos (ronda 4)
- [x] **Reinicio real de la máquina** durante una copia → reanudar y verificar (ronda 12,
      autorizado explícitamente): reinicio real disparado a mitad de una copia de 6 GiB, el pool
      volvió a importar sin errores,
      `PROCESSING` volvió a `PENDING` como documenta el contrato, `--resume` reescribió el archivo
      completo con hash idéntico. **Encontró un bug real**: el archivo parcial de rsync (con su
      sufijo aleatorio, antes de que rsync lo renombre a la forma final `.tmp`) no coincidía con el
      glob de `recover_temps()`, así que quedaba en el árbol para siempre — `--status` lo contaba
      pero la recuperación automática nunca lo tocaba ni lo ponía en cuarentena. Corregido en 4.4.1.
- [x] `PROCESSING` forzado a mano en un `.state` → vuelve a `PENDING`
- [x] Temporal `.zrw-` de otro job presente → **no se toca en absoluto** (no va a cuarentena; la
      cuarentena es solo para huérfanos del mismo job — corregido el entendimiento de este ítem
      en la ronda 7, el texto original de este plan podía leerse como ambiguo)
- [x] Marcar un archivo como `DONE` a mano y luego modificarlo → `RECOVERED` y reevaluación (ronda 7)
- [x] Dos workers sobre el mismo job → el segundo avisa y sale, sin matar al primero
- [x] Pausa segura por espacio, sin `FAILED` masivo; liberar espacio y reanudar — ronda 15,
      **sin llenar el pool real** (prohibido de forma permanente): dataset de laboratorio
      descartable con `quota=1200M`, un candidato real de 10 MiB y ~250 MiB de relleno para bajar
      el espacio libre por debajo del margen mínimo (1 GiB, fijo). El job paró con código `13`
      exacto y `[ERROR] ... espacio insuficiente; lote pausado`, el candidato quedó `PENDING` (no
      `FAILED`, no tocado — hash idéntico). Liberado el relleno, `--resume` completó el candidato
      con `DONE`/`commit verificado`, mismo hash, `failed=0` en el resumen final.

## H. Governor

- [x] `--adaptive off`: el BW no se mueve nunca
- [x] Servidor ocioso con `auto`: el BW sube gradualmente hasta `--bw-max` (ronda 9,
      con el scrub ya terminado y el sistema genuinamente asentado — load1 < 0.5
      confirmado antes de arrancar: baseline `HEALTHY`, 4 eventos `INCREASE`
      limpios, 0 `THROTTLE`, BW final exactamente 80.0M = `--bw-max`).
- [x] Generar carga de I/O (`fio`, un `scrub`, una copia grande): el BW baja
- [x] `guarded`: baja pero nunca sube (ronda 7: 0 eventos `INCREASE` en toda la corrida, bajo presión crítica real)
- [x] Presión crítica sostenida: pausa protectiva confirmada (rondas 6 y 7). Por defecto el worker
      sale con código 13 y queda esperando un `--resume` manual — eso no cambió y sigue siendo el
      comportamiento por defecto. La "reanudación automática al liberar" que describe este ítem
      ahora existe como opt-in: `--auto-resume` (4.3.0) espera dentro del mismo proceso y retoma
      solo cuando la salud se recupera, acotado por `--pause-timeout`. Validado con 5 tests
      unitarios deterministas, y **confirmado contra presión real** (ronda 10, carga sintética
      con `fio` autorizada explícitamente): pausó a los 35s de presión `EMERGENCY` real, quedó
      vivo esperando (no salió con
      13), y reanudó solo 40s-3m19s después de cortar la carga en cada uno de los dos archivos de
      la corrida — código de salida final 0, `--resume` nunca invocado. Integridad verificada
      (SHA-256 idéntico en ambos archivos).
- [x] `[C] → 1` bajar el BW a 20M, luego dejar el servidor ocioso: **AUTO no debe volver a subirlo**
      (ronda de consola en vivo: subió hasta exactamente 20.0M y se detuvo ahí, con presión real
      oscilando alrededor — nunca lo cruzó)
- [x] Con el techo manual puesto y bajo presión: AUTO **sí** debe poder bajar de 20M (confirmado con
      presión real, sin necesidad de generarla a propósito: `THROTTLE 20.0M -> 16.0M`)
- [x] `[C] → a`: AUTO recupera la autoridad y vuelve a subir (confirmado: subió libre hasta 47.8M,
      muy por encima del viejo techo, antes de volver a pausarse por presión real sostenida)
- [x] Todos estos cambios quedan registrados en `journal.tsv`

## I. Controles e interfaz

- [x] `P` pausa después del archivo actual, no a mitad de copia (confirmado en vivo: el archivo en
      curso terminó y verificó normal antes de `JOB PAUSADO`)
- [x] `Q` termina de forma segura y deja el job reanudable (confirmado en vivo, dos veces: la
      primera vez no registró por timing, la segunda sí — `[OPERATOR] Salida segura solicitada`,
      archivo en curso terminado, estado consistente para `--resume`)
- [x] `C` cambia BW, nice, ionice y cooldown en caliente (confirmado en vivo con `/proc` real: el
      archivo ya en copia no cambió de velocidad/nice/ionice; el siguiente sí)
- [x] `recordsize` y `threshold` cambiados desde `C` **no** afectan al job en curso (confirmado en
      vivo — y encontró un bug real en el camino, ver abajo)
- [x] Wizard sin argumentos detecta el job previo y su progreso (confirmado en vivo: "TRABAJO
      COMPLETO", estadísticas correctas, opciones sensatas)
- [x] Explorador con `whiptail`; luego con `whiptail` fuera del PATH, cae al selector Bash
      (confirmado en vivo ambos casos — el segundo con un PATH sombra, ya que `/usr/bin` en
      TrueNAS SCALE es de solo lectura y no se puede mover el binario real)
- [x] Salida redirigida a un archivo: sin códigos ANSI (ronda 7: 0 ocurrencias de ESC), sin prompts (confirmado con argumentos completos, nunca pregunta)

## J. Producción

Solo después de que todo lo anterior pase:

- [x] Un subdirectorio real acotado, con `--adaptive guarded` (ronda 11:
      `Musicales`, 14.33 GiB, 199 archivos — 1 candidato real por umbral,
      reescrito con 0 fallos)
- [x] Verificar una muestra de archivos: hash, metadatos, `zdb` (ronda 11:
      199/199 verificados tamaño/mtime/hash; el candidato reescrito
      confirmado con `stat`, ACL NFSv4 completa y `zdb -O` mostrando
      `dblk=1M`)
- [x] Observar el impacto real sobre los servicios del NAS (ronda 11: load
      dentro de rango normal durante toda la corrida, sin degradación
      observable)
- [x] Un subdirectorio grande, corrida larga real, sin supervisión activa (ronda 16:
      `Videos/Series`, 2.1 TiB / 238 archivos — ~17% de `toolbox/media` (12 TiB
      totales). 238/238 procesados, 0 fallos, 0 stale. Sobrevivió un reinicio
      real de la máquina a mitad de camino (217/238) sin perder nada. Cinco
      bugs reales encontrados y corregidos en el camino (4.4.8-4.4.12, ver
      `CHANGELOG.md`) — ninguno de integridad, todos en la capa de gobernanza
      o de resume/config.
- [ ] Recién entonces, el dataset completo — `Musicales` + `Series` ya están
      hechos (~2.1 TiB de los ~12 TiB de `toolbox/media`); queda pendiente de
      decisión del operador si sigue con otro subdirectorio acotado o con el
      resto del dataset de una sola vez.

---

## Qué reportar si algo falla

Para cada fallo, guarde: la sección de `events.log` correspondiente, las líneas de `journal.tsv` de ese archivo, el `summary.json`, y el `stat`/`sha256sum` del archivo antes y después. El motivo del fallo está siempre en la columna `result` del journal.

---

# English

This package does **not** claim these tests have been run against your TrueNAS. The automated benches in `tests/` were run and do pass, but they simulate ZFS with stubs: they don't test real ZFS. Run this plan before pointing the worker at production.

## Lab setup

Create a test dataset with the same recordsize as the target dataset, and a tree of small files (a few MiB is enough for almost everything). Lower the threshold with `--threshold 1M` so small files enter the inventory.

```bash
zfs create -o recordsize=1M toolbox/reblock-lab
mkdir -p /mnt/toolbox/reblock-lab/tree
```

For each test, capture before and after: `sha256sum`, `stat -c '%s %i %x %y %a %u %g %h'`, `getfacl`, and `getfattr -d -m -`.

---

## A. Static

- [x] `bash tests/test_static.sh`
- [x] `bash tests/test_units.sh`
- [x] `bash tests/test_integration.sh`
- [x] `shellcheck zfs-reblock-worker.sh` (optional) — covered by `tests/test_static.sh` ("shellcheck with no warnings"), run in every round since round 2

## B. Preflight and environment

- [x] `--check` lists every command and ends in `READY`
- [x] `--check` run as a non-root user fails (actual code: `10`/`EX_NOT_ROOT`, not `2` as this plan previously said — corrected)
- [x] Temporarily rename `ionice` out of the PATH: the worker continues and **warns** in the log
- [x] Temporarily rename `rsync`: the worker stops, it doesn't improvise
- [x] `--explain` on a large file and on one below the threshold

## C. Basic functionality

- [x] `--dry-run`: doesn't create `jobs/`, doesn't modify anything, lists candidates and an estimate
- [x] Full run over the lab tree
- [x] Every processed file's inode **changed** (a rename occurred)
- [x] `zdb` reports 1M blocks after the reblock — root cause found (round 9):
      it wasn't the scrub, and it wasn't a bug. `zdb -O` reads the pool's
      on-disk labels, which only update on the next TXG sync cycle
      (`zfs_txg_timeout`, 5s by default); a freshly committed file isn't
      visible to `zdb -O` until ~5-10s after its `sync`, even though `sync`
      has already returned. Confirmed with a staggered-delay test
      (0/2/5/10/20/40s): fails through second 5, works from second 10
      onward, always. With that wait, `zdb -O` confirms `dblk=1M` on a real,
      freshly rewritten file. `zfs_hint()` remains advisory-only by design —
      it doesn't need to, and shouldn't, wait out this cycle, since it never
      decides anything on its own — but the plan item, for the operator's
      manual inspection, is now closed: wait ~10s after the commit before
      invoking `zdb -O` by hand.
- [x] A file below the threshold was not touched
- [x] `--status` reflects progress correctly

## D. Integrity

- [x] SHA-256 identical before and after, for every file
- [x] Modify the source **during** the copy (`dd` on the file while it's running) → `STALE`, original not replaced
- [x] Corrupt the temp file before verification → no commit happens, it stays `FAILED` (round 7)
- [x] `--integrity standard` is noticeably faster and still verifies size
- [x] `--integrity maximum` re-reads the file after the commit
- [x] **`--hash b3` (BLAKE3) against a real `b3sum`** — round 14, with `b3sum`
      already installed on the NAS: `--dry-run --dry-sample 1 --hash b3` on a
      real 2.19 GiB file (`Musicales/.../....ratDVD`) finished with no
      errors, with real measured throughput (2.19 GiB/s). `b3sum`'s output
      format manually confirmed: `<hash>  <path>` (two spaces), identical to
      `sha256sum`/`b2sum`'s — the same `awk '{print $1}'` in `hash_of()`
      parses it unchanged.

## E. Metadata

- [x] `atime` preserved (tested with `atime=on` on the dataset) — round 9,
      disposable lab dataset (`zrw-lab-dataset.sh`, real `atime=on`):
      confirmed that reading the file DOES change its atime on this dataset
      (2020-01-01 → real date, as expected with `atime=on`), and that the
      worker restores it to exactly the original value despite that.
- [x] `mtime` preserved
- [x] `mode` preserved
- [x] `UID` / `GID` preserved (tested with a file owned by a different real user, round 7)
- [x] ACL preserved, `acltype=posix` — set a non-trivial ACL with `setfacl` and compare with `getfacl` (round 9, lab dataset: `user:950:rwx`, `group:986:r--` identical before/after)
- [x] ACL preserved, `acltype=nfsv4` — set an ACE with `nfs4xdr_setfacl` and compare with
      `nfs4xdr_getfacl -j | jq -S -c 'del(.path,.fhandle)'`. **`fhandle` must differ**: the rewritten
      file is a new inode. If it doesn't differ, something wasn't rewritten.
- [x] xattrs preserved — set one with `setfattr` and compare
- [x] `acltype=nfsv4` dataset **without `nfs4xdr_getfacl` installed**: its files must be left out of
      the inventory, with the name of the missing tool, and **left untouched** — round 14, real
      shadow PATH hiding `nfs4xdr_getfacl`+`jq` (without touching the real, read-only binaries),
      `--dry-run` against the real `/mnt/toolbox`: `toolbox/media` (the only recordsize=1M dataset
      in the tree) ended up `OMITE (faltan nfs4xdr_getfacl y/o jq)`, with the exact name of the
      missing tool in the log, no file touched.
- [x] Entire tree with no verifier available: exits with `20` before copying anything — round 14,
      disposable lab dataset (`toolbox/zrw-lab`, `acltype=posix`), shadow PATH hiding
      `getfacl`+`getfattr`, real job attempt: died with exactly code `20`, no new folder under
      `jobs/`, and the lab dataset empty — zero files touched.

## F. Filename and file edge cases

- [x] spaces
- [x] tabs
- [x] single and double quotes
- [x] `$`, backticks, `!` (round 8)
- [x] **newline inside the name**
- [x] UTF-8 characters and emoji
- [x] basename longer than 200 characters
- [x] hardlink → `SKIPPED`, `nlink` intact, link not broken (round 7)
- [x] sparse file → allocated size (`du`) doesn't grow
- [x] read-only file
- [x] deeply nested directories (round 7)

## G. Recovery

- [x] `kill -9` on the worker during a copy → resume: no `EX_LOCKED`, identical SHA-256, no orphaned temp files (round 4)
- [x] **Real machine reboot** during a copy → resume and verify (round 12,
      explicitly authorized): a real reboot triggered mid-copy on a 6 GiB file, the pool
      re-imported with no errors, `PROCESSING` went back to
      `PENDING` as the contract documents, `--resume` rewrote the entire file with an identical
      hash. **Found a real bug**: rsync's partial file (with its random suffix, before rsync
      renames it to the final `.tmp` form) didn't match `recover_temps()`'s glob, so it stayed in
      the tree forever — `--status` counted it, but automatic recovery never touched it or
      quarantined it. Fixed in 4.4.1.
- [x] `PROCESSING` manually forced in a `.state` file → reverts to `PENDING`
- [x] A `.zrw-` temp file from another job present → **not touched at all** (doesn't go to
      quarantine; quarantine is only for orphans of the same job — the understanding of this item
      was corrected in round 7, the plan's original wording could be read as ambiguous)
- [x] Manually mark a file `DONE` and then modify it → `RECOVERED` and re-evaluation (round 7)
- [x] Two workers on the same job → the second reports and exits, without killing the first
- [x] Safe pause due to space, no mass `FAILED`; free space and resume — round 15, **without
      filling the real pool** (permanently prohibited): a disposable lab dataset with
      `quota=1200M`, one real 10 MiB candidate, and ~250 MiB of filler to bring free space below
      the minimum margin (1 GiB, fixed). The job stopped with exactly code `13` and
      `[ERROR] ... espacio insuficiente; lote pausado`, the candidate stayed `PENDING` (not
      `FAILED`, untouched — identical hash). Once the filler was freed, `--resume` completed the
      candidate with `DONE`/verified commit, the same hash, `failed=0` in the final summary.

## H. Governor

- [x] `--adaptive off`: BW never moves
- [x] Idle server with `auto`: BW gradually rises to `--bw-max` (round 9, with
      the scrub already finished and the system genuinely settled — load1 <
      0.5 confirmed before starting: `HEALTHY` baseline, 4 clean `INCREASE`
      events, 0 `THROTTLE`, final BW exactly 80.0M = `--bw-max`).
- [x] Generate I/O load (`fio`, a `scrub`, a large copy): BW drops
- [x] `guarded`: drops but never rises (round 7: 0 `INCREASE` events across the whole run, under real critical pressure)
- [x] Sustained critical pressure: protective pause confirmed (rounds 6 and 7). By default the
      worker exits with code 13 and waits for a manual `--resume` — that hasn't changed and
      remains the default behavior. The "automatic resume once released" this item describes now
      exists as opt-in: `--auto-resume` (4.3.0) waits within the same process and resumes on its
      own once health recovers, bounded by `--pause-timeout`. Validated with 5 deterministic unit
      tests, and **confirmed against real pressure** (round 10, synthetic load with `fio`,
      explicitly authorized): paused 35s into real `EMERGENCY` pressure, stayed alive waiting (didn't exit with 13), and resumed
      on its own 40s-3m19s after the load was cut, on each of the two files in the run — final
      exit code 0, `--resume` never invoked. Integrity verified (identical SHA-256 on both files).
- [x] `[C] → 1` lower BW to 20M, then leave the server idle: **AUTO must not raise it again**
      (live-console round: it rose to exactly 20.0M and stopped there, with real pressure
      oscillating around it — never crossed it)
- [x] With the manual ceiling set and under pressure: AUTO **must** still be able to drop below
      20M (confirmed under real pressure, with no need to generate it on purpose:
      `THROTTLE 20.0M -> 16.0M`)
- [x] `[C] → a`: AUTO regains authority and rises again (confirmed: rose freely up to 47.8M, well
      above the old ceiling, before pausing again due to sustained real pressure)
- [x] All of these changes are recorded in `journal.tsv`

## I. Controls and interface

- [x] `P` pauses after the current file, not mid-copy (confirmed live: the file in progress
      finished and verified normally before `JOB PAUSADO`)
- [x] `Q` ends safely and leaves the job resumable (confirmed live, twice: the first time it
      wasn't recorded due to timing, the second time it was — `[OPERATOR] Salida segura
      solicitada`, file in progress finished, consistent state for `--resume`)
- [x] `C` changes BW, nice, ionice, and cooldown live (confirmed live with real `/proc`: the file
      already being copied didn't change speed/nice/ionice; the next one did)
- [x] `recordsize` and `threshold` changed from `C` do **not** affect the current job (confirmed
      live — and found a real bug along the way, see below)
- [x] Wizard with no arguments detects the previous job and its progress (confirmed live: "TRABAJO
      COMPLETO", correct statistics, sensible options)
- [x] Browser with `whiptail`; then with `whiptail` out of the PATH, falls back to the Bash
      selector (confirmed live in both cases — the second one with a shadow PATH, since
      `/usr/bin` on TrueNAS SCALE is read-only and the real binary can't be moved)
- [x] Output redirected to a file: no ANSI codes (round 7: 0 occurrences of ESC), no prompts (confirmed with full arguments, never asks)

## J. Production

Only after everything above passes:

- [x] A real, bounded subdirectory, with `--adaptive guarded` (round 11:
      `Musicales`, 14.33 GiB, 199 files — 1 real candidate by threshold,
      rewritten with 0 failures)
- [x] Verify a sample of files: hash, metadata, `zdb` (round 11: 199/199
      verified for size/mtime/hash; the rewritten candidate confirmed with
      `stat`, full NFSv4 ACL, and `zdb -O` showing `dblk=1M`)
- [x] Observe the real impact on the NAS's services (round 11: load within
      normal range throughout the run, no observable degradation)
- [x] A large subdirectory, a real long run, without active supervision (round 16:
      `Videos/Series`, 2.1 TiB / 238 files — ~17% of `toolbox/media` (12 TiB
      total). 238/238 processed, 0 failures, 0 stale. Survived a real machine
      reboot mid-way (217/238) without losing anything. Five real bugs found
      and fixed along the way (4.4.8-4.4.12, see `CHANGELOG.md`) — none of
      them integrity bugs, all in the governance layer or the resume/config
      layer.
- [ ] Only then, the full dataset — `Musicales` + `Series` are already done
      (~2.1 TiB of `toolbox/media`'s ~12 TiB); it remains a decision for the
      operator whether to continue with another bounded subdirectory or with
      the rest of the dataset in one go.

---

## What to report if something fails

For each failure, save: the corresponding section of `events.log`, that file's lines in `journal.tsv`, `summary.json`, and the file's `stat`/`sha256sum` before and after. The failure reason is always in the journal's `result` column.
