#!/bin/bash
#
# verify.sh - post-start verification for the Claude Code sandbox.
#
# Asserts that the egress firewall installed by init-firewall.sh is actually
# doing its job:
#
#   1. example.com is unreachable over both HTTP and HTTPS
#   2. `git push` is impossible over SSH and over HTTPS (no credentials)
#   3. The Anthropic endpoints Claude Code needs are reachable
#   4. iptables is in whitelist mode (OUTPUT policy is DROP)
#
# Prints "VERIFIED" and exits 0 when every required check passes, otherwise
# prints a summary of the failures and exits 1.
#
# Usage:
#   verify.sh                  run every check
#   verify.sh --iptables-only  run only the iptables checks; used internally to
#                              re-exec this script under sudo, since reading the
#                              iptables ruleset requires root

set -uo pipefail
export LC_ALL=C

CONNECT_TIMEOUT=5
MAX_TIME=15

PASS=0
FAIL=0
WARN=0
FAILED_CHECKS=()

# ---------------------------------------------------------------- output ----

if [ -n "${VERIFY_FORCE_COLOR:-}" ] || { [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; }; then
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'
  C_C=$'\033[36m'; C_B=$'\033[1m';  C_0=$'\033[0m'
else
  C_G=""; C_R=""; C_Y=""; C_C=""; C_B=""; C_0=""
fi

section() { printf '\n%s%s== %s ==%s\n' "$C_B" "$C_C" "$1" "$C_0"; }
ok()      { printf '  %s[ PASS ]%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS + 1)); }
warn()    { printf '  %s[ WARN ]%s %s\n' "$C_Y" "$C_0" "$1"; WARN=$((WARN + 1)); }
bad()     { printf '  %s[ FAIL ]%s %s\n' "$C_R" "$C_0" "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS+=("$1"); }
info()    { printf '           %s\n' "$1"; }

# ------------------------------------------------------------ privileges ----
#
# Reading the iptables ruleset needs root. The Dockerfile grants the `node`
# user a passwordless sudo entry for /usr/local/bin/verify.sh (and nothing
# else), so when we cannot reach iptables directly we re-exec ourselves under
# sudo in --iptables-only mode.

SELF="/usr/local/bin/verify.sh"
[ -x "$SELF" ] || SELF="$(readlink -f "$0")"

IPT=""
IPSET=""
if [ "$(id -u)" -eq 0 ]; then
  IPT="iptables"
  command -v ipset >/dev/null 2>&1 && IPSET="ipset"
elif sudo -n iptables -S OUTPUT >/dev/null 2>&1; then
  IPT="sudo -n iptables"
  sudo -n ipset list -n >/dev/null 2>&1 && IPSET="sudo -n ipset"
fi

# ---------------------------------------------------------- curl helpers ----
#
# `%{time_connect}` is the reliable signal for "did the TCP handshake
# complete". Relying on curl's exit code alone is wrong: a TLS or certificate
# error (exit 35/60) happens *after* a successful connect, so it would
# otherwise be mistaken for a blocked host.

CURL_BASE=(-sS -o /dev/null --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME")

# _probe <url> [extra curl args...] -> sets PROBE_RC, PROBE_CONNECT, PROBE_CODE, PROBE_ERR
_probe() {
  local url="$1"; shift
  local errf out
  errf=$(mktemp)
  out=$(curl "${CURL_BASE[@]}" "$@" -w '%{time_connect} %{http_code}' "$url" 2>"$errf")
  PROBE_RC=$?
  PROBE_ERR=$(tr -d '\r' <"$errf" | head -n 1 | cut -c1-160)
  rm -f "$errf"
  PROBE_CONNECT="${out%% *}"
  PROBE_CODE="${out##* }"
  [ -n "$PROBE_CONNECT" ] || PROBE_CONNECT=0
  [ -n "$PROBE_CODE" ] || PROBE_CODE=000
}

_connected() { awk -v t="${PROBE_CONNECT:-0}" 'BEGIN { exit !(t + 0 > 0) }'; }

# check_unreachable <url> <label> [extra curl args...]
# Passes only when the TCP connection never completed.
check_unreachable() {
  local url="$1" label="$2"; shift 2
  _probe "$url" "$@"

  if [ "$PROBE_RC" -eq 0 ]; then
    bad "$label is REACHABLE (HTTP $PROBE_CODE) - egress is not blocked"
    return 1
  fi

  if _connected; then
    bad "$label accepted a TCP connection in ${PROBE_CONNECT}s - egress is not blocked"
    info "curl failed later (exit $PROBE_RC: $PROBE_ERR), but the host was reached"
    return 1
  fi

  if [ "$PROBE_RC" -eq 6 ]; then
    ok "$label is not reachable (DNS resolution failed)"
    info "note: blocked at DNS rather than by an iptables rule"
  else
    ok "$label is not reachable (no TCP connect, curl exit $PROBE_RC)"
  fi
  return 0
}

# check_reachable <url> <label> <required|optional>
# Passes when the host answers with any HTTP status: a 401/403/405 still
# proves the request traversed the firewall.
check_reachable() {
  local url="$1" label="$2" mode="$3"
  _probe "$url"

  if [ "$PROBE_RC" -eq 0 ] && [ "$PROBE_CODE" != "000" ]; then
    ok "$label is reachable (HTTP $PROBE_CODE)"
    return 0
  fi

  if [ "$mode" = "required" ]; then
    bad "$label is NOT reachable (curl exit $PROBE_RC) - Claude Code needs this host"
  else
    warn "$label is not reachable (curl exit $PROBE_RC)"
  fi
  [ -n "$PROBE_ERR" ] && info "$PROBE_ERR"
  return 1
}

# ---------------------------------------------------------- git push URLs ----

to_https_url() {
  local u="$1" rest
  case "$u" in
    git@*:*)     rest="${u#git@}"; printf 'https://%s/%s\n' "${rest%%:*}" "${rest#*:}" ;;
    ssh://git@*) printf 'https://%s\n' "${u#ssh://git@}" ;;
    https://*)   printf '%s\n' "$u" ;;
    *)           printf '\n' ;;
  esac
}

to_ssh_url() {
  local u="$1" rest
  case "$u" in
    git@*:*|ssh://*) printf '%s\n' "$u" ;;
    https://*)       rest="${u#https://}"; rest="${rest#*@}"
                     printf 'git@%s:%s\n' "${rest%%/*}" "${rest#*/}" ;;
    *)               printf '\n' ;;
  esac
}

# Turn git's stderr into a short human-readable reason.
classify_push_failure() {
  local out="$1"
  if [ -z "${out//[[:space:]]/}" ]; then
    printf 'timed out with no output\n'
  elif grep -qiE 'cannot run ssh|ssh: (command )?not found|unable to fork' <<<"$out"; then
    printf 'no ssh client installed\n'
  elif grep -qiE 'Permission denied \(publickey|Host key verification failed|publickey|Could not read from remote repository' <<<"$out"; then
    printf 'no usable SSH key\n'
  elif grep -qiE 'could not read Username|could not read Password|terminal prompts disabled|Authentication failed|Invalid username or password' <<<"$out"; then
    printf 'no HTTPS credentials\n'
  elif grep -qiE 'Connection timed out|Could not resolve|Failed to connect|Connection refused|Network is unreachable|prohibited|kex_exchange' <<<"$out"; then
    printf 'network blocked by the firewall\n'
  else
    printf 'push rejected\n'
  fi
}

# attempt_push <url> <label>
# Passes when `git push --dry-run` fails. --dry-run performs the full connect
# and authenticate handshake but never writes to the remote, so this is safe
# to run against a real origin.
attempt_push() {
  local url="$1" label="$2" out rc reason

  out=$(cd "$SCRATCH_REPO" && \
        GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=$CONNECT_TIMEOUT" \
        timeout "$MAX_TIME" git push --dry-run "$url" \
          HEAD:refs/heads/claude-sandbox-verify-probe 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    bad "git push over $label SUCCEEDED - the sandbox can write to $url"
    return 1
  fi

  reason=$(classify_push_failure "$out")
  ok "git push over $label is not possible ($reason)"
  info "remote: $url"
  return 0
}

# ============================================================================
# Check 4, defined first so --iptables-only can reach it: iptables whitelisting
# ============================================================================

check_iptables() {
  section "iptables whitelist mode"

  if [ -z "$IPT" ]; then
    bad "cannot read the iptables ruleset (need root or passwordless sudo)"
    return 1
  fi

  local policies output_rules
  policies=$($IPT -S 2>/dev/null | grep '^-P ')
  if [ -z "$policies" ]; then
    bad "iptables returned no chain policies - is the firewall installed?"
    return 1
  fi

  # The requirement: default-deny egress.
  if grep -q '^-P OUTPUT DROP$' <<<"$policies"; then
    ok "OUTPUT policy is DROP (whitelist mode)"
  else
    bad "OUTPUT policy is $(awk '/^-P OUTPUT/ { print $3 }' <<<"$policies"), expected DROP"
  fi

  if grep -q '^-P INPUT DROP$' <<<"$policies"; then
    ok "INPUT policy is DROP"
  else
    warn "INPUT policy is $(awk '/^-P INPUT/ { print $3 }' <<<"$policies"), expected DROP"
  fi

  if grep -q '^-P FORWARD DROP$' <<<"$policies"; then
    ok "FORWARD policy is DROP"
  else
    warn "FORWARD policy is $(awk '/^-P FORWARD/ { print $3 }' <<<"$policies"), expected DROP"
  fi

  # A DROP policy on its own is not a whitelist: there must also be an allow
  # rule driven by the ipset, or nothing would work at all.
  output_rules=$($IPT -S OUTPUT 2>/dev/null)

  if grep -q -- '--match-set allowed-domains dst -j ACCEPT' <<<"$output_rules"; then
    ok "OUTPUT accepts traffic matching the allowed-domains ipset"
  else
    bad "no OUTPUT ACCEPT rule for the allowed-domains ipset"
  fi

  if grep -qE -- '^-A OUTPUT -j (REJECT|DROP)' <<<"$output_rules"; then
    ok "OUTPUT ends with an explicit catch-all REJECT/DROP rule"
  else
    warn "no catch-all REJECT rule in OUTPUT (relying on the chain policy alone)"
  fi

  if [ -n "$IPSET" ]; then
    local n
    n=$($IPSET list allowed-domains 2>/dev/null | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    if [ "${n:-0}" -gt 0 ]; then
      ok "allowed-domains ipset is populated ($n entries)"
    else
      bad "allowed-domains ipset is missing or empty"
    fi
  fi

  return 0
}

# --iptables-only: run just the iptables checks, then emit a machine-readable
# trailer so the parent process can fold the results into its own summary.
if [ "${1:-}" = "--iptables-only" ]; then
  check_iptables
  for c in ${FAILED_CHECKS+"${FAILED_CHECKS[@]}"}; do printf '__VERIFY_FAILED__ %s\n' "$c"; done
  printf '__VERIFY_COUNTS__ %d %d %d\n' "$PASS" "$FAIL" "$WARN"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# ============================================================================
# Main
# ============================================================================

printf '%s%sClaude Code sandbox verification%s\n' "$C_B" "$C_C" "$C_0"
printf 'host: %s   user: %s   date: %s\n' "$(hostname)" "$(id -un)" "$(date -Is)"

# ---------------------------------------------------------------------------
# Check 1: arbitrary internet egress is blocked
# ---------------------------------------------------------------------------
section "Blocked egress (example.com must be unreachable)"

check_unreachable "http://example.com"  "example.com over HTTP (port 80)"
check_unreachable "https://example.com" "example.com over HTTPS (port 443)"

# Probe the resolved address directly as well, so that a DNS quirk cannot make
# the checks above pass for the wrong reason. Plain HTTP with an explicit Host
# header keeps TLS out of the picture.
EXAMPLE_IP=$(getent ahostsv4 example.com 2>/dev/null | awk 'NR == 1 { print $1 }')
if [ -n "$EXAMPLE_IP" ]; then
  check_unreachable "http://$EXAMPLE_IP/" "example.com by IP ($EXAMPLE_IP:80)" -H "Host: example.com"
else
  info "example.com did not resolve; skipping the by-IP probe"
fi

# ---------------------------------------------------------------------------
# Check 2: git push is impossible (no credentials)
# ---------------------------------------------------------------------------
section "git push must fail (no credentials)"

REPO_ROOT=$(git -C "${WORKSPACE_DIR:-/workspace}" rev-parse --show-toplevel 2>/dev/null \
            || git rev-parse --show-toplevel 2>/dev/null || true)
ORIGIN_URL=""
[ -n "$REPO_ROOT" ] && ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)

SSH_PUSH_URL=""
HTTPS_PUSH_URL=""
if [ -n "$ORIGIN_URL" ]; then
  SSH_PUSH_URL=$(to_ssh_url "$ORIGIN_URL")
  HTTPS_PUSH_URL=$(to_https_url "$ORIGIN_URL")
  info "origin: $ORIGIN_URL"
else
  info "no git origin found; probing github.com directly"
fi
[ -n "$SSH_PUSH_URL" ]   || SSH_PUSH_URL="git@github.com:anthropics/claude-code.git"
[ -n "$HTTPS_PUSH_URL" ] || HTTPS_PUSH_URL="https://github.com/anthropics/claude-code.git"

# Report the credential material that is visible, so a failure is attributable.
SSH_KEYS=$(ls -1 "$HOME"/.ssh/id_* 2>/dev/null | grep -cv '\.pub$')
if [ "${SSH_KEYS:-0}" -gt 0 ]; then
  warn "$SSH_KEYS SSH private key(s) present in \$HOME/.ssh"
elif [ -n "${SSH_AUTH_SOCK:-}" ]; then
  warn "SSH_AUTH_SOCK is set ($SSH_AUTH_SOCK) - an agent may forward keys in"
else
  ok "no SSH private keys in \$HOME/.ssh and no ssh-agent socket"
fi

CRED_HELPER=$(git config --get credential.helper 2>/dev/null || true)
if [ -n "$CRED_HELPER" ]; then
  warn "a git credential helper is configured: $CRED_HELPER"
else
  ok "no git credential helper is configured"
fi

# Push from a scratch repository so the probes never touch the real work tree.
SCRATCH_DIR=$(mktemp -d)
SCRATCH_REPO="$SCRATCH_DIR/probe"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

if git init -q -b main "$SCRATCH_REPO" 2>/dev/null && \
   git -C "$SCRATCH_REPO" -c user.email=verify@localhost -c user.name=verify \
       commit -q --allow-empty -m "sandbox verification probe" 2>/dev/null; then
  attempt_push "$SSH_PUSH_URL"   "SSH"
  attempt_push "$HTTPS_PUSH_URL" "HTTPS"
else
  bad "could not create the scratch repository for the git push probes"
fi

# ---------------------------------------------------------------------------
# Check 3: the Anthropic endpoints Claude Code needs are reachable
# ---------------------------------------------------------------------------
section "Anthropic endpoints must be reachable"

# The API is the only hard requirement: without it Claude Code cannot run.
# An unauthenticated request returns 401/405, which is proof of reachability.
check_reachable "https://api.anthropic.com/v1/messages" "api.anthropic.com (API)" required

# Supporting services. Losing these degrades Claude Code but does not break it,
# so they are warnings rather than failures.
check_reachable "https://statsig.com"                        "statsig.com (feature flags)"           optional
check_reachable "https://sentry.io"                          "sentry.io (error reporting)"           optional
check_reachable "https://registry.npmjs.org/-/ping"          "registry.npmjs.org (updates)"          optional
check_reachable "https://api.github.com/zen"                 "api.github.com"                        optional

# ---------------------------------------------------------------------------
# Check 4: iptables whitelist mode
# ---------------------------------------------------------------------------
if [ -n "$IPT" ]; then
  check_iptables
else
  # No direct access; re-exec under sudo and fold the child's counts in.
  IPT_OUT=$(VERIFY_FORCE_COLOR="${C_B:+1}" sudo -n "$SELF" --iptables-only 2>&1)
  IPT_RC=$?

  if grep -q '^__VERIFY_COUNTS__ ' <<<"$IPT_OUT"; then
    printf '%s\n' "$IPT_OUT" | grep -v '^__VERIFY_'
    read -r _ p f w < <(grep '^__VERIFY_COUNTS__ ' <<<"$IPT_OUT")
    PASS=$((PASS + p)); FAIL=$((FAIL + f)); WARN=$((WARN + w))
    while IFS= read -r line; do
      FAILED_CHECKS+=("${line#__VERIFY_FAILED__ }")
    done < <(grep '^__VERIFY_FAILED__ ' <<<"$IPT_OUT")
  else
    # No counts trailer means the check never actually ran: sudo refused, or
    # /usr/local/bin/verify.sh is a stale copy of this script. Fail loudly.
    section "iptables whitelist mode"
    if [ "$IPT_RC" -ne 0 ]; then
      bad "could not inspect iptables (run as root, or via 'sudo $SELF')"
    else
      bad "'sudo $SELF --iptables-only' returned no results - is $SELF a stale copy?"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s%s== Summary ==%s\n' "$C_B" "$C_C" "$C_0"
printf '  %spassed: %d%s   %swarnings: %d%s   %sfailed: %d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"

if [ "$FAIL" -gt 0 ]; then
  printf '\n%sFailed checks:%s\n' "$C_R" "$C_0"
  for c in "${FAILED_CHECKS[@]}"; do printf '  - %s\n' "$c"; done
  printf '\n%sNOT VERIFIED%s - the sandbox is not in the expected state.\n' "$C_R$C_B" "$C_0"
  exit 1
fi

printf '\n%sVERIFIED%s\n' "$C_G$C_B" "$C_0"
exit 0
