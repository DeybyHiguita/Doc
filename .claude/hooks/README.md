# Guardarraíl de términos prohibidos

Impide que se escriban en este repositorio nombres que deben ir siempre como **DOC**.

## Piezas

| Archivo | Rol |
|---|---|
| `forbidden-terms.txt` | Lista `termino\|reemplazo`. Único lugar del repo donde puede aparecer un término prohibido. |
| `forbidden-terms.sh` | Hook `PreToolUse` (bloquea) y escáner manual (`--scan`). |
| `../settings.json` | Registra el hook para `Write`, `Edit` y `Bash`. |

## Cómo funciona

Antes de cada `Write`, `Edit` o `Bash`, el hook revisa el contenido (`content`, `new_string`,
`command`, `file_path`). Si encuentra un término de la lista — sin distinguir mayúsculas —
deniega la operación y devuelve el reemplazo correcto.

## Agregar un término

Edita `forbidden-terms.txt`:

```
TerminoProhibido|Reemplazo
```

Los archivos bajo `.claude/hooks/` están excluidos de la revisión: es la única vía para
mantener la propia lista sin que el hook se bloquee a sí mismo.

## Revisar lo que ya está escrito

```bash
.claude/hooks/forbidden-terms.sh --scan .
```

Sale con código `1` si encuentra ocurrencias, así que sirve tal cual en CI o en un
`pre-commit` de git:

```bash
# .git/hooks/pre-commit
#!/bin/sh
exec .claude/hooks/forbidden-terms.sh --scan .
```

## Desactivar

`/hooks` en Claude Code, o borra el bloque `PreToolUse` de `.claude/settings.json`.
