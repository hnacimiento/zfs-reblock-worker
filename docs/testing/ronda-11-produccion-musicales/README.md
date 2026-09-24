# Ronda 11 — primera corrida real sobre producción (`Musicales`)

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Primera vez que el worker corre sobre archivos de producción reales, en su
lugar, sin copias descartables de por medio. Autorizado explícitamente por
el operador, con `Musicales` como directorio elegido de la lista de
candidatos de la ronda anterior (14 GiB, 199 archivos, todos de 2002-2003,
ninguno en uso al momento de la corrida).

## Resultado

- **Inventario completo antes de tocar nada**: 199 archivos, 14.33 GiB,
  hash SHA-256 de cada uno guardado como referencia.
- **Corrida real**: `--adaptive guarded --integrity maximum` (máxima
  confianza, dado que es producción real). Solo **1 de 199** archivos
  superó el umbral por defecto (2 GiB) y calificó como candidato — el resto
  del directorio son archivos más chicos, correctamente dejados fuera del
  inventario sin tocarse.
- **Ese candidato se reescribió con éxito**: 0 fallos, inode cambió
  (165770 nuevo), tamaño/mtime/hash idénticos antes y después.
- **Verificación manual sobre el archivo real** (`Álbum de Ejemplo
  [...].ratDVD`, 2.19 GiB): `mtime` preservado exacto
  (2007-04-22, la fecha original, no la de la corrida), ACL NFSv4 idéntica
  y consistente con el resto del pool, y **`zdb -O` confirma `dblk=1M`** —
  el archivo real adoptó el recordsize del dataset.
- **199/199 archivos verificados** al final: mismo tamaño, mismo mtime,
  mismo hash que el inventario inicial (los 198 no candidatos, sin tocar;
  el candidato, reescrito con contenido idéntico).

## Dos errores propios de scripting, documentados sin maquillar

Ninguno afectó la integridad de los datos reales — los dos fueron fallas en
**mi** script de verificación, no en el worker:

1. **Word-splitting en la muestra de ACL** (`for f in $SAMPLE` sin
   comillas): los nombres de archivo con espacios se partieron palabra por
   palabra, así que la comparación automática de ACL antes/después de la
   corrida (`X2`/`X8` del log) quedó inválida — comparaba fragmentos de
   rutas inexistentes contra sí mismos, dando un falso "OK" vacío de
   contenido. Corregido con una verificación manual posterior, con las
   comillas puestas correctamente, contra el archivo real que sí se
   reescribió (ver `02-verificacion-manual-hillsong.txt`).
2. **Limpieza demasiado agresiva**: el job quedó pausado (código 13, por
   presión real transitoria durante el propio hasheo del baseline) después
   de terminar su único candidato real — sin trabajo pendiente genuino,
   pero sin haber llegado al camino de salida "0, todo listo". El paso de
   limpieza del script borró el estado del job (`rm -rf .../jobs/ZRW-*`)
   antes de poder confirmarlo con un `--resume` explícito. Sin consecuencia
   real (no quedaba nada más por hacer, y la integridad ya estaba
   verificada de forma independiente), pero es un descuido a evitar: no
   limpiar el estado de un job que no terminó con código 0 sin antes
   intentar cerrarlo.

## Índice

- `01-batchX-reblock-real-musicales.txt` — log completo de la corrida:
  inventario, hash de referencia, la corrida real, y la comparación
  automática (con la nota de que la parte de ACL de ese log específico no
  es confiable por el bug #1 de arriba).
- `02-verificacion-manual-hillsong.txt` — la verificación correcta, hecha a
  mano después, sobre el archivo real reescrito: `stat`, ACL NFSv4 completa,
  y `zdb -O` confirmando `dblk=1M`.

## Cierre

Primer punto de la sección J del `TEST-PLAN.md` cerrado: un subdirectorio
real acotado, con `--adaptive guarded`, muestra de archivos verificada
(hash + metadatos + `zdb`), sin impacto negativo observado sobre el sistema
(load se mantuvo en rango normal durante toda la corrida). Sin cambios de
código — los dos hallazgos de esta ronda fueron errores en mi propio script
de verificación, ya corregidos en el análisis posterior.

---

# English

First time the worker has run against real production files, in place, with
no disposable copies involved. Explicitly authorized, with `Musicales`
chosen from the previous round's list of candidate directories (14 GiB, 199
files, all from 2002-2003, none in use at the time of the run).

## Result

- **Full inventory before touching anything**: 199 files, 14.33 GiB, SHA-256
  hash of each one saved as a reference.
- **Real run**: `--adaptive guarded --integrity maximum` (maximum
  confidence, given that this is real production). Only **1 of 199** files
  exceeded the default threshold (2 GiB) and qualified as a candidate — the
  rest of the directory is smaller files, correctly left out of the
  inventory untouched.
- **That candidate was successfully rewritten**: 0 failures, inode changed
  (new 165770), size/mtime/hash identical before and after.
- **Manual verification on the real file** (`Sample Album
  [...].ratDVD`, 2.19 GiB): `mtime` preserved exactly
  (2007-04-22, the original date, not the run's date), NFSv4 ACL identical
  and consistent with the rest of the pool, and **`zdb -O` confirms
  `dblk=1M`** — the real file adopted the dataset's recordsize.
- **199/199 files verified** at the end: same size, same mtime, same hash
  as the initial inventory (the 198 non-candidates, untouched; the
  candidate, rewritten with identical content).

## Two mistakes of my own in the scripting, documented without polish

Neither affected the integrity of the real data — both were failures in
**my** verification script, not in the worker:

1. **Word-splitting in the ACL sample** (`for f in $SAMPLE` without quotes):
   file names with spaces got split word by word, so the automatic
   before/after ACL comparison (`X2`/`X8` in the log) ended up invalid — it
   compared fragments of nonexistent paths against themselves, producing a
   false, content-empty "OK". Fixed with a subsequent manual verification,
   with the quotes correctly in place, against the real file that was
   actually rewritten (see `02-verificacion-manual-hillsong.txt`).
2. **Cleanup that was too aggressive**: the job ended up paused (code 13,
   due to real transient pressure during the baseline hashing itself) after
   finishing its one real candidate — with no genuine work left pending, but
   without having reached the "0, all done" exit path. The script's cleanup
   step deleted the job's state (`rm -rf .../jobs/ZRW-*`) before it could be
   confirmed with an explicit `--resume`. No real consequence (there was
   nothing else left to do, and integrity had already been verified
   independently), but it's an oversight to avoid: don't clean up the state
   of a job that didn't finish with exit code 0 without first trying to
   close it out.

## Index

- `01-batchX-reblock-real-musicales.txt` — full log of the run: inventory,
  reference hash, the real run, and the automatic comparison (with the note
  that the ACL portion of this specific log isn't reliable due to bug #1
  above).
- `02-verificacion-manual-hillsong.txt` — the correct verification, done by
  hand afterward, on the real rewritten file: `stat`, full NFSv4 ACL, and
  `zdb -O` confirming `dblk=1M`.

## Close-out

First item of section J of `TEST-PLAN.md` closed: a bounded real
subdirectory, with `--adaptive guarded`, a sample of files verified (hash +
metadata + `zdb`), with no negative impact observed on the system (load
stayed in normal range throughout the run). No code changes — both findings
in this round were mistakes in my own verification script, already fixed in
the follow-up analysis.
