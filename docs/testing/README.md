# Historial de pruebas contra el servidor real

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Esta carpeta archiva la salida completa de cada ronda de pruebas corrida contra
el TrueNAS de referencia (`toolbox/media`, `acltype=nfsv4`, `recordsize=1M`).
Es el registro que sostiene las afirmaciones del `CHANGELOG.md`: cada hallazgo
ahí documentado tiene su evidencia cruda acá, para poder revisarlo después sin
tener que confiar en el resumen.

`remote/results/` (en `.gitignore`) sigue siendo el destino por defecto de
`zrw-remote.sh`: ahí cae la salida de cada corrida, efímera. Lo que se junta
acá es la selección curada y renombrada de esas corridas, la que vale la pena
conservar.

## Índice

### [`ronda-1-conexion-y-preflight/`](ronda-1-conexion-y-preflight/)
Primera conexión SSH real, primer `discover`/`check`/`dry-run`/`environment`
contra el servidor. Acá aparece por primera vez, en datos reales, el falso
aviso *"rsync sin soporte ACL declarado"* — la pista que llevó al hallazgo del
bug de `pipefail` + `grep -q` (ver CHANGELOG 4.2.1).

### [`ronda-2-bateria-hallazgos/`](ronda-2-bateria-hallazgos/)
La batería completa: estático + unitario + integración, local y corriendo
*dentro* del NAS real, más `--explain` sobre archivos reales de distinto
tamaño. `remoto/06` a `remoto/11` documentan la progresión completa de un
hallazgo real: 30 fallos → 1 fallo → 0 fallos, a medida que se corrigió primero
el harness de tests (`/tmp` en `noexec` en este servidor) y después el diseño
de los escenarios de ACL (asumían la ausencia de `nfs4xdr_getfacl`, que en
TrueNAS SCALE viene instalado de fábrica).

### [`ronda-3-round-trip-acl-real/`](ronda-3-round-trip-acl-real/)
Copia real de un archivo de producción (6 GiB, `acltype=nfsv4`) y de un
archivo nativo de un dataset `acltype=posix`, verificando SHA-256, ACL, xattr
y timestamps antes/después. El archivo `02` documenta también un error de
método propio (comparar la vista NFSv4 de un origen NFSv4 contra su copia en
POSIX no prueba nada) y su corrección.

### [`ronda-4-job-real-y-hallazgo-zdb/`](ronda-4-job-real-y-hallazgo-zdb/)
El primer `--new-job` **real** (no `--dry-run`) del proyecto, dentro de un
directorio de prueba dedicado y descartable. Encontró, de casualidad —un
scrub real corriendo en el pool desde medianoche—, que `zdb -O` puede
bloquearse varios minutos compitiendo por I/O de metadata, congelando el job
entero pese a ser "solo advisory". Corregido en 4.2.2 con un `timeout`
alrededor de esa llamada. El mismo bug explicaba, de rebote, por qué
`--resume` fallaba con `EX_LOCKED` justo después de interrumpir un job.

### [`ronda-5-bateria-autonoma/`](ronda-5-bateria-autonoma/)
Auditoría de código de `sync`/`sync -f` (sin bugs) más una batería autónoma
completa: governor bajo scrub real, `--integrity standard`/`maximum`,
`STALE` en ambos checkpoints, ACL con `fhandle` cambiado, nombres de archivo
límite, `.state` forzado a mano, y dos workers reales simultáneos sobre el
mismo job. La batería de nombres límite reveló dos bugs reales e
independientes —`hash_of()` no quitaba la barra que `sha256sum` antepone al
hash de un nombre con salto de línea, y `xattr_equal()`/`acl_equal_posix()`
asumían un encabezado de tamaño fijo en `getfattr`/`getfacl` que ese mismo
salto de línea rompe— que dejaban sin reblockear, en silencio pero sin
riesgo de pérdida de datos, cualquier archivo real con un salto de línea en
su nombre. Corregido en 4.2.3.

### [`ronda-6-backslash-workers-job-largo/`](ronda-6-backslash-workers-job-largo/)
Backslash literal en el nombre (mismo fix de 4.2.3, sin cambios adicionales
necesarios), `--workers 2` combinado con `STALE` (sin interacción
problemática), y un job real de 293 GiB / 3h23m sin supervisión. El hallazgo:
bajo presión sostenida real del servidor (mismo scrub de fondo), el governor
pausó el job por su cuenta (`JOB PAUSADO`, código 13) en vez de forzar un
disco ya saturado — comportamiento correcto por diseño, pero significa que un
job largo con la configuración adaptativa por defecto puede quedar esperando
un `--resume` manual en vez de terminar solo. RSS estable (~5.8 MB) durante
toda la corrida, sin señales de fuga de memoria.

### [`ronda-7-casos-limite-restantes/`](ronda-7-casos-limite-restantes/)
El resto de `docs/TEST-PLAN.md` que se podía resolver sin consola interactiva
ni autorización especial: hardlink → `SKIPPED`, UID/GID de un usuario real no
root preservados, directorio anidado profundo, salida sin códigos ANSI al
redirigir a archivo, temporal corrompido antes de verificar → `FAILED` sin
commit, `DONE` forzado a mano + modificación → `RECOVERED`, y `guarded`
confirmado sin ningún evento `INCREASE` bajo presión real crítica. Un
hallazgo de método propio: la prueba del temporal de OTRO job reveló que mi
expectativa (cuarentena) estaba mal — el código correctamente lo deja
intacto sin tocarlo, la cuarentena es solo para huérfanos del mismo job.
`zdb -O` post-commit quedó inconcluso (bloqueado por el mismo scrub real,
consistente con el hallazgo ya conocido de la ronda 4). ACL POSIX no trivial
y `atime=on` quedaron fuera a propósito: requieren tocar una propiedad de
dataset de producción o crear uno de laboratorio, decisión de
infraestructura que le corresponde al operador.

### [`ronda-9-hash-cascade-lab-dataset-governor-ocioso/`](ronda-9-hash-cascade-lab-dataset-governor-ocioso/)
Cuatro cierres: la causa raíz real de `zdb -O` (retraso de un ciclo de TXG,
~5-10s, no el scrub — confirmado con una prueba de retraso escalonado y con
`dblk=1M` finalmente verificado post-commit); el governor con un servidor
genuinamente ocioso subiendo limpio hasta `--bw-max` (el primer intento se
contaminó con la propia carga de armar el test, documentado como parte del
aprendizaje); y ACL POSIX no trivial + `atime=on` cerrados usando el dataset
de laboratorio descartable (`remote/zrw-lab-dataset.sh`, creado y destruido
sin tocar producción).

### [`ronda-10-auto-resume-carga-sintetica/`](ronda-10-auto-resume-carga-sintetica/)
`--auto-resume` (4.3.0) confirmado contra presión real, con carga sintética
de `fio` autorizada explícitamente sobre el pool de producción: pausa a los
35s de `EMERGENCY` real, reanudación sola 40s-3m19s después de cortar la
carga, código de salida 0, SHA-256 idéntico. De paso, primera verificación
en vivo de `remote/zrw-deep-observe.sh` (árbol de procesos, I/O real por
proceso, fds, memoria, cgroup) contra el worker corriendo de verdad.

### [`ronda-11-produccion-musicales/`](ronda-11-produccion-musicales/)
Primera corrida real sobre producción, en el lugar (no una copia
descartable): `Musicales`, 14.33 GiB, 199 archivos. Solo 1 calificó por
umbral, se reescribió con 0 fallos, `mtime`/ACL idénticos y `zdb -O`
confirmando `dblk=1M`. 199/199 verificados al final. Incluye dos errores
propios de scripting documentados con transparencia (sin consecuencia real
sobre los datos).

### [`ronda-12-reinicio-real/`](ronda-12-reinicio-real/)
Reinicio real de la máquina (`/sbin/reboot`) a mitad de una copia de 6 GiB,
autorizado explícitamente. Pool importado sin errores, `PROCESSING` volvió
a `PENDING` tal como documenta el contrato, `--resume` completó con hash
idéntico. Encontró un bug real: el temporal parcial de `rsync` (con su
sufijo aleatorio, antes del renombrado final) no coincidía con el glob de
`recover_temps()` y quedaba huérfano para siempre, sin cuarentena — mismo
patrón corregido en 4.4.1.

### [`ronda-13-consola-en-vivo/`](ronda-13-consola-en-vivo/)
Secciones I y H completas, turno por turno con el operador tecleando en su
propia terminal. Tres bugs reales encontrados y corregidos en el momento:
el teclado competía con el inventario por `stdin` (4.4.2, un archivo podía
perder su nombre sin perder su contenido), `[C]` cambiando
recordsize/threshold podía abortar el job en curso (4.4.4), y `Ctrl+C` no
terminaba el proceso (4.4.7). De paso, dos pasadas de color en el
dashboard (4.4.5/4.4.6). Sobrevivió un reinicio real
no planeado de la máquina y la PC a mitad de la ronda.

### [`ronda-14-b3sum-verificador-ausente/`](ronda-14-b3sum-verificador-ausente/)
Los tres últimos ítems que dependían de instalar `b3sum` o de simular una
herramienta ACL ausente, cerrados contra el NAS real: `--hash b3` con un
`b3sum` real (formato de salida idéntico a `sha256sum`/`b2sum`, sin cambios
de parseo); un dataset `nfsv4` real quedando fuera del inventario cuando se
oculta `nfs4xdr_getfacl`/`jq` del PATH (símlinks, nunca se tocan los binarios
reales); y un árbol entero sin ningún verificador terminando en código `20`
antes de tocar nada, en un dataset de laboratorio descartable. Ejecutada
directamente por Claude vía SSH de solo lectura/no interactivo (sin
necesidad de que el operador tipee nada), para acelerar los pasos que no
requieren su intervención.

### [`ronda-15-pausa-por-espacio-real/`](ronda-15-pausa-por-espacio-real/)
El último ítem prohibido ("llenar el pool") resuelto con el reemplazo que el
propio operador propuso: un dataset de laboratorio descartable con `quota`
chica en vez del pool real. Confirmó la pausa segura ante espacio
insuficiente (código `13`, candidato intacto, sin `FAILED`) y la reanudación
completa tras liberar espacio (`--resume`, hash idéntico). De paso corrigió
un error de verificación propio de la ronda 14 (`STATE_ROOT` real vs. una
ruta vieja usada por error al comprobar residuos).

### [`ronda-16-produccion-series-completa/`](ronda-16-produccion-series-completa/)
La corrida real más grande del proyecto: `Videos/Series` completo (2.1 TiB,
238 archivos, ~17% de `toolbox/media`), 0 fallos. Sobrevivió un reinicio
real de la máquina a mitad de camino. Cinco bugs reales encontrados y
corregidos (4.4.8-4.4.12), ninguno de integridad. Confirmó, con `fio`
aislado, que el techo bajo del governor era prudencia, no el disco — con
`--adaptive off` autorizado explícitamente, los archivos reales sostuvieron
62-64 MiB/s.

## Convención

Cada ronda vive en `docs/discovery/` (local, no publicado) cuando es una
sonda de descubrimiento (`zrw-discovery.sh`, formato `.txt`+`.json`) o acá,
en `docs/testing/`, cuando es una corrida del worker o de sus tests. Los
nombres de archivo llevan un prefijo numérico que refleja el orden real en
que se ejecutaron, no un orden temático.

---

# English

This folder archives the complete output of every round of testing run
against the reference TrueNAS box (`toolbox/media`, `acltype=nfsv4`,
`recordsize=1M`). It's the record that backs the claims in `CHANGELOG.md`:
every finding documented there has its raw evidence here, so it can be
reviewed later without having to trust the summary.

`remote/results/` (in `.gitignore`) remains the default destination for
`zrw-remote.sh`: that's where each run's output lands, ephemeral. What's
collected here is the curated, renamed selection of those runs — the ones
worth keeping.

## Index

### [`ronda-1-conexion-y-preflight/`](ronda-1-conexion-y-preflight/)
First real SSH connection, first `discover`/`check`/`dry-run`/`environment`
against the server. This is where the false *"rsync sin soporte ACL
declarado"* ("rsync without declared ACL support") warning first shows up
on real data — the clue that led to the discovery of the `pipefail` +
`grep -q` bug (see CHANGELOG 4.2.1).

### [`ronda-2-bateria-hallazgos/`](ronda-2-bateria-hallazgos/)
The full battery: static + unit + integration, run locally and *inside*
the real NAS, plus `--explain` against real files of different sizes.
`remoto/06` through `remoto/11` document the complete progression of a
real finding: 30 failures → 1 failure → 0 failures, as the test harness
was fixed first (`/tmp` mounted `noexec` on this server) and then the ACL
scenario design (they assumed `nfs4xdr_getfacl` would be absent, when on
TrueNAS SCALE it ships installed by default).

### [`ronda-3-round-trip-acl-real/`](ronda-3-round-trip-acl-real/)
Real copy of a production file (6 GiB, `acltype=nfsv4`) and of a native
file from an `acltype=posix` dataset, verifying SHA-256, ACL, xattr and
timestamps before/after. File `02` also documents a methodology mistake of
my own (comparing the NFSv4 view of an NFSv4 source against its POSIX
copy proves nothing) and its correction.

### [`ronda-4-job-real-y-hallazgo-zdb/`](ronda-4-job-real-y-hallazgo-zdb/)
The project's first **real** `--new-job` (not `--dry-run`), inside a
dedicated, disposable test directory. Found, by chance — a real scrub had
been running on the pool since midnight — that `zdb -O` can block for
several minutes competing for metadata I/O, freezing the entire job
despite being "advisory only". Fixed in 4.2.2 with a `timeout` around
that call. The same bug explained, as a side effect, why `--resume` was
failing with `EX_LOCKED` right after interrupting a job.

### [`ronda-5-bateria-autonoma/`](ronda-5-bateria-autonoma/)
Code audit of `sync`/`sync -f` (no bugs) plus a complete autonomous
battery: governor under a real scrub, `--integrity standard`/`maximum`,
`STALE` at both checkpoints, ACL with a changed `fhandle`, edge-case file
names, `.state` forced by hand, and two real workers running
simultaneously on the same job. The edge-case-names battery revealed two
real, independent bugs — `hash_of()` wasn't stripping the leading slash
`sha256sum` prepends to the hash of a name containing a newline, and
`xattr_equal()`/`acl_equal_posix()` assumed a fixed-size header in
`getfattr`/`getfacl` that that same newline breaks — which left any real
file with a newline in its name silently un-reblocked, without any risk of
data loss. Fixed in 4.2.3.

### [`ronda-6-backslash-workers-job-largo/`](ronda-6-backslash-workers-job-largo/)
A literal backslash in a file name (same fix as 4.2.3, no additional
changes needed), `--workers 2` combined with `STALE` (no problematic
interaction), and a real, unsupervised 293 GiB / 3h23m job. The finding:
under sustained real server pressure (the same background scrub), the
governor paused the job on its own (`JOB PAUSADO`, code 13) instead of
forcing an already-saturated disk — correct behavior by design, but it
means a long job with the default adaptive configuration can end up
waiting on a manual `--resume` instead of finishing on its own. RSS stayed
stable (~5.8 MB) throughout the whole run, with no sign of a memory leak.

### [`ronda-7-casos-limite-restantes/`](ronda-7-casos-limite-restantes/)
The rest of `docs/TEST-PLAN.md` that could be resolved without an
interactive console or special authorization: hardlink → `SKIPPED`,
UID/GID of a real non-root user preserved, deeply nested directory, output
with no ANSI codes when redirected to a file, a temp file corrupted before
verification → `FAILED` with no commit, `DONE` forced by hand + modified
→ `RECOVERED`, and `guarded` confirmed with no `INCREASE` event at all
under real critical pressure. A methodology finding of my own: testing the
temp file of ANOTHER job revealed my expectation (quarantine) was wrong —
the code correctly leaves it untouched, quarantine is only for orphans of
the same job. Post-commit `zdb -O` was left inconclusive (blocked by the
same real scrub, consistent with the already-known finding from round 4).
Non-trivial POSIX ACL and `atime=on` were deliberately left out: they
require touching a production dataset property or creating a lab one, an
infrastructure decision that belongs to the operator.

### [`ronda-9-hash-cascade-lab-dataset-governor-ocioso/`](ronda-9-hash-cascade-lab-dataset-governor-ocioso/)
Four items closed out: the real root cause of `zdb -O` (a TXG cycle delay,
~5-10s, not the scrub — confirmed with a staggered-delay test and with
`dblk=1M` finally verified post-commit); the governor with a genuinely
idle server climbing cleanly up to `--bw-max` (the first attempt was
contaminated by the load of setting up the test itself, documented as
part of the learning process); and non-trivial POSIX ACL + `atime=on`
closed out using the disposable lab dataset (`remote/zrw-lab-dataset.sh`,
created and destroyed without touching production).

### [`ronda-10-auto-resume-carga-sintetica/`](ronda-10-auto-resume-carga-sintetica/)
`--auto-resume` (4.3.0) confirmed against real pressure, with explicitly
authorized synthetic `fio` load on the production pool: paused at 35s
under real `EMERGENCY`, resumed on its own 40s-3m19s after cutting the
load, exit code 0, identical SHA-256. Along the way, the first live
verification of `remote/zrw-deep-observe.sh` (process tree, real per-
process I/O, fds, memory, cgroup) against the worker actually running.

### [`ronda-11-produccion-musicales/`](ronda-11-produccion-musicales/)
First real run against production, in place (not a disposable copy):
`Musicales`, 14.33 GiB, 199 files. Only 1 qualified by threshold, was
rewritten with 0 failures, identical `mtime`/ACL, and `zdb -O` confirming
`dblk=1M`. 199/199 verified at the end. Includes two scripting mistakes of
my own, documented transparently (with no real consequence to the data).

### [`ronda-12-reinicio-real/`](ronda-12-reinicio-real/)
A real machine reboot (`/sbin/reboot`), explicitly authorized, mid-copy of
a 6 GiB file. Pool imported with no errors, `PROCESSING` reverted to
`PENDING` exactly as the contract documents, `--resume` completed with an
identical hash. Found a real bug: rsync's partial temp file (with its
random suffix, before the final rename) didn't match `recover_temps()`'s
glob and stayed orphaned forever, without quarantine — the same pattern
fixed in 4.4.1.

### [`ronda-13-consola-en-vivo/`](ronda-13-consola-en-vivo/)
Sections I and H in full, turn by turn with the operator typing on their
own terminal. Three real bugs found and fixed on the spot: the keyboard
was competing with the inventory for `stdin` (4.4.2, a file could lose its
name without losing its content), `[C]` changing recordsize/threshold
could abort the job in progress (4.4.4), and `Ctrl+C` wasn't terminating
the process (4.4.7). Along the way, two passes on dashboard color
(4.4.5/4.4.6). Survived a real, unplanned reboot of both the machine and
the PC mid-round.

### [`ronda-14-b3sum-verificador-ausente/`](ronda-14-b3sum-verificador-ausente/)
The last three items that depended on installing `b3sum` or simulating a
missing ACL tool, closed out against the real NAS: `--hash b3` with a real
`b3sum` (output format identical to `sha256sum`/`b2sum`, no parsing
changes needed); a real `nfsv4` dataset correctly falling out of the
inventory when `nfs4xdr_getfacl`/`jq` are hidden from the PATH (via
symlinks, the real binaries are never touched); and an entire tree with no
verifier at all ending in code `20` before touching anything, on a
disposable lab dataset. Run directly by Claude over a read-only,
non-interactive SSH session (with no need for the operator to type
anything), to speed up the steps that don't require their intervention.

### [`ronda-15-pausa-por-espacio-real/`](ronda-15-pausa-por-espacio-real/)
The last forbidden item ("fill the pool") resolved with the substitute the
operator himself proposed: a disposable lab dataset with a small `quota`
instead of the real pool. Confirmed the safe pause on insufficient space
(code `13`, candidate untouched, no `FAILED`) and full resumption after
freeing space (`--resume`, identical hash). Along the way, it also fixed a
verification mistake of its own from round 14 (the real `STATE_ROOT` vs.
an old path mistakenly used when checking for leftovers).

### [`ronda-16-produccion-series-completa/`](ronda-16-produccion-series-completa/)
The largest real run of the project: all of `Videos/Series` (2.1 TiB, 238
files, ~17% of `toolbox/media`), 0 failures. Survived a real machine
reboot partway through. Five real bugs found and fixed (4.4.8-4.4.12),
none of them integrity-related. Confirmed, with isolated `fio`, that the
governor's low ceiling was caution, not the disk — with `--adaptive off`
explicitly authorized, the real files sustained 62-64 MiB/s.

## Convention

Each round lives in `docs/discovery/` (local, not published) when it's a
discovery probe (`zrw-discovery.sh`, `.txt`+`.json` format), or here, in
`docs/testing/`, when it's a run of the worker or its tests. File names
carry a numeric prefix reflecting the actual order they were run in, not a
thematic order.
