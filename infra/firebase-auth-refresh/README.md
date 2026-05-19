# firebase-auth-refresh

Pipeline replica Firebase Auth prod -> beta y dev. Filtrado a TI + backoffice.

## Modos

| MODE | Proyecto | Acción |
|---|---|---|
| `export-prod` | vr-portal-fb | DB prod: SELECT users + 4 TI investor. Firebase listUsers. Sube whitelist.json + prod-users-full.json al bucket |
| `import-beta` | vr-portal-fb-beta | Lee bucket, drop firebase beta, importUsers filtrados con signerKey prod |
| `import-dev` | vr-portal-fb-dev | Igual que beta pero target dev |

## Variables esperadas

- `MODE` (requerido)
- `PROJECT_ID` (requerido)
- `BUCKET` (requerido, ej `gs://vr-portal-fb-sql-refresh`)
- `BUCKET_PREFIX` (default `firebase-auth/`)
- `DB_URL_SECRET` (solo export-prod, ej `prod_ms_identity_database_url`)

## Filtro

- 22 cuentas de tabla `users` prod (backoffice + admin + superadmin)
- 4 cuentas TI hardcoded en script (Julian, Samuel, Ericx, Adrián)
- Total: 26 usuarios importados a beta y dev

## SignerKey

Pasa signerKey de prod al `importUsers` via `UserImportOptions.hash`. Firebase auth target acepta login con password de prod. Tras primer login exitoso re-hashea con signerKey local destino.

## Trigger

Solo manual via workflow GitHub Actions `firebase-auth-refresh-beta.yml` / `firebase-auth-refresh-dev.yml` con `confirm=YES`.
