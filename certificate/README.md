# Certificado de firma de documentos

Certificado público (autofirmado) usado para firmar digitalmente los PDF de
este proyecto bajo `document/`. **Nunca contiene ni referencia la clave
privada** — eso permanece fuera de cualquier repositorio, bajo control
exclusivo del autor.

```
Autor:
Hernán Dario Nacimiento

GitHub:
https://github.com/hnacimiento

Certificado de firma (SHA-256 fingerprint):
06:9B:24:9F:2C:93:E1:D5:C2:FC:E3:4C:79:F2:DD:8B:35:3C:76:CB:E9:3A:BF:9D:10:7B:81:A2:D0:0D:58:B4

Certificado:
hernan-nacimiento-signing.crt
```

## Verificar un PDF firmado

1. Confirmar que el fingerprint SHA-256 de `hernan-nacimiento-signing.crt`
   coincide con el publicado arriba (`openssl x509 -in
   hernan-nacimiento-signing.crt -noout -fingerprint -sha256`).
2. Verificar la firma del PDF contra ese certificado exacto — cualquier
   validador PAdES/PDF estándar (Adobe Acrobat, `pyhanko sign validate`,
   etc.) sirve.

Este mismo certificado se reutiliza en los distintos proyectos personales
del autor — no es específico de `zfs-reblock-worker`. Es autofirmado a
propósito: no depende de una autoridad certificadora externa, la identidad
se verifica por continuidad (mismo certificado, mismo fingerprint, usado
consistentemente) y por la referencia pública a `github.com/hnacimiento`
incluida en el propio certificado (Subject Alternative Name).
