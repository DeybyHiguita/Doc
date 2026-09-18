#!/usr/bin/env bash
# Guardarraíl de términos prohibidos.
#
#   Modo hook  (sin argumentos, recibe el JSON de PreToolUse por stdin):
#     bloquea Write / Edit / Bash cuando el contenido incluye un término prohibido.
#
#   Modo escaneo:
#     .claude/hooks/forbidden-terms.sh --scan [directorio]
#     recorre los archivos del repo y reporta ocurrencias. Sale con 1 si encuentra alguna.
#
# Los términos se definen en forbidden-terms.txt (termino|reemplazo).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERMS_FILE="$HOOK_DIR/forbidden-terms.txt"

load_terms() {
  [ -f "$TERMS_FILE" ] || return 0
  grep -v '^[[:space:]]*#' "$TERMS_FILE" | grep -v '^[[:space:]]*$'
}

# ─── Modo escaneo ────────────────────────────────────────────────────────────
if [ "${1:-}" = "--scan" ]; then
  target="${2:-.}"
  status=0
  while IFS='|' read -r term replacement; do
    [ -n "${term:-}" ] || continue
    matches=$(grep -rniI --exclude-dir=.git --exclude-dir=.claude -- "$term" "$target" 2>/dev/null) || true
    if [ -n "$matches" ]; then
      printf 'Termino prohibido "%s" (usar "%s"):\n%s\n\n' "$term" "$replacement" "$matches"
      status=1
    fi
  done < <(load_terms)
  [ "$status" -eq 0 ] && echo "OK: no se encontraron terminos prohibidos."
  exit "$status"
fi

# ─── Modo hook ───────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

payload=$(printf '%s' "$input" | jq -r '
  [.tool_input.content, .tool_input.new_string, .tool_input.command, .tool_input.file_path]
  | map(select(type == "string")) | join("\n")' 2>/dev/null) || exit 0

# Escape hatch: mantener y editar la propia lista de términos.
case "$payload" in
  *.claude/hooks/*) exit 0 ;;
esac

while IFS='|' read -r term replacement; do
  [ -n "${term:-}" ] || continue
  if printf '%s' "$payload" | grep -qi -- "$term"; then
    jq -n --arg t "$term" --arg r "${replacement:-}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("Termino prohibido en este repositorio: \"" + $t + "\". Usa \"" + $r + "\" en su lugar y reintenta la operacion.")
      }
    }'
    exit 0
  fi
done < <(load_terms)

exit 0
