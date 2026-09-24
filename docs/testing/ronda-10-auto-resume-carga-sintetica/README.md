# Ronda 10 — `--auto-resume` confirmado contra presión real (carga sintética autorizada)

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Se generó carga sintética de I/O real (`fio`) sobre el pool de producción,
a propósito, para validar `--auto-resume` (4.3.0) en condiciones reales —
algo que quedó pendiente en la ronda 6/7 porque el scrub que sostenía la
presión natural terminó antes de poder probarlo, y que deliberadamente no
se hizo antes de contar con autorización previa (ver ronda 9).

## Resultado

Confirmado de punta a punta, con un script único que orquesta todo:
1. Dos archivos reales (2.79 GiB cada uno) a reblockear, con el sistema
   genuinamente asentado antes de arrancar (mismo cuidado metodológico de
   la ronda 9, corregido después de contaminar una medición ahí).
2. Worker lanzado con `--adaptive auto --auto-resume --pause-timeout 15`.
3. `fio` generando presión real (`randrw`, 4 jobs, iodepth 32) sobre un
   archivo de scratch en el mismo pool.
4. El baseline capturó `EMERGENCY` real; el worker entró en pausa
   protectiva a los 35s: `[AUTO] PAUSA PROTECTIVA: EMERGENCY sostenido` +
   `[AUTO] --auto-resume activo: esperando...` — **sin salir**.
5. Se cortó la presión sintética (`kill` a `fio`).
6. El worker detectó la recuperación y **reanudó solo**, sin `--resume`:
   40s después en el primer archivo, 3m19s después en el segundo (más
   presión residual esa vez).
7. Job completado: 2/2 reescritos, 0 fallidos, **código de salida 0** (no
   13 — nunca se invocó `--resume` manualmente). SHA-256 idéntico en ambos
   archivos antes/después.

De paso, se validó en vivo `remote/zrw-deep-observe.sh` (herramienta nueva
de esta misma sesión) contra el proceso real del worker mientras corría:
árbol de procesos, I/O real por proceso, descriptores de archivo abiertos
con sus rutas exactas, memoria, cgroup, y `zpool iostat` — todo funcionando
correctamente, sirvió de base para [Live Console Protocol](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Live-Console-Protocol) y para
el diseño de [Witness Design](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Witness-Design) (pendiente, no construir todavía).

## Índice

- `01-batchW-auto-resume-fio-real.txt` — log completo de la corrida: desde
  el chequeo de espacio hasta la limpieza final, incluido el log íntegro
  del worker con las dos transiciones de pausa/reanudación.

## Cierre

Con esto, `--auto-resume` queda completamente validado: tanto en el
laboratorio simulado (5 tests unitarios deterministas, ambos caminos:
recupera solo / se rinde por timeout) como contra presión real de un
servidor de producción. Sin cambios de código en esta ronda.

---

# English

Real, synthetic I/O load (`fio`) was generated on the production pool,
deliberately, to validate `--auto-resume` (4.3.0) under real conditions —
something that had been left pending in round 6/7 because the scrub
sustaining the natural pressure ended before it could be tested, and that
was deliberately not done without prior authorization (see round 9).

## Result

Confirmed end to end, with a single script that orchestrates everything:

1. Two real files (2.79 GiB each) to be reblocked, with the system
   genuinely settled before starting (same methodological care as round 9,
   adopted after a measurement there got contaminated).
2. Worker launched with `--adaptive auto --auto-resume --pause-timeout 15`.
3. `fio` generating real pressure (`randrw`, 4 jobs, iodepth 32) on a
   scratch file in the same pool.
4. The baseline captured real `EMERGENCY`; the worker entered a protective
   pause at 35s: `[AUTO] PAUSA PROTECTIVA: EMERGENCY sostenido` +
   `[AUTO] --auto-resume activo: esperando...` — **without exiting**.
5. The synthetic pressure was cut (`kill` on `fio`).
6. The worker detected the recovery and **resumed on its own**, without
   `--resume`: 40s later on the first file, 3m19s later on the second
   (more residual pressure that time).
7. Job completed: 2/2 rewritten, 0 failed, **exit code 0** (not 13 —
   `--resume` was never invoked manually). Identical SHA-256 on both files
   before/after.

Along the way, `remote/zrw-deep-observe.sh` (a new tool from this same
session) was validated live against the worker's real process while it was
running: process tree, real per-process I/O, open file descriptors with
their exact paths, memory, cgroup, and `zpool iostat` — all working
correctly, and it served as the basis for [Live Console Protocol](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Live-Console-Protocol)
and for the design of [Witness Design](https://github.com/hnacimiento/zfs-reblock-worker/wiki/Witness-Design) (pending, not to be
built yet).

## Index

- `01-batchW-auto-resume-fio-real.txt` — full log of the run: from the
  space check to final cleanup, including the worker's complete log with
  both pause/resume transitions.

## Closing

With this, `--auto-resume` is now fully validated: both in the simulated
lab (5 deterministic unit tests, both paths: recovers on its own / gives up
on timeout) and against real pressure on a production server. No code
changes in this round.
