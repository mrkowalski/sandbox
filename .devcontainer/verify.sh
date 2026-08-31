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
#   5. Firewall installation was anchored to this container start, so a
#      restart cannot bring the container back unprotected
#
# and that the writable mounts the container is granted are the ones intended,
# and no more:
#
#   6. npm's cache directory is writable *and* exec-capable
#   7. The rootfs outside those mounts is still read-only
#
# and that the sandbox tells the agent which commands cannot work in here,
# rather than leaving it to find out by running them:
#
#   8. The host-only command list is installed, and the guard that enforces
#      it blocks a declared command and passes an ordinary one
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
# Check 5: firewall installation is anchored to container start
# ---------------------------------------------------------------------------
#
# The ruleset being correct right now says nothing about *how* it got that way.
# postStartCommand runs only when the devcontainer CLI launches the container;
# `docker start`, a Desktop restart button, or a restart after a host reboot
# brings the container back with a fresh, empty network namespace and never runs
# it. The image ENTRYPOINT is what covers those, and this check is how a
# container that came up without it gets caught instead of quietly running open.
#
# /tmp is a tmpfs, recreated empty on every start, so the marker being present
# means the entrypoint ran *this* start - not that it ran once, long ago.
#
# Stated plainly for whoever reads this next: the marker is a configuration
# check, not an attestation. The agent runs as `node`, /tmp is writable, and it
# could create the file itself. That is acceptable and is not what this is for -
# verify.sh exists to catch a sandbox that was built or started wrong, and the
# containment boundary is netfilter and the read-only rootfs, not this file.
section "Firewall installation must run at every container start"

FIREWALL_MARKER=/tmp/.sandbox-firewall-installed

if [ -f "$FIREWALL_MARKER" ]; then
  ok "the image entrypoint installed the firewall for this container start"
else
  bad "no entrypoint marker ($FIREWALL_MARKER) - the firewall was not installed at start"
  info "the container was started by something that bypassed the image ENTRYPOINT,"
  info "or from an image built before it existed; a restart of such a container"
  info "comes back with an empty ruleset and nothing to report it"
  info "first thing to check: devcontainer.json still sets \"overrideCommand\": false"
fi

# Nulls and newlines are squashed to keep the whole command on one line.
PID1_CMD=$(tr "\0\n" "  " < /proc/1/cmdline 2>/dev/null | head -c 160)
info "PID 1: ${PID1_CMD:-<unreadable>}"

# This line is context, NOT attribution. It cannot tell you whether the
# entrypoint ran: entrypoint.sh ends in `exec "$@"`, which replaces its own
# process, so PID 1 is the container's command either way - the two cases are
# byte-identical here. The marker above is the only check that detects a bypass.
#
# What PID 1 *can* tell you is *which* command is running, and that identifies
# the cause. The devcontainer CLI's shim and the image's own keep-alive are both
# `sleep 1 & wait` loops, but only the CLI's carries an `exec "$@"` - it is
# written to exec a command that, with "overrideCommand": false, it never
# supplies. Seeing it as PID 1 means the CLI created this container with
# `--entrypoint /bin/sh` and the image ENTRYPOINT was discarded; because
# `--entrypoint` is baked into the container config at create time, every later
# `docker start` of it bypasses the entrypoint too. That is defect D, and it is
# a FAIL rather than a warning because it silently disarms the enforcement point
# while leaving a container that looks perfectly healthy from the outside.
#
# KEEP IN SYNC with the CMD in the Dockerfile - this string is the one thing
# verify.sh knows about it. If the CMD's text changes, change this with it or
# every launch will report a false FAIL.
PID1_KEEPALIVE='sandbox keep-alive (image CMD)'

if [ -z "$PID1_CMD" ]; then
  warn "could not read /proc/1/cmdline - cannot tell which command PID 1 is"
elif [[ "$PID1_CMD" == *"$PID1_KEEPALIVE"* ]]; then
  ok "PID 1 is the image's own keep-alive - the image ENTRYPOINT was not overridden"
elif [[ "$PID1_CMD" == *'exec "$@"'* ]]; then
  bad "PID 1 is a launch tool's shim, not the image keep-alive - the ENTRYPOINT was overridden"
  info "the devcontainer CLI creates the container with --entrypoint /bin/sh unless"
  info "devcontainer.json sets \"overrideCommand\": false; check that it still does"
  info "and recreate the container (--remove-existing-container), since the override"
  info "is stored in the container config and survives every docker start"
else
  # A hand-run `docker run -it <image> bash` lands here, and so does any other
  # deliberate command. Not a failure - the entrypoint still ran, which the
  # marker above proves - but worth reporting, because it means this container
  # is not shaped like the one a devcontainer launch produces.
  warn "PID 1 is neither the image keep-alive nor a known launch-tool shim"
  info "expected if this container was started by hand with an explicit command"
fi

# ---------------------------------------------------------------------------
# Check 6: npm's cache is writable and exec-capable
# ---------------------------------------------------------------------------
#
# The rootfs is read-only, so npm's cache has to come from a writable mount or
# every registry fetch dies with EROFS before it can be written to disk.
#
# Writability alone is not sufficient, which is why there are two probes here.
# `npx` stages a package under <cache>/_npx/<hash>/node_modules and then execs
# its bin, so a cache placed on a `noexec` filesystem - the /tmp tmpfs, for
# instance - clears the EROFS and then fails one step later with exit 126. A
# check that only tested writability would score that broken state as healthy.
#
# The location is read from `npm config get cache` rather than hardcoded, so a
# base image that changes npm's default path is reported here instead of
# silently reintroducing EROFS at the first `npm install`.

section "npm cache must be writable and executable"

NPM_CACHE=$(npm config get cache 2>/dev/null | tr -d '\r' | tail -n 1)
case "$NPM_CACHE" in null|undefined) NPM_CACHE="" ;; esac

if [ -z "$NPM_CACHE" ]; then
  bad "could not determine the npm cache directory ('npm config get cache')"
elif [ ! -d "$NPM_CACHE" ]; then
  bad "the npm cache directory does not exist: $NPM_CACHE"
else
  info "npm cache: $NPM_CACHE"

  # Both probes live at the top level of the cache directory, never inside
  # _cacache, so nothing they leave behind could be mistaken for cache content.
  WRITE_PROBE="$NPM_CACHE/.verify-write-probe.$$"
  if ( : > "$WRITE_PROBE" ) 2>/dev/null; then
    ok "npm cache is writable"
    rm -f "$WRITE_PROBE"
  else
    bad "npm cache is not writable ($NPM_CACHE) - 'npm install' and 'npx' fail with EROFS"
  fi

  EXEC_PROBE="$NPM_CACHE/.verify-exec-probe.$$.sh"
  if ( printf '#!/bin/sh\necho exec-ok\n' > "$EXEC_PROBE" ) 2>/dev/null &&
     chmod +x "$EXEC_PROBE" 2>/dev/null; then
    if [ "$("$EXEC_PROBE" 2>/dev/null || true)" = "exec-ok" ]; then
      ok "npm cache is exec-capable - 'npx <tool>' can run a staged binary"
    else
      bad "npm cache is mounted noexec ($NPM_CACHE) - 'npx <tool>' fails with exit 126"
    fi
  else
    bad "could not stage the exec probe in the npm cache ($NPM_CACHE)"
  fi
  rm -f "$EXEC_PROBE"
fi

# ---------------------------------------------------------------------------
# Check 7: the rootfs is still read-only
# ---------------------------------------------------------------------------
#
# Every writable mount added to the container chips away at the guarantee that
# the agent cannot tamper with the sandbox's own machinery. These probes pin
# down what must stay read-only no matter what is mounted: the scripts that
# install and check the firewall, the whitelist they read, the global
# node_modules holding the claude binary, and $HOME itself - the named volumes
# are mounted *inside* $HOME, so that last one is what proves they did not make
# the whole home directory writable.

section "read-only rootfs must still be read-only"

# check_ro_dir <dir> <label> - the directory must reject a new file.
check_ro_dir() {
  local dir="$1" label="$2" probe
  probe="$dir/.verify-ro-probe.$$"
  if [ ! -d "$dir" ]; then
    warn "$label: $dir does not exist; skipping"
  elif ( : > "$probe" ) 2>/dev/null; then
    rm -f "$probe"
    bad "$label is WRITABLE ($dir) - the read-only rootfs has been weakened"
  else
    ok "$label is read-only ($dir)"
  fi
}

# check_ro_file <file> <label> - the file must reject being opened for writing.
# Opening in append mode and writing no bytes tests the permission without
# risking a change to the contents of a file the firewall depends on.
check_ro_file() {
  local file="$1" label="$2"
  if [ ! -e "$file" ]; then
    bad "$label: $file is missing"
  elif ( : >> "$file" ) 2>/dev/null; then
    bad "$label is WRITABLE ($file) - the read-only rootfs has been weakened"
  else
    ok "$label is read-only ($file)"
  fi
}

check_ro_dir  "/usr/local/bin"                     "sandbox scripts"
check_ro_file "/usr/local/etc/allowed-domains.txt" "egress whitelist"

GLOBAL_MODULES=$(npm root -g 2>/dev/null | tr -d '\r' | tail -n 1)
if [ -n "$GLOBAL_MODULES" ]; then
  check_ro_dir "$GLOBAL_MODULES" "global node_modules (claude binary)"
else
  bad "could not determine the global node_modules directory ('npm root -g')"
fi

check_ro_dir "$HOME" "\$HOME (the named volumes mount inside it)"

# ---------------------------------------------------------------------------
# Check 8: host-only commands are declared and enforced
# ---------------------------------------------------------------------------
#
# Unlike the checks above, this one is about what the *agent* can do rather
# than what the network allows. It is not a containment guarantee - a host-only
# command is already blocked at the network layer - so it is checked here for
# the same reason everything else is: a capability the container claims should
# be asserted at every start rather than documented and hoped for.
#
# Every failure below is `bad`, so a broken guard blocks the launch. That is
# deliberate: a guard that silently stops matching would put the agent back to
# discovering these commands by running them, which is the failure this exists
# to remove.

section "Host-only command guard"

HOST_ONLY_LIST=/usr/local/etc/host-only-commands.txt
HOST_ONLY_GUARD=/usr/local/bin/host-only-guard.sh
HOST_ONLY_SETTINGS=/etc/claude-code/managed-settings.json
HOST_ONLY_POLICY=/etc/claude-code/CLAUDE.md

# A command the shipped list is expected to declare host-only. This is the only
# thing verify.sh knows about the list's *contents*; if the wrangler entries are
# ever dropped, point this at something the new list does declare.
HOST_ONLY_SAMPLE='npx wrangler login'

# An ordinary command that must never be blocked. Over-blocking is as much a
# failure as under-blocking: it would leave the agent unable to work.
HOST_ONLY_ORDINARY='ls -la'

# guard_probe <command> [list-path] -> sets GUARD_RC and GUARD_OUT
# Feeds the guard a synthetic PreToolUse payload, exactly as Claude Code would.
guard_probe() {
  local cmd="$1" list="${2:-$HOST_ONLY_LIST}" payload
  payload=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  GUARD_OUT=$(printf '%s' "$payload" | HOST_ONLY_COMMANDS="$list" "$HOST_ONLY_GUARD" 2>&1)
  GUARD_RC=$?
}

HOST_ONLY_OK=1

for f in "$HOST_ONLY_LIST" "$HOST_ONLY_GUARD" "$HOST_ONLY_SETTINGS" "$HOST_ONLY_POLICY"; do
  if [ -r "$f" ]; then
    ok "installed: $f"
  else
    bad "missing or unreadable: $f"
    HOST_ONLY_OK=0
  fi
done

if [ -x "$HOST_ONLY_GUARD" ]; then
  ok "$HOST_ONLY_GUARD is executable"
else
  bad "$HOST_ONLY_GUARD is not executable - the hook would fail to run"
  HOST_ONLY_OK=0
fi

# The settings file is what actually activates the guard; a correct script that
# nothing invokes is the quietest possible way for this to be broken.
if [ -r "$HOST_ONLY_SETTINGS" ] && grep -qF "$HOST_ONLY_GUARD" "$HOST_ONLY_SETTINGS"; then
  ok "managed settings register the guard as a PreToolUse hook"
else
  bad "managed settings do not reference $HOST_ONLY_GUARD"
  info "the guard would never be invoked; see $HOST_ONLY_SETTINGS"
  HOST_ONLY_OK=0
fi

if [ "$HOST_ONLY_OK" -eq 1 ]; then
  # The list must parse. The guard validates it the same way at hook time, so
  # asking the guard keeps one implementation of the rules.
  if PARSE_OUT=$(HOST_ONLY_COMMANDS="$HOST_ONLY_LIST" "$HOST_ONLY_GUARD" --check-list 2>&1); then
    ok "${PARSE_OUT#host-only-guard: }"
  else
    bad "$HOST_ONLY_LIST does not parse"
    while IFS= read -r l; do info "${l#host-only-guard: }"; done <<<"$PARSE_OUT"
  fi

  # Exercise the guard rather than trusting its configuration: a listed command
  # must be blocked, and an ordinary one must not.
  guard_probe "$HOST_ONLY_SAMPLE"
  if [ "$GUARD_RC" -eq 2 ]; then
    ok "guard blocks a declared host-only command ('$HOST_ONLY_SAMPLE')"
  else
    bad "guard did NOT block '$HOST_ONLY_SAMPLE' (exit $GUARD_RC)"
    info "either the guard is broken, or the list no longer declares it -"
    info "update HOST_ONLY_SAMPLE in this script if the list changed on purpose"
  fi

  guard_probe "$HOST_ONLY_ORDINARY"
  if [ "$GUARD_RC" -eq 0 ] && [ -z "$GUARD_OUT" ]; then
    ok "guard passes an ordinary command through silently ('$HOST_ONLY_ORDINARY')"
  else
    bad "guard interfered with '$HOST_ONLY_ORDINARY' (exit $GUARD_RC)"
    [ -n "$GUARD_OUT" ] && info "$(head -n 1 <<<"$GUARD_OUT")"
  fi

  # The two probes above depend on the shipped list's contents. Repeat them
  # against a list written here, so a guard whose matching has stopped working
  # is caught even if the shipped list is what changed.
  GUARD_PROBE_DIR=$(mktemp -d)
  printf '%s\n' \
    'sandbox-verify-probe([[:space:]]|$)  ::  synthetic entry used by verify.sh' \
    > "$GUARD_PROBE_DIR/list.txt"

  guard_probe 'sandbox-verify-probe' "$GUARD_PROBE_DIR/list.txt"
  BLOCKS_SYNTHETIC=$([ "$GUARD_RC" -eq 2 ] && echo 1 || echo 0)
  guard_probe 'echo hello' "$GUARD_PROBE_DIR/list.txt"
  ALLOWS_SYNTHETIC=$([ "$GUARD_RC" -eq 0 ] && echo 1 || echo 0)

  if [ "$BLOCKS_SYNTHETIC" -eq 1 ] && [ "$ALLOWS_SYNTHETIC" -eq 1 ]; then
    ok "guard matching works against a list written by this script"
  else
    bad "guard matching is broken (synthetic block=$BLOCKS_SYNTHETIC allow=$ALLOWS_SYNTHETIC)"
  fi

  # Failing closed on a broken policy is the whole point; check it explicitly.
  guard_probe "$HOST_ONLY_ORDINARY" "$GUARD_PROBE_DIR/does-not-exist.txt"
  if [ "$GUARD_RC" -eq 2 ]; then
    ok "guard refuses commands when the list is missing (fails closed)"
  else
    bad "guard allowed a command with a missing list (exit $GUARD_RC) - it fails open"
  fi

  rm -rf "$GUARD_PROBE_DIR"
else
  info "skipping the behavioural probes - the guard is not installed correctly"
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
