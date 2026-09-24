# Security Policy

**[Leer en español ↓](#español)** · **[Read in English ↓](#english)**

---

# Español

Este worker escribe sobre datos reales en producción. Un bug de seguridad
acá no es abstracto: puede significar pérdida o corrupción de datos.

## Reportar una vulnerabilidad

Abrí un [issue](https://github.com/hnacimiento/zfs-reblock-worker/issues)
describiendo el problema — qué invariante del
[contrato de seguridad](https://github.com/hnacimiento/zfs-reblock-worker#contrato-de-seguridad)
se ve afectada, y cómo reproducirlo. Si el hallazgo es explotable de forma
inmediata contra un dataset real (no un escenario de laboratorio), indicalo
en el título para poder priorizarlo.

No hace falta un canal privado para esto: el proyecto es de un solo
mantenedor y todo el desarrollo ya es público.

## Alcance

Cubre `zfs-reblock-worker.sh` y los scripts de `remote/`. Quedan afuera los
documentos formales de `document/` y el certificado de `certificate/` — para
un problema con la firma digital de esos archivos, ver la verificación
descrita en `certificate/README.md`.

---

# English

This worker writes to real production data. A security bug here isn't
abstract: it can mean real data loss or corruption.

## Reporting a vulnerability

Open an [issue](https://github.com/hnacimiento/zfs-reblock-worker/issues)
describing the problem — which invariant of the
[safety contract](https://github.com/hnacimiento/zfs-reblock-worker#safety-contract)
is affected, and how to reproduce it. If the finding is immediately
exploitable against a real dataset (not a lab-only scenario), say so in the
title so it can be prioritized.

No private channel is needed for this: the project has a single maintainer
and all development is already public.

## Scope

Covers `zfs-reblock-worker.sh` and the scripts under `remote/`. Out of
scope: the formal documents under `document/` and the certificate under
`certificate/` — for an issue with those files' digital signature, see the
verification steps in `certificate/README.md`.
