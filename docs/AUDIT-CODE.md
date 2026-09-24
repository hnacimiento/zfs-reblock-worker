# Auditoría de código: legacy consolidado vs. v4.0.0

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Comparación **a nivel de código**, no de features. "Legacy consolidado" significa lo mejor que aparece en cualquiera de las seis versiones previas (`v2`, `v3`, `v3.1`, `v3.2`, `v3.3`, `v3.4`), como si pudieran fusionarse. Cada fila dice qué se rescató, qué se corrigió y qué se descartó.

Estado de arranque de cada legacy, verificado ejecutándolos:

| Versión | Líneas | `bash -n` | ¿Procesa un archivo? |
|---|---:|---|---|
| v2 | 187 | pasa | sí |
| v3 | 1.154 | pasa | esqueleto, no |
| v3.1 | 1.294 | **falla** (línea 1074) | no |
| v3.2 | 1.183 | pasa | no (regresión de base) |
| v3.3 | 1.422 | pasa | **no** — `orig_sha: unbound variable`, línea 952 |
| v3.4 | 1.497 | pasa | **no** — mismo defecto, línea 996 |

---

## 1. Estructura y legibilidad

| Aspecto | Legacy consolidado | v4.0.0 |
|---|---|---|
| Organización | Secciones por comentario, sin índice; el lector descubre el orden leyendo | 20 secciones numeradas con un índice en la cabecera; cada una es una preocupación |
| Comentarios | Mezcla de español e inglés; muchos describen *qué* hace la línea | Todos en inglés; explican *por qué*, no *qué*. Comprobado por el test estático |
| Longitud | 1.497 (v3.4) para menos funcionalidad | 2.154 con paralelismo, diskstats, rollback, modos de salida y `--explain` |
| Helpers | Repetición de `stat -c` uno por campo (6 llamadas por archivo) | `snapshot_file` hace un solo `stat -c '%s %i %a %u %g %h'` |
| Parseo de CLI | Un `case` con la validación dispersa entre ramas | Ramas de opción con valor agrupadas; toda la validación en `validate()` |
| Salida | `printf` sueltos en cada sitio | `say/raw/log/err/warn` con `UI_MODE` como única proyección |
| Nombres | `CURRENT_*`, `STATE_*`, `FILE_*`, `DEFAULT_*` largos y repetidos | `CUR_*`, `ST_*`, `F_*`, `D_*` cortos y consistentes |
| Constantes | Variables normales, sobrescribibles por accidente | `readonly` para defaults y exit codes |

## 2. Corrección del núcleo

| Aspecto | Legacy consolidado | v4.0.0 |
|---|---|---|
| `set -e` | v2 lo usa: un rsync fallido aborta el lote entero | `set -uo pipefail` sin `-e`; un archivo que falla se registra y el lote sigue |
| Variables sin inicializar | `local hint orig_sha` + `[[ -z "$orig_sha" ]]` con `set -u` → **aborta en el primer archivo** (v3.3/v3.4) | Toda variable se inicializa; `src_sha=""` explícito |
| Lectura de `/proc/stat` | `read` con `IFS=$'\n\t'` global → campos vacíos → CPU e IOWAIT siempre 0 | `IFS=' ' read -r -a` local; verificado con un test |
| Formato del bwlimit | `"${bps}B"` — ni rsync lo acepta ni el parser lo relee → governor congelado (v3.1) | `bw_rate()` normaliza a KiB; test de ida y vuelta |
| Orden hash/timestamps | Hash del temporal **después** de restaurar → la invariante de atime falla siempre (v3.1) | Hash primero, restauración después, verificación al final. Igual post-commit |
| atime del origen | Se lee para hashear y no se restaura: un FAILED deja el original alterado | `touch -a` inmediatamente después de cada lectura del origen |
| `mv` del estado | `mv` de un `.tmp` que nunca se creó cuando el estado está vacío (v3.3/v3.4) | `save_state` siempre escribe antes de renombrar |
| `trap` | Ausente en v3, v3.2, v3.3, v3.4 | `trap cleanup EXIT INT TERM` y `trap '' HUP` |

## 3. Integridad y frontera de commit

| Aspecto | Legacy consolidado | v4.0.0 |
|---|---|---|
| Verificación pre-commit | v2: solo tamaño. v3.1+: SHA-256 + metadatos | SHA-256 + mode/uid/gid + timestamps + ACL/xattr + identidad, en ese orden |
| Re-hash del origen tras copiar | **v3.3/v3.4**: detecta cambios que preservan tamaño y mtime | Adoptado, y clasificado `STALE` (no `FAILED`): quien escribía el archivo no es un fallo del worker |
| Ancla de rollback | **v3.4**: hardlink al inode original, coste de espacio cero | Adoptado. `make_anchor` escribe primero un registro sidecar, después enlaza |
| Rollback post-commit | v3.4: cuarentena del reemplazo + restauración del original | Adoptado, más restauración de timestamps y `sync` |
| ACL/xattr post-commit | v3.4: compara contra el ancla (metadatos originales) | Adoptado |
| Verificación ACL/xattr | v3.4: solo `rsync --itemize-changes` | `getfacl`/`getfattr` cuando existen, `rsync` como fallback; el método usado va al resumen — **superado en 4.2.0**, ver abajo |
| Parseo de `zdb` | v3.1: coincidencia textual amplia. v3.4: exige campo `lsize` | Criterio de v3.4 adoptado **sin su consecuencia**: el hint nunca produce SKIP — **`lsize` resultó ser el campo equivocado**, ver abajo |
| Recuperación del ancla | **No existe** en v3.4: `recover_orphans` solo busca `.tmp` | `recover_anchors` compara inodes: si el commit no ocurrió borra el ancla; si ocurrió sin verificar, completa el rollback |

### El defecto que esto corrige

En v3.4 un corte de energía entre `ln` y `mv` deja el ancla huérfana. El original queda con `nlink=2`, y en la corrida siguiente el propio worker lo clasifica como hardlink y lo marca `SKIPPED` — un estado terminal que ni `--retry-failed` revisita. El archivo queda inprocesable, en silencio, para siempre. El banco de integración de v4 reproduce ese escenario exacto y comprueba que el archivo vuelve a `nlink=1`, intacto y procesable.

## 4. Estado y durabilidad

| Aspecto | Legacy consolidado | v4.0.0 |
|---|---|---|
| Formato | v3.2/v3.3: un TSV compartido, reescrito entero en cada transición | Un archivo por candidato: escrituras independientes, aptas para paralelismo |
| Durabilidad | **v3.3/v3.4**: `sync -f` sobre estado y journal | Adoptado en `save_state` y `journal` |
| PENDING inicial | **v3.3/v3.4**: `initialize_pending_states` | Adoptado como `init_pending` |
| Autoridad | Ninguna versión revalida: un `DONE` se cree siempre | `state_valid()` exige que el archivo siga coincidiendo; si no, `RECOVERED` y reevaluación |
| Journal | v3.3+: mezclado con el log humano en algunos casos | `journal.tsv` separado, con `PENDING_AFTER_RECOVERY` como evento explícito |
| Claim entre workers | No aplica (nadie paraleliza) | `claim_file()` bajo `flock`: PROCESSING/VERIFYING marca propiedad |
| Codificación de rutas | v3.1+: `printf %q` + `eval` | Igual, encapsulado en `unq()` y probado con 8 nombres hostiles |

## 5. Governor

| Aspecto | Legacy consolidado | v4.0.0 |
|---|---|---|
| Métricas | CPU, iowait, load, memoria — y CPU/iowait rotos por el bug de IFS | Añade utilización y latencia de disco desde `/proc/diskstats` |
| Prioridad del score | CPU y memoria pesan igual que el I/O | Almacenamiento primero: `DISK_UTIL` hasta +5, `DISK_WAIT` +4, `IOWAIT` +4, CPU +3 |
| Niveles | HEALTHY/BUSY/PRESSURE/CRITICAL | Añade `EMERGENCY` |
| Baseline | Se mide y se registra | Además **propone el BW inicial** (`suggest_initial_bw`) |
| Autoridad del operador | v3.1+: correcta | Igual, más registro en journal de cada bloqueo de AUTO |
| Prioridad adaptativa | No existe | `adapt_priority()`, opt-in, con el valor del operador como cota agresiva |
| Cooldown adaptativo | No existe | `adapt_cooldown()`, `fixed` por defecto |
| Reparto entre workers | No aplica | `run_rsync` divide `BW_BPS/WORKERS`: el techo del operador se respeta en total |

## 6. Robustez operativa

| Aspecto | Legacy consolidado | v4.0.0 |
|---|---|---|
| Falta de espacio | `FAILED` por archivo: un problema del pool se vuelve cientos de fallos falsos | Pausa segura del lote, el archivo queda `PENDING` |
| Exit codes | `exit 1` / `exit 2` genéricos | 11 códigos semánticos (`EX_*`), documentados en `--help` |
| Lock | Avisa y sale | Además muestra PID, hora de inicio y target del worker que lo tiene |
| Entorno cambiante | Solo se valida al arrancar | `env_sane()` antes de cada archivo: dataset, montaje y recordsize |
| Desatendido | Sin modo silencioso; el dashboard depende del TTY | `--ui auto\|dash\|plain\|quiet\|json`, `--log-file`, `trap '' HUP` |
| Cuarentena | Se llena y nadie la mira | `inspect_quarantine()` reporta tamaño y SHA-256 de cada elemento |
| Finales de línea | CRLF rompe el shebang en Linux | Comprobado en el test estático |

## 7. Pruebas

| Aspecto | Legacy consolidado | v4.0.0 |
|---|---|---|
| Estático | `bash -n` + `grep` de tokens (v3.4 añade `--help`) | 37 comprobaciones, incluidas invariantes negativas ("no ejecuta `zfs set`", "un hint de zdb nunca produce SKIP") |
| Unitario | No existe | 60 asserts sobre funciones puras vía `ZRW_LIB_ONLY=1` |
| Integración | No existe | 41 comprobaciones end-to-end con ZFS simulado, incluidos rollback huérfano, paralelismo y exit codes |
| Ejecución verificada | Ninguna versión procesó un archivo | Ciclo completo ejecutado en Linux real con `rsync` real |

---

## Qué se descartó del legacy, y por qué

| Descartado | Origen | Motivo |
|---|---|---|
| `zdb` con hint `1M` ⇒ `SKIP` | v2, v3.4 | El propio `FINAL-ASSURANCE.md` de v3.4 afirma que un hint "never authorizes a skip", y el código sí saltea. Un campo `lsize` no prueba que *todos* los bloques del archivo sean de 1M |
| Ausencia de `trap` | v3, v3.2, v3.3, v3.4 | Ctrl+C dejaba temporales y anclas en el árbol de datos |
| Estado en un TSV compartido | v3.2–v3.4 | Reescribir el archivo entero en cada transición no es seguro con varios workers |
| `IFS` global `$'\n\t'` | v3, v3.1–v3.4 | Es la causa raíz de que el governor esté ciego; se fija por lectura |
| `nproc` como fuente del número de CPUs | v3.1–v3.4 | Dependencia innecesaria; `/proc/cpuinfo` siempre está |

---

## Lo que corrigió el servidor real (4.2.0)

Todo lo anterior es una auditoría de escritorio: comparación de código contra
código. Correr `remote/zrw-discovery.sh` sobre el TrueNAS de destino invalidó
dos conclusiones de esa auditoría, y vale la pena dejar dicho cuáles, porque el
patrón se repite: **ninguna de las dos se podía ver leyendo código.**

### 1. `getfacl` no sirve donde `acltype=nfsv4`

La auditoría dio por buena la cadena "`getfacl`/`getfattr` cuando existen,
`rsync --itemize-changes` como fallback". Sobre el servidor real los datasets
usan `acltype=nfsv4`, que `getfacl` no sabe leer y que `rsync --itemize-changes`
directamente no comprueba. El preflight habría dicho READY y cada archivo
habría fallado **después** de copiarse y hashearse.

La corrección no fue agregar una herramienta más, sino separar lo que estaba
colapsado: capacidades del host, política del dataset, y verificador efectivo
por archivo. El fallback a `rsync` se eliminó: daba una respuesta
tranquilizadora y falsa, que es peor que no dar ninguna.

### 2. `lsize` nunca respondió la pregunta

La auditoría celebró que v3.4 endureciera el parseo de `zdb` exigiendo un campo
`lsize` explícito, y adoptó ese criterio. La salida real de `zdb -O` muestra por
qué daba igual: `lsize` es el **tamaño lógico del archivo**, así que un archivo
de 2 GiB reporta 2 GiB esté en bloques de 128K o de 1M. El campo que responde
"¿este archivo ya está en el recordsize objetivo?" es **`dblk`**.

El hint era, en la práctica, ruido bien parseado. Que nunca decidiera nada
—única decisión de diseño que la auditoría defendió correctamente— es lo que
impidió que ese error tuviera consecuencias.

### Qué dice esto del método

Las dos correcciones tienen la misma forma: una capa de abstracción que parecía
resuelta ("verificar ACL", "leer el tamaño de bloque") escondía una pregunta que
solo el entorno real podía contestar. De ahí que `remote/zrw-discovery.sh` sea
parte del entregable y no una herramienta de una sola vez: antes de correr el
worker en un servidor nuevo, la sonda va primero.

---

# English

**Code-level** comparison, not a feature comparison. "Consolidated legacy" means the best of what appears across any of the six prior versions (`v2`, `v3`, `v3.1`, `v3.2`, `v3.3`, `v3.4`), as if they could be merged into one. Each row states what was salvaged, what was fixed, and what was discarded.

Startup status of each legacy version, verified by actually running them:

| Version | Lines | `bash -n` | Does it process a file? |
|---|---:|---|---|
| v2 | 187 | passes | yes |
| v3 | 1,154 | passes | skeleton only, no |
| v3.1 | 1,294 | **fails** (line 1074) | no |
| v3.2 | 1,183 | passes | no (baseline regression) |
| v3.3 | 1,422 | passes | **no** — `orig_sha: unbound variable`, line 952 |
| v3.4 | 1,497 | passes | **no** — same defect, line 996 |

---

## 1. Structure and readability

| Aspect | Consolidated legacy | v4.0.0 |
|---|---|---|
| Organization | Sections marked by comments, no index; the reader discovers the order by reading | 20 numbered sections with an index in the header; each one is a single concern |
| Comments | Mix of Spanish and English; many describe *what* the line does | All in English; they explain *why*, not *what*. Checked by the static test |
| Length | 1,497 (v3.4) for less functionality | 2,154 with parallelism, diskstats, rollback, output modes, and `--explain` |
| Helpers | Repeated `stat -c` calls, one per field (6 calls per file) | `snapshot_file` does a single `stat -c '%s %i %a %u %g %h'` |
| CLI parsing | One `case` with validation scattered across branches | Value-taking option branches grouped together; all validation in `validate()` |
| Output | Loose `printf` calls scattered everywhere | `say/raw/log/err/warn` with `UI_MODE` as the single projection point |
| Naming | `CURRENT_*`, `STATE_*`, `FILE_*`, `DEFAULT_*` — long and repetitive | `CUR_*`, `ST_*`, `F_*`, `D_*` — short and consistent |
| Constants | Plain variables, accidentally overwritable | `readonly` for defaults and exit codes |

## 2. Core correctness

| Aspect | Consolidated legacy | v4.0.0 |
|---|---|---|
| `set -e` | v2 uses it: one failed rsync aborts the entire batch | `set -uo pipefail` without `-e`; a file that fails is logged and the batch continues |
| Uninitialized variables | `local hint orig_sha` + `[[ -z "$orig_sha" ]]` under `set -u` → **aborts on the first file** (v3.3/v3.4) | Every variable is initialized; `src_sha=""` explicit |
| Reading `/proc/stat` | `read` with global `IFS=$'\n\t'` → empty fields → CPU and IOWAIT always 0 | Local `IFS=' ' read -r -a`; verified with a test |
| bwlimit format | `"${bps}B"` — rsync doesn't accept it and the parser can't read it back → governor frozen (v3.1) | `bw_rate()` normalizes to KiB; round-trip test |
| Hash/timestamp order | Temp file hashed **after** restoring timestamps → the atime invariant always fails (v3.1) | Hash first, restoration after, verification last. Same for post-commit |
| Source atime | Read for hashing and never restored: a FAILED leaves the original altered | `touch -a` immediately after every read of the source |
| State `mv` | `mv` of a `.tmp` that was never created when state is empty (v3.3/v3.4) | `save_state` always writes before renaming |
| `trap` | Absent in v3, v3.2, v3.3, v3.4 | `trap cleanup EXIT INT TERM` and `trap '' HUP` |

## 3. Integrity and commit boundary

| Aspect | Consolidated legacy | v4.0.0 |
|---|---|---|
| Pre-commit verification | v2: size only. v3.1+: SHA-256 + metadata | SHA-256 + mode/uid/gid + timestamps + ACL/xattr + identity, in that order |
| Re-hashing the source after copying | **v3.3/v3.4**: detects changes that preserve size and mtime | Adopted, and classified as `STALE` (not `FAILED`): someone writing to the file is not a worker failure |
| Rollback anchor | **v3.4**: hardlink to the original inode, zero space cost | Adopted. `make_anchor` writes a sidecar record first, then links |
| Post-commit rollback | v3.4: quarantines the replacement + restores the original | Adopted, plus timestamp restoration and `sync` |
| Post-commit ACL/xattr | v3.4: compares against the anchor (original metadata) | Adopted |
| ACL/xattr verification | v3.4: `rsync --itemize-changes` only | `getfacl`/`getfattr` when available, `rsync` as fallback; the method used is recorded in the summary — **superseded in 4.2.0**, see below |
| `zdb` parsing | v3.1: broad text match. v3.4: requires an explicit `lsize` field | v3.4's criterion adopted **without its consequence**: the hint never produces a SKIP — **`lsize` turned out to be the wrong field**, see below |
| Anchor recovery | **Does not exist** in v3.4: `recover_orphans` only looks for `.tmp` files | `recover_anchors` compares inodes: if the commit never happened it deletes the anchor; if it happened without verification, it completes the rollback |

### The defect this fixes

In v3.4, a power outage between `ln` and `mv` leaves the anchor orphaned. The original ends up with `nlink=2`, and on the next run the worker itself classifies it as a hardlink and marks it `SKIPPED` — a terminal state that not even `--retry-failed` revisits. The file becomes silently unprocessable, forever. v4's integration bench reproduces that exact scenario and confirms the file returns to `nlink=1`, intact and processable.

## 4. State and durability

| Aspect | Consolidated legacy | v4.0.0 |
|---|---|---|
| Format | v3.2/v3.3: a single shared TSV, rewritten in full on every transition | One file per candidate: independent writes, suitable for parallelism |
| Durability | **v3.3/v3.4**: `sync -f` on state and journal | Adopted in `save_state` and `journal` |
| Initial PENDING | **v3.3/v3.4**: `initialize_pending_states` | Adopted as `init_pending` |
| Authority | No version revalidates: a `DONE` is always trusted | `state_valid()` requires the file to still match; if not, `RECOVERED` and re-evaluation |
| Journal | v3.3+: mixed with the human-readable log in some cases | Separate `journal.tsv`, with `PENDING_AFTER_RECOVERY` as an explicit event |
| Claim between workers | Not applicable (nobody parallelizes) | `claim_file()` under `flock`: PROCESSING/VERIFYING marks ownership |
| Path encoding | v3.1+: `printf %q` + `eval` | Same, encapsulated in `unq()` and tested against 8 hostile names |

## 5. Governor

| Aspect | Consolidated legacy | v4.0.0 |
|---|---|---|
| Metrics | CPU, iowait, load, memory — with CPU/iowait broken by the IFS bug | Adds disk utilization and latency from `/proc/diskstats` |
| Score priority | CPU and memory weigh the same as I/O | Storage first: `DISK_UTIL` up to +5, `DISK_WAIT` +4, `IOWAIT` +4, CPU +3 |
| Levels | HEALTHY/BUSY/PRESSURE/CRITICAL | Adds `EMERGENCY` |
| Baseline | Measured and logged | Also **proposes the initial BW** (`suggest_initial_bw`) |
| Operator authority | v3.1+: correct | Same, plus a journal entry for every AUTO block |
| Adaptive priority | Does not exist | `adapt_priority()`, opt-in, with the operator's value as an aggressive ceiling |
| Adaptive cooldown | Does not exist | `adapt_cooldown()`, `fixed` by default |
| Distribution across workers | Not applicable | `run_rsync` splits `BW_BPS/WORKERS`: the operator's ceiling is respected in total |

## 6. Operational robustness

| Aspect | Consolidated legacy | v4.0.0 |
|---|---|---|
| Insufficient space | `FAILED` per file: a pool problem turns into hundreds of false failures | Safe batch pause, the file stays `PENDING` |
| Exit codes | Generic `exit 1` / `exit 2` | 11 semantic codes (`EX_*`), documented in `--help` |
| Lock | Warns and exits | Also shows PID, start time, and target of the worker holding it |
| Changing environment | Only validated at startup | `env_sane()` before every file: dataset, mount, and recordsize |
| Unattended operation | No silent mode; the dashboard depends on the TTY | `--ui auto\|dash\|plain\|quiet\|json`, `--log-file`, `trap '' HUP` |
| Quarantine | Fills up and nobody looks at it | `inspect_quarantine()` reports size and SHA-256 of every item |
| Line endings | CRLF breaks the shebang on Linux | Checked by the static test |

## 7. Testing

| Aspect | Consolidated legacy | v4.0.0 |
|---|---|---|
| Static | `bash -n` + token `grep` (v3.4 adds `--help`) | 37 checks, including negative invariants ("does not run `zfs set`", "a zdb hint never produces a SKIP") |
| Unit | Does not exist | 60 asserts over pure functions via `ZRW_LIB_ONLY=1` |
| Integration | Does not exist | 41 end-to-end checks with simulated ZFS, including orphaned rollback, parallelism, and exit codes |
| Verified execution | No version ever processed a file | Full cycle run on real Linux with real `rsync` |

---

## What was discarded from legacy, and why

| Discarded | Origin | Reason |
|---|---|---|
| `zdb` hint of `1M` ⇒ `SKIP` | v2, v3.4 | v3.4's own `FINAL-ASSURANCE.md` states a hint "never authorizes a skip," yet the code does skip. An `lsize` field doesn't prove *every* block of the file is 1M |
| No `trap` | v3, v3.2, v3.3, v3.4 | Ctrl+C left temp files and anchors behind in the data tree |
| State in a shared TSV | v3.2–v3.4 | Rewriting the entire file on every transition isn't safe with multiple workers |
| Global `IFS` set to `$'\n\t'` | v3, v3.1–v3.4 | It's the root cause of the governor being blind; fixed at read time |
| `nproc` as the source of CPU count | v3.1–v3.4 | Unnecessary dependency; `/proc/cpuinfo` is always available |

---

## What the real server fixed (4.2.0)

Everything above is a desk audit: code-against-code comparison. Running
`remote/zrw-discovery.sh` against the target TrueNAS invalidated two
conclusions from that audit, and it's worth recording which ones, because the
pattern repeats: **neither one could be seen just by reading the code.**

### 1. `getfacl` doesn't work where `acltype=nfsv4`

The audit approved the chain "`getfacl`/`getfattr` when available, `rsync
--itemize-changes` as fallback." On the real server the datasets use
`acltype=nfsv4`, which `getfacl` can't read and which `rsync
--itemize-changes` simply doesn't check. The preflight would have said READY
and every file would have failed **after** being copied and hashed.

The fix wasn't adding one more tool, but separating what had been collapsed
together: host capabilities, dataset policy, and the effective per-file
verifier. The `rsync` fallback was removed: it gave a reassuring but false
answer, which is worse than giving none at all.

### 2. `lsize` never answered the question

The audit praised v3.4 for hardening the `zdb` parsing by requiring an
explicit `lsize` field, and adopted that criterion. The real output of `zdb
-O` shows why it didn't matter: `lsize` is the file's **logical size**, so a
2 GiB file reports 2 GiB whether it's in 128K blocks or 1M blocks. The field
that actually answers "is this file already at the target recordsize?" is
**`dblk`**.

The hint was, in practice, well-parsed noise. The fact that it never decided
anything — the one design decision the audit correctly defended — is what
kept that error from having any consequences.

### What this says about the method

Both fixes have the same shape: an abstraction layer that looked already
solved ("verify ACL," "read the block size") was hiding a question that only
the real environment could answer. That's why `remote/zrw-discovery.sh` is
part of the deliverable and not a one-off tool: before running the worker on
a new server, the probe goes first.
