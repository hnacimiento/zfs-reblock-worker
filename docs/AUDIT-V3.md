# Auditoría de las entregas previas

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Este documento explica en qué estado estaban los entregables anteriores (`legacy/`) y qué se corrigió para llegar a la V3.3.0. Se escribe para que quede registro de por qué la versión final no es simplemente "el último ZIP".

## Estado en que se encontró el proyecto

| Entregable | Estado real |
|---|---|
| `zfs-reblock-worker_v2.sh` | Funcional. Base conceptual correcta, con las limitaciones que motivaron el V3. |
| `zfs-reblock-worker-v3.zip` | Esqueleto: arquitectura y documentación, sin la implementación completa. |
| `zfs-reblock-worker-v3-final.zip` (V3.1) | El más completo en features, pero **el script está corrupto y no arranca**. |
| `zfs-reblock-worker-v3.2-final.zip` | Sintácticamente correcto, pero **construido sobre el esqueleto V3**, no sobre la V3.1: es una regresión. |

### La V3.1 no ejecuta

```
$ bash -n zfs-reblock-worker-v3-final/zfs-reblock-worker.sh
línea 1074: syntax error near unexpected token `)'
```

Dentro de `process_one()` hay un bloque truncado: la comprobación de espacio quedó cortada a mitad de una línea (`ILED" "$STATE_ATTEMPT" ...`) y `local hint` aparece duplicado. El archivo nunca pudo haberse ejecutado.

### La V3.2 perdió funcionalidad

La V3.2 se anunció como "endurecimiento de la V3.1", pero partió del esqueleto anterior. Comparando las funciones presentes en cada script, la V3.2 no tiene: `write_config`/`load_config`, `journal`/`transition`, `verify_acl_xattr`, `recover_interrupted_states`, `apply_profile`, `show_status`, `directory_browser`/`browser_whiptail`, `validate_options` ni `json_escape`. También desaparecieron `--refresh-inventory`, los perfiles y el soporte de `whiptail`.

## Qué se hizo para la V3.3.0

Se tomó la V3.1 como base (la más completa), se reparó, se le aplicaron los puntos de endurecimiento que la V3.2 prometía y se cerraron los pendientes que el propio diseño había dejado abiertos.

### Defectos corregidos de la V3.1

| Defecto | Consecuencia | Corrección |
|---|---|---|
| Script truncado en `process_one` | El worker no arrancaba | Bloque de comprobación de espacio reescrito |
| `BW_EFFECTIVE="${new_bps}B"` | El formato generado no lo acepta `rsync` ni lo puede releer el propio parser: tras el primer ajuste el governor quedaba congelado | El ancho de banda se maneja internamente en bytes/s y se formatea a KiB solo al invocar `rsync` |
| `read -r _ user nicev ...` sobre `/proc/stat` con `IFS=$'\n\t'` | El IFS global no incluye espacio, así que la línea nunca se separaba: `CPU_UTIL` e `IOWAIT` quedaban siempre en 0 y el health score era ciego | Lectura con `IFS=' '` explícito en array |
| El SHA-256 del temporal se calculaba **después** de restaurar los timestamps | Leer el temporal actualiza su atime; la invariante post-commit de atime fallaba en todos los archivos | Se reordenó: primero los hashes, después la restauración, después la verificación. Post-commit se vuelve a restaurar y reverificar |
| Leer el origen para hashearlo modificaba su atime sin restaurarlo | Si el archivo terminaba en `FAILED` o `STALE`, quedaba con el atime alterado | Se restaura el atime del origen inmediatamente después de leerlo |
| `recover_orphans` movía **cualquier** `.zrw-*.tmp` | Podía secuestrar el temporal de otro job en curso | Los temporales llevan el token del job; los ajenos se reportan y no se tocan |
| `[[ ! -f "$CONFIG_FILE" \|\| ! "$RESUME" ]]` | Comparación de cadena donde se quería una condición numérica | `(( ! RESUME ))` |

### Puntos de endurecimiento que la V3.2 prometía

- **Inventario snapshot atómico** — se construye en un temporal y se publica con `mv`.
- **Job ID realmente único** — fecha + nanosegundos + PID + hash de (ruta, recordsize, umbral).
- **Ownership de `.tmp` por job** — `.zrw-<token-job>-<token-archivo>.tmp`.
- **ACL/xattr con verificación reforzada y fallback** — `getfacl`/`getfattr` cuando existen; `rsync --itemize-changes` cuando no. El método efectivamente usado se registra en el resumen, y no se afirma en la documentación que rsync verifique ACL "criptográficamente".
- **Preflight completo** — cubre todos los comandos que el worker ejecuta realmente, incluidos los auxiliares (`head`, `tail`, `uniq`, `sed`).
- **Modo `--explain`** — implementado.
- **Estado coherente en cada frontera** — cubierto por el banco de integración.
- **Revisión estática del Bash completo** — `tests/test_static.sh`.

### Requisitos del diseño que faltaban en todas las entregas

- **El checkpoint no es autoridad absoluta.** Un `DONE` o `SKIPPED` solo se acepta si el archivo sigue existiendo con el tamaño e inode registrados; si no, pasa a `RECOVERED` y se reevalúa. Todas las versiones anteriores confiaban ciegamente en el estado guardado.
- **Estado `RECOVERED`**, que figuraba en el modelo de estados y no existía en el código.
- **Espacio insuficiente pausa el lote, no marca FAILED.** La decisión acordada era "pausa segura, no FAILED masivo"; la V3.1 marcaba cada archivo como fallido, convirtiendo un problema del pool en cientos de fallos falsos.
- **`--retry-stale`**, para revalidar los archivos modificados después del inventario.
- **Niveles de integridad `standard` / `strict` / `maximum`**, en vez de un único modo fijo.
- **Wizard consciente del estado**, que detecta el trabajo previo, su progreso y sus temporales huérfanos antes de ofrecer opciones.
- **Explorador con `dialog` y `fzf`** además de `whiptail`, con el informe de disponibilidad en el preflight.
- **Códigos de salida documentados.**
- **`--status` filtrable por directorio.**

### El capítulo de observabilidad, que faltaba entero

El documento dedica una sección larga a convertir la salida en "una interfaz operacional" donde de un vistazo se responda *dónde estoy, qué estoy haciendo, cuánto hice, cuánto falta, a qué velocidad, hay algún problema, qué sigue*. Estaba dado por cerrado en el diseño y no existía en ninguna entrega. Se implementó completo:

progreso por bytes además de por archivos, ETA global, velocidad media, línea de estado por etapa, últimos cinco completados, cuenta regresiva del cooldown, modo en la cabecera, contador de avisos, desglose de motivos de skip/fallo, y resumen final con estado del sistema y el comando exacto para lo pendiente.

### Control operativo que también faltaba

- Cooldown adaptativo (`COOLDOWN_MODE` del diseño).
- Condiciones de parada: `--stop-after`, `--stop-at`.
- Health check periódico del entorno ZFS durante la ejecución.
- Perfiles leídos de archivo, y opción de guardar la configuración como perfil.
- El wizard recuerda el último directorio sin seleccionarlo en silencio.

### Un problema de empaquetado

Los archivos terminaron con finales de línea CRLF durante la edición desde Windows. Un script Bash con CRLF **no arranca en Linux** (`bad interpreter: no such file or directory`). Se normalizaron a LF y se agregó una comprobación en `test_static.sh` para que no vuelva a pasar.

## Lo que se decidió NO implementar

No es una omisión: el propio documento llega a esta conclusión y conviene dejarla registrada.

- **Concurrencia / `WORKERS`.** Paralelizar contradice el objetivo del worker. Con archivos delicados, dos reescrituras simultáneas sobre el mismo pool son justamente lo que no se quiere.
- **`nice`/`ionice` bajo control del governor.** Son los airbags: que el servidor esté tranquilo ahora no garantiza que lo siga estando en treinta segundos. Se cambian a mano.

## Verificación ejecutada

A diferencia de las entregas anteriores, esta versión se ejecutó:

- `tests/test_static.sh` — 20 comprobaciones estructurales: **OK**
- `tests/test_units.sh` — 38 asserts sobre funciones puras, incluidos nombres Unix hostiles y las reglas de autoridad del governor: **OK**
- `tests/test_integration.sh` — ciclo completo (inventario, copia, SHA-256, timestamps, commit por rename, resume, hardlink, cuarentena, lock, recordsize distinto) sobre Linux con `rsync` real y ZFS simulado por stubs: **OK**

## Lo que sigue sin estar verificado

El banco de integración **simula ZFS**. No prueba, y no puede probar:

- comportamiento real de `zdb` sobre OpenZFS 2.4.3;
- ACL y xattr de ZFS reales (en el entorno de prueba `getfacl`/`getfattr` ni siquiera estaban);
- confirmación por transaction group y durabilidad real de `sync`;
- archivos de decenas o cientos de GiB;
- interrupción por corte de energía real;
- el comportamiento del governor bajo carga real del NAS.

Eso es exactamente lo que cubre [`TEST-PLAN.md`](TEST-PLAN.md), y es trabajo de laboratorio sobre el TrueNAS.

---

# English

This document explains the actual state of the previous deliverables (`legacy/`) and what was fixed to reach V3.3.0. It's written so there's a record of why the final version isn't simply "the latest ZIP."

## State in which the project was found

| Deliverable | Actual state |
|---|---|
| `zfs-reblock-worker_v2.sh` | Functional. Correct conceptual base, with the limitations that motivated V3. |
| `zfs-reblock-worker-v3.zip` | Skeleton: architecture and documentation, without the full implementation. |
| `zfs-reblock-worker-v3-final.zip` (V3.1) | The most feature-complete, but **the script is corrupted and doesn't start**. |
| `zfs-reblock-worker-v3.2-final.zip` | Syntactically correct, but **built on top of the V3 skeleton**, not on V3.1: it's a regression. |

### V3.1 doesn't run

```
$ bash -n zfs-reblock-worker-v3-final/zfs-reblock-worker.sh
línea 1074: syntax error near unexpected token `)'
```

Inside `process_one()` there's a truncated block: the space check gets cut off mid-line (`ILED" "$STATE_ATTEMPT" ...`) and `local hint` appears duplicated. The file could never have run.

### V3.2 lost functionality

V3.2 was announced as "hardening of V3.1," but it actually started from the earlier skeleton. Comparing the functions present in each script, V3.2 is missing: `write_config`/`load_config`, `journal`/`transition`, `verify_acl_xattr`, `recover_interrupted_states`, `apply_profile`, `show_status`, `directory_browser`/`browser_whiptail`, `validate_options`, and `json_escape`. Also gone: `--refresh-inventory`, profiles, and `whiptail` support.

## What was done for V3.3.0

V3.1 was taken as the base (the most complete one), repaired, the hardening points V3.2 had promised were applied, and the open items the design itself had left pending were closed.

### V3.1 defects fixed

| Defect | Consequence | Fix |
|---|---|---|
| Truncated script in `process_one` | The worker wouldn't start | Space-check block rewritten |
| `BW_EFFECTIVE="${new_bps}B"` | The generated format isn't accepted by `rsync` and can't be read back by the parser itself: after the first adjustment the governor would freeze | Bandwidth is now handled internally in bytes/s and only formatted to KiB when invoking `rsync` |
| `read -r _ user nicev ...` over `/proc/stat` with `IFS=$'\n\t'` | The global IFS doesn't include a space, so the line was never split: `CPU_UTIL` and `IOWAIT` stayed at 0 always, and the health score was blind | Read with an explicit `IFS=' '` into an array |
| The temp file's SHA-256 was computed **after** restoring timestamps | Reading the temp file updates its atime; the post-commit atime invariant failed on every file | Reordered: hashes first, restoration after, verification last. Post-commit restores and re-verifies again |
| Reading the source to hash it modified its atime without restoring it | If the file ended up `FAILED` or `STALE`, it was left with an altered atime | The source's atime is restored immediately after reading it |
| `recover_orphans` would move **any** `.zrw-*.tmp` | Could hijack the temp file of another job in progress | Temp files now carry the job's token; files from other jobs are reported and left untouched |
| `[[ ! -f "$CONFIG_FILE" \|\| ! "$RESUME" ]]` | String comparison where a numeric condition was intended | `(( ! RESUME ))` |

### Hardening points V3.2 had promised

- **Atomic inventory snapshot** — built in a temp file and published with `mv`.
- **Truly unique job ID** — date + nanoseconds + PID + hash of (path, recordsize, threshold).
- **Per-job `.tmp` ownership** — `.zrw-<job-token>-<file-token>.tmp`.
- **ACL/xattr with reinforced verification and fallback** — `getfacl`/`getfattr` when available; `rsync --itemize-changes` when not. The method actually used is recorded in the summary, and the documentation does not claim that rsync verifies ACLs "cryptographically."
- **Full preflight** — covers every command the worker actually runs, including auxiliary ones (`head`, `tail`, `uniq`, `sed`).
- **`--explain` mode** — implemented.
- **Consistent state at every boundary** — covered by the integration bench.
- **Static review of the full Bash script** — `tests/test_static.sh`.

### Design requirements missing from every delivery

- **The checkpoint is not absolute authority.** A `DONE` or `SKIPPED` is only accepted if the file still exists with the recorded size and inode; otherwise it becomes `RECOVERED` and is re-evaluated. Every prior version blindly trusted the saved state.
- **`RECOVERED` state**, which appeared in the state model and did not exist in the code.
- **Insufficient space pauses the batch, it doesn't mark FAILED.** The agreed decision was "safe pause, not mass FAILED"; V3.1 marked every file as failed, turning a pool problem into hundreds of false failures.
- **`--retry-stale`**, to revalidate files modified after the inventory was built.
- **`standard` / `strict` / `maximum` integrity levels**, instead of a single fixed mode.
- **State-aware wizard**, that detects prior work, its progress, and its orphaned temp files before offering options.
- **Browser with `dialog` and `fzf`** in addition to `whiptail`, with availability reported in the preflight.
- **Documented exit codes.**
- **`--status` filterable by directory.**

### The observability chapter, missing entirely

The design document dedicates a long section to turning the output into "an operational interface" where a single glance answers *where am I, what am I doing, how much have I done, how much is left, at what speed, is there a problem, what's next*. It was treated as settled in the design and existed in none of the deliveries. It was fully implemented:

progress by bytes in addition to by files, overall ETA, average speed, a per-stage status line, the last five completed, a cooldown countdown, the mode shown in the header, a warnings counter, a breakdown of skip/failure reasons, and a final summary with system status and the exact command for what's left pending.

### Operational control that was also missing

- Adaptive cooldown (the design's `COOLDOWN_MODE`).
- Stop conditions: `--stop-after`, `--stop-at`.
- Periodic health check of the ZFS environment during execution.
- Profiles read from file, and an option to save the current configuration as a profile.
- The wizard remembers the last directory without silently pre-selecting it.

### A packaging problem

The files ended up with CRLF line endings during editing from Windows. A Bash script with CRLF **doesn't start on Linux** (`bad interpreter: no such file or directory`). They were normalized to LF, and a check was added to `test_static.sh` so this doesn't happen again.

## What was decided NOT to implement

This isn't an omission: the design document itself reaches this conclusion, and it's worth recording.

- **Concurrency / `WORKERS`.** Parallelizing contradicts the worker's goal. With sensitive files, two simultaneous rewrites on the same pool are exactly what's not wanted.
- **`nice`/`ionice` under governor control.** They're the airbags: the server being quiet right now doesn't guarantee it will still be quiet in thirty seconds. They're changed by hand.

## Verification performed

Unlike prior deliveries, this version was actually run:

- `tests/test_static.sh` — 20 structural checks: **OK**
- `tests/test_units.sh` — 38 asserts over pure functions, including hostile Unix filenames and the governor's authority rules: **OK**
- `tests/test_integration.sh` — full cycle (inventory, copy, SHA-256, timestamps, commit via rename, resume, hardlink, quarantine, lock, different recordsize) on Linux with real `rsync` and ZFS simulated via stubs: **OK**

## What still isn't verified

The integration bench **simulates ZFS**. It doesn't test, and can't test:

- real behavior of `zdb` on OpenZFS 2.4.3;
- real ZFS ACLs and xattrs (in the test environment, `getfacl`/`getfattr` weren't even present);
- transaction-group confirmation and real `sync` durability;
- files of tens or hundreds of GiB;
- interruption by a real power outage;
- the governor's behavior under the NAS's real load.

That's exactly what [`TEST-PLAN.md`](TEST-PLAN.md) covers, and it's lab work on the TrueNAS.
