#!/bin/bash
#
# host-only-guard.sh - stops the sandbox agent running commands that cannot work here.
#
# Guarantees:
#   - a Bash command matching an entry in /usr/local/etc/host-only-commands.txt
#     never executes inside the container;
#   - the agent is handed that entry's explanation and host-side remedy, plus
#     the exact command it tried, instead of an opaque network or auth failure;
#   - a command matching no entry is passed through untouched and silently.
#
# This is NOT a containment mechanism. The firewall and the read-only rootfs
# contain the agent; a listed command stays blocked at the network layer
# whether or not this guard runs. The guard's job is to turn a confusing
# failure into a clear handoff, so it is deliberately easy to bypass on
# purpose (HOST_ONLY_GUARD_BYPASS=1) and makes no attempt to defeat an agent
# that is trying to evade it.
#
# Invocation: registered as a PreToolUse hook for the Bash tool in the managed
# settings baked into the image. Claude Code writes the tool-input JSON to
# stdin. Exit 0 allows the call; exit 2 blocks it and feeds stderr back to the
# model. Exit 2 is used rather than a JSON permissionDecision because it is the
# oldest and least version-dependent PreToolUse blocking contract, and because
# it does not go through the permission system at all - the container runs with
# --dangerously-skip-permissions, so anything the permission mode can switch
# off is not a mechanism here.
#
# Also runnable standalone, which is how verify.sh probes it:
#   echo '{"tool_name":"Bash","tool_input":{"command":"npx wrangler login"}}' | host-only-guard.sh
#
# Usage:
#   host-only-guard.sh              read a hook payload on stdin; exit 0 or 2
#   host-only-guard.sh --check-list validate the list only; exit 0 or 1
#
# Environment:
#   HOST_ONLY_COMMANDS       override the list path (verify.sh uses this to
#                            probe parse failures without touching the real one)
#   HOST_ONLY_GUARD_BYPASS   see below; read out of the *command*, not the
#                            environment, so it applies to one invocation only

set -euo pipefail
export LC_ALL=C

LIST="${HOST_ONLY_COMMANDS:-/usr/local/etc/host-only-commands.txt}"
BYPASS_VAR="HOST_ONLY_GUARD_BYPASS"

# Runner words stripped from the front of a segment so that `npx wrangler login`
# and `wrangler login` are the same command as far as the list is concerned.
# The loop also drops leading VAR=value assignments and the runner's own flags,
# then reduces a path like ./node_modules/.bin/wrangler to its basename.
NORMALIZE_SED=':a
s/^[[:space:]]+//
s/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//
s/^(sudo|command|env|time|nohup|exec)[[:space:]]+//
s/^(npx|bunx|pnpx)[[:space:]]+//
s/^(pnpm|yarn|npm|bun)[[:space:]]+(dlx|exec|x)[[:space:]]+//
s/^-[^[:space:]]+[[:space:]]+//
ta
s#^[^[:space:]]*/##'

# Heredoc bodies are dropped before anything else. The agent is told to quote
# these commands back to the user; if writing one into a README or a notes file
# tripped the guard, the guard would be fighting the behaviour it exists to
# produce. Only the introducing line survives, so `cat > f <<EOF` is still seen.
STRIP_HEREDOCS_AWK='
BEGIN { skip = 0 }
{
  if (skip) {
    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line == delim) skip = 0
    next
  }
  if (match($0, /<<-?[ \t]*("[^"]*"|\047[^\047]*\047|[A-Za-z_][A-Za-z0-9_]*)/)) {
    d = substr($0, RSTART, RLENGTH)
    sub(/^<<-?[ \t]*/, "", d)
    gsub(/["\047]/, "", d)
    delim = d
    skip = 1
  }
  print
}'

# ------------------------------------------------------------------ list ----
#
# Parsing is strict on purpose. An unreadable or malformed policy must not
# degrade into "nothing is host-only" - that is the failure mode this whole
# change exists to remove - so every problem here aborts rather than warns,
# matching init-firewall.sh aborting on a domain it cannot resolve.

# grep exits 1 for "no match" and 2 for a bad regex; only 2 means the pattern
# itself is broken. `|| rc=$?` keeps set -e out of it.
is_valid_ere() {
  local rc=0
  printf %s "" | grep -Eq -- "$1" 2>/dev/null || rc=$?
  [ "$rc" -le 1 ]
}

PATTERNS=()
REMEDIES=()

load_list() {
  local line pat text lineno=0 problems=0

  if [ ! -f "$LIST" ]; then
    printf 'host-only-guard: list not found: %s\n' "$LIST" >&2
    return 1
  fi
  if [ ! -r "$LIST" ]; then
    printf 'host-only-guard: list is not readable: %s\n' "$LIST" >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    # Blank-but-not-empty lines (whitespace only) are ignored too.
    [ -n "${line//[[:space:]]/}" ] || continue

    if [ "$line" = "${line%" :: "*}" ]; then
      printf 'host-only-guard: %s:%d: no " :: " separator\n' "$LIST" "$lineno" >&2
      problems=$((problems + 1))
      continue
    fi

    pat="${line%%" :: "*}"
    text="${line#*" :: "}"
    # Trim surrounding whitespace from both halves.
    pat="$(printf '%s' "$pat" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    text="$(printf '%s' "$text" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

    if [ -z "$pat" ] || [ -z "$text" ]; then
      printf 'host-only-guard: %s:%d: pattern or remedy text is empty\n' "$LIST" "$lineno" >&2
      problems=$((problems + 1))
      continue
    fi

    if ! is_valid_ere "$pat"; then
      printf 'host-only-guard: %s:%d: not a valid POSIX ERE: %s\n' "$LIST" "$lineno" "$pat" >&2
      problems=$((problems + 1))
      continue
    fi

    PATTERNS+=("$pat")
    REMEDIES+=("$text")
  done < "$LIST"

  if [ "$problems" -gt 0 ]; then
    printf 'host-only-guard: %d malformed entr%s in %s\n' \
      "$problems" "$([ "$problems" -eq 1 ] && echo y || echo ies)" "$LIST" >&2
    return 1
  fi

  if [ "${#PATTERNS[@]}" -eq 0 ]; then
    printf 'host-only-guard: %s declares no entries\n' "$LIST" >&2
    return 1
  fi

  return 0
}

# ------------------------------------------------------------- normalize ----

# normalize <command string> -> one normalized segment per line on stdout
normalize() {
  printf '%s\n' "$1" \
    | awk "$STRIP_HEREDOCS_AWK" \
    | sed -E 's/[;&|()]/\n/g' \
    | sed -E "$NORMALIZE_SED" \
    | grep -v '^[[:space:]]*$' || true
}

# ----------------------------------------------------------------- modes ----

if [ "${1:-}" = "--check-list" ]; then
  load_list || exit 1
  printf 'host-only-guard: %s parses (%d entries)\n' "$LIST" "${#PATTERNS[@]}"
  exit 0
fi

if [ $# -gt 0 ]; then
  printf 'host-only-guard: unknown argument: %s\n' "$1" >&2
  exit 1
fi

# ------------------------------------------------------------------ hook ----

PAYLOAD="$(cat)"

# Nothing to inspect: allow. An empty payload is not a policy failure.
[ -n "${PAYLOAD//[[:space:]]/}" ] || exit 0

TOOL=""
COMMAND=""
# Two separate extractions rather than one @tsv: @tsv escapes newlines as a
# literal backslash-n, which would hide the structure of a multi-line command
# (heredocs above all) from the normalizer below.
if TOOL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null)"; then
  COMMAND="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
else
  # The payload did not parse. Failing open would silently disable the policy,
  # so refuse - but keep the escape hatch alive by looking for the bypass token
  # in the raw text, otherwise a payload-format change would brick the session
  # with no way out short of a host-side rebuild.
  if printf '%s' "$PAYLOAD" | grep -q "$BYPASS_VAR="; then
    printf 'host-only-guard: payload unparseable; %s found, allowing.\n' "$BYPASS_VAR" >&2
    exit 0
  fi
  printf 'host-only-guard: could not parse the hook payload, so the host-only\n' >&2
  printf 'policy cannot be applied. Refusing the command rather than ignoring\n' >&2
  printf 'the policy. Prefix the command with %s=1 to run it anyway,\n' "$BYPASS_VAR" >&2
  printf 'and report this - the guard needs updating on the host.\n' >&2
  exit 2
fi

# The hook is registered for Bash, but be explicit rather than assume.
[ "$TOOL" = "Bash" ] || exit 0
[ -n "${COMMAND//[[:space:]]/}" ] || exit 0

# Deliberate single-invocation bypass. Read out of the command string, not the
# environment, so it cannot leak into later commands in the session.
if printf '%s' "$COMMAND" | grep -Eq "(^|[[:space:]])$BYPASS_VAR="; then
  printf 'host-only-guard: %s set - guard bypassed for this command.\n' "$BYPASS_VAR" >&2
  exit 0
fi

load_list || exit 2

mapfile -t SEGMENTS < <(normalize "$COMMAND")

for seg in ${SEGMENTS+"${SEGMENTS[@]}"}; do
  i=0
  while [ "$i" -lt "${#PATTERNS[@]}" ]; do
    if printf '%s\n' "$seg" | grep -Eq -- "^(${PATTERNS[$i]})"; then
      {
        printf 'This command must be run OUTSIDE the sandbox. It was not executed.\n\n'
        printf '  Blocked: %s\n\n' "$COMMAND"
        printf '  Why: %s\n\n' "${REMEDIES[$i]}"
        printf 'Tell the user, in your reply, that this step has to be run in a terminal\n'
        printf 'outside the sandbox, quote the command above verbatim, and give the reason\n'
        printf 'above. Do not retry it, do not reword it to get past this guard, and do not\n'
        printf 'silently substitute another way of achieving the same thing. Carry on with\n'
        printf 'whatever else the task needs and say which steps you left for the host.\n\n'
        printf 'Declared in %s. If that entry is wrong, prefixing the command with\n' "$LIST"
        printf '%s=1 runs it anyway, for this one invocation.\n' "$BYPASS_VAR"
      } >&2
      exit 2
    fi
    i=$((i + 1))
  done
done

exit 0
