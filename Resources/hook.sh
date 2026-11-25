#!/bin/sh
# Aura — pont entre les hooks des agents et l'app.
#
#   hook.sh claude <Événement>     JSON du hook sur stdin (Claude Code)
#   hook.sh cursor <événement>     JSON du hook sur stdin (Cursor)
#   hook.sh codex '<json>'         Codex ajoute le JSON en dernier argument (notify)
#
# Règle d'or : ne jamais bloquer l'agent. Si Aura ne répond pas, on sort sans rien décider.
# Le JSON brut de l'agent est transmis tel quel à Aura (clé "raw") : la lecture des champs
# se fait dans l'app (HookPayload.swift). Les formats de SORTIE attendus par chaque agent
# sont tous dans ce fichier, dans les fonctions claude_decision et cursor_permission.

AURA_PORT=47823
AURA_WAIT=310
[ -r "$HOME/.aura/config.sh" ] && . "$HOME/.aura/config.sh"

BASE="http://127.0.0.1:${AURA_PORT}"
SOURCE="${1:-other}"
KIND="${2:-}"
# Identifiant de l'app qui héberge l'agent (Terminal, iTerm, Cursor…), hérité de macOS.
APP=$(printf '%s' "${__CFBundleIdentifier:-}" | tr -cd 'A-Za-z0-9._-')

command -v curl >/dev/null 2>&1 || exit 0

if [ "$SOURCE" = "codex" ]; then
  LAST=""
  for LAST in "$@"; do :; done
  PAYLOAD="$LAST"
  KIND="notify"
else
  PAYLOAD=$(cat)
fi

# On n'envoie que ce qui ressemble à un objet JSON.
case "$PAYLOAD" in
  "{"*) ;;
  *) PAYLOAD='{}' ;;
esac

body() {
  printf '{"source":"%s","hook":"%s","app":"%s","raw":%s}' "$SOURCE" "$KIND" "$APP" "$PAYLOAD"
}

# Événement simple : envoi court, aucune sortie.
send_event() {
  body | curl -s -o /dev/null --connect-timeout 1 --max-time 2 \
    -H 'Content-Type: application/json' -H 'Expect:' \
    --data-binary @- "$BASE/event" >/dev/null 2>&1
  return 0
}

# Demande de validation : bloque jusqu'à la réponse d'Aura.
# Affiche allow, deny, ask ou pass (pass = Aura n'a pas d'avis ou ne répond pas).
ask_aura() {
  RESP=$(body | curl -s --connect-timeout 1 --max-time "$AURA_WAIT" \
    -H 'Content-Type: application/json' -H 'Expect:' \
    --data-binary @- "$BASE/approve" 2>/dev/null) || RESP=""
  case "$RESP" in
    *'"decision":"allow"'*) echo allow ;;
    *'"decision":"deny"'*)  echo deny ;;
    *'"decision":"ask"'*)   echo ask ;;
    *)                      echo pass ;;
  esac
}

# --- Format de sortie Claude Code (PreToolUse) --------------------------------
# https://code.claude.com/docs/en/hooks : hookSpecificOutput.permissionDecision
claude_decision() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
}

# --- Format de sortie Cursor (beforeShellExecution) ---------------------------
# https://cursor.com/docs/agent/hooks : permission allow | deny | ask
cursor_permission() {
  if [ -n "${2:-}" ]; then
    printf '{"permission":"%s","user_message":"%s","agent_message":"%s"}\n' "$1" "$2" "$2"
  else
    printf '{"permission":"%s"}\n' "$1"
  fi
}

case "$SOURCE:$KIND" in
  claude:PreToolUse)
    DECISION=$(ask_aura)
    case "$DECISION" in
      allow) claude_decision allow "Autorise depuis Aura" ;;
      deny)  claude_decision deny "Refuse depuis Aura" ;;
      ask)   claude_decision ask "Aura te laisse trancher" ;;
      *)     : ;; # pass : aucune sortie, Claude Code suit son flux normal
    esac
    exit 0
    ;;
  cursor:beforeShellExecution)
    DECISION=$(ask_aura)
    case "$DECISION" in
      allow) cursor_permission allow ;;
      deny)  cursor_permission deny "Refuse depuis Aura" ;;
      *)     cursor_permission ask ;; # ask ou pass : Cursor affiche sa propre demande
    esac
    exit 0
    ;;
  cursor:*)
    send_event
    printf '{}\n'
    exit 0
    ;;
  *)
    send_event
    exit 0
    ;;
esac
