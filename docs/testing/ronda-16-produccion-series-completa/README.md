# Ronda 16 — producción real a escala: `Videos/Series` completo (2.1 TiB)

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

La corrida real más grande y más larga de todo el proyecto hasta ahora, y la
primera vez que el worker corrió sobre un subdirectorio grande sin
supervisión activa minuto a minuto. Arrancó con `--threshold 10M` sobre
`Musicales` completo (cierre de la etapa chica), siguió con `Videos/Series`
(2.1 TiB / 238 archivos, ~17% de los 12 TiB de `toolbox/media`), y terminó
horas después, sola, sin que hiciera falta ninguna intervención final.

## Resultado

**238/238 archivos, 0 fallos, 0 stale, 0 recuperaciones, 0 rollbacks.**
149.6 GiB reescritos (los candidatos que realmente superaban el umbral),
`elapsed_seconds=4623` (~77 min de trabajo efectivo, repartidos en una
ventana de horas por las pausas del governor y un reinicio real en el
medio).

## Cinco bugs reales, cinco arreglos, cero problemas de integridad

Ninguno de los cinco tocó el hash de verificación, el commit atómico ni la
preservación de metadatos — todos vivían en la capa de gobernanza o en el
manejo de configuración al reanudar. Detalle completo en `CHANGELOG.md`:

- **4.4.8** — el ARC de ZFS se leía como memoria "usada" real, inflando la
  presión del governor sin que hubiera ningún problema genuino.
- **4.4.9** — un job resumido mostraba la versión con la que se creó, no la
  que corría de verdad (cosmético).
- **4.4.10** — el governor subía el ancho de banda apenas veía una muestra
  sana, chocando con la siguiente ráfaga periódica de sync de ZFS —
  oscilaba en casi cada archivo.
- **4.4.11** — nuevo aviso: si el dataset vive en un disco USB, se informa
  al arrancar (nunca cambia nada por su cuenta).
- **4.4.12** — un flag explícito en `--resume` (`--adaptive off`) no se
  aplicaba de verdad: `load_config()` lo pisaba con el valor guardado del
  job. El hallazgo más serio de los cinco, encontrado tratando de medir el
  rendimiento real del disco.

## El hallazgo de fondo: el techo bajo no era el disco

Con `fio` aislado (dataset de laboratorio, `Series` pausado), el disco
físico sostuvo ~150-170 MiB/s de escritura secuencial pura. El patrón real
del job (leer + escribir + verificar, todo contra el mismo disco) es
distinto — pero con el governor apagado (`--adaptive off --bwlimit 80M`,
autorizado explícitamente por el operador porque el servidor estaba libre),
archivos reales completaron a **62-64 MiB/s sostenidos**, muy por encima de
los 10-15 MiB/s que el governor elegía por prudencia. Detalle completo,
con los logs crudos del benchmark, en `analisis-disco-usb-zfs/README.md`
(secciones 12-14 y "Candidatos a mejora") — análisis local, no publicado.

## Reinicio real, en el medio, no planeado

Un corte eléctrico reinició la máquina real con el job en 217/238. Al
volver: pool importado sin errores, el archivo que estaba `PROCESSING`
volvió solo a `PENDING` (contrato de invariantes cumplido), sin
temporales huérfanos que rescatar. `--resume` con la misma configuración
completó los 21 archivos restantes sin problema. Es el tercer reinicio real
que este proyecto sobrevive sin pérdida de datos (rondas 12 y este), cada
uno en una etapa distinta del trabajo.

## Cierre

Con esto, la sección J del `TEST-PLAN.md` tiene `Musicales` + `Series`
cerrados (~2.1 TiB de los ~12 TiB de `toolbox/media`). Queda pendiente,
como siempre, la decisión del operador sobre el resto del dataset — no es
un test que falte, es el trabajo real que sigue. Versión final del worker:
**4.4.12**.

---

# English

The largest and longest real run of the entire project so far, and the
first time the worker ran over a large subdirectory without active
minute-by-minute supervision. It started with `--threshold 10M` over the
full `Musicales` (closing out the small stage), continued with
`Videos/Series` (2.1 TiB / 238 files, ~17% of `toolbox/media`'s 12 TiB),
and finished hours later, on its own, with no final intervention needed.

## Result

**238/238 files, 0 failures, 0 stale, 0 recoveries, 0 rollbacks.**
149.6 GiB rewritten (the candidates that actually exceeded the threshold),
`elapsed_seconds=4623` (~77 min of effective work, spread over a window of
hours due to governor pauses and a real reboot in the middle).

## Five real bugs, five fixes, zero integrity problems

None of the five touched the verification hash, the atomic commit, or
metadata preservation — all of them lived in the governance layer or in
configuration handling on resume. Full detail in `CHANGELOG.md`:

- **4.4.8** — ZFS's ARC was being read as real "used" memory, inflating the
  governor's pressure reading with no genuine problem behind it.
- **4.4.9** — a resumed job displayed the version it was created with, not
  the one actually running (cosmetic).
- **4.4.10** — the governor raised bandwidth as soon as it saw one healthy
  sample, colliding with ZFS's next periodic sync burst — it oscillated on
  almost every file.
- **4.4.11** — new warning: if the dataset lives on a USB disk, it's
  reported at startup (it never changes anything on its own).
- **4.4.12** — an explicit flag on `--resume` (`--adaptive off`) wasn't
  actually being applied: `load_config()` overwrote it with the job's saved
  value. The most serious finding of the five, found while trying to
  measure the disk's real throughput.

## The underlying finding: the low ceiling wasn't the disk

With isolated `fio` (lab dataset, `Series` paused), the physical disk
sustained ~150-170 MiB/s of pure sequential write throughput. The job's
real pattern (read + write + verify, all against the same disk) is
different — but with the governor turned off (`--adaptive off --bwlimit
80M`, explicitly authorized by the operator because the server was free),
real files completed at **62-64 MiB/s sustained**, well above the
10-15 MiB/s the governor chose out of caution. Full detail, with the raw
benchmark logs, in `analisis-disco-usb-zfs/README.md` (sections 12-14 and
"Candidates for improvement") — local analysis, not published.

## A real reboot, in the middle, unplanned

A power outage rebooted the real machine with the job at 217/238. On
return: pool imported with no errors, the file that had been `PROCESSING`
reverted on its own to `PENDING` (invariants contract honored), with no
orphaned temp files to rescue. `--resume` with the same configuration
completed the remaining 21 files with no problem. This is the third real
reboot this project has survived with no data loss (rounds 12 and this
one), each at a different stage of the work.

## Closing

With this, section J of `TEST-PLAN.md` has `Musicales` + `Series` closed
out (~2.1 TiB of `toolbox/media`'s ~12 TiB). Pending, as always, is the
operator's decision on the rest of the dataset — it's not a missing test,
it's the real work still ahead. Final worker version: **4.4.12**.
