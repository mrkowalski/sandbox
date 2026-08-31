#!/bin/bash
#
# entrypoint.sh - install the sandbox's egress firewall, then hand off to the
# container's command. Declared as the image ENTRYPOINT.
#
# This is the sandbox's enforcement point, and it is anchored to the *container*
# rather than to the tool that launches it. It therefore runs on every start:
# `devcontainer up`, `docker start`, a Docker Desktop restart button, an
# automatic restart after a host reboot. devcontainer.json's postStartCommand
# covers only the first of those - and iptables rules and ipsets live in the
# container's network namespace, which is new on every start, so a restarted
# container used to come back with an empty ruleset and nothing to notice.
#
# It fails closed by never reaching `exec`: if the firewall does not install, or
# does not verify, this script exits and the container stops. That leaves no
# unprotected container running for `devcontainer exec` to attach to, which is
# the point - a launch command that merely returns non-zero does not stop
# anyone from attaching a moment later.
#
# The gate is `verify.sh --iptables-only`, which asserts local ruleset state and
# opens no sockets. The full verify.sh - which probes api.anthropic.com and the
# other whitelisted endpoints - stays in postStartCommand, because reachability
# is a health signal, not a containment property. A third party's outage should
# report NOT VERIFIED; it should not stop the sandbox from starting.
#
# Runs as the unprivileged `node` user and reaches root only through the two
# NOPASSWD sudoers entries the Dockerfile already grants (init-firewall.sh and
# verify.sh). It adds no privilege.
#
# Escape hatch, for the host operator only: `docker run --entrypoint /bin/bash`
# (or `--entrypoint ""`) starts the image with none of this, which is how a
# container that refuses to start is diagnosed. Deliberately not an in-image
# env-var bypass: that would be a permanent, documented way to run the sandbox
# unprotected, and the agent in here has no container engine to use the
# --entrypoint override with.

set -euo pipefail

MARKER=/tmp/.sandbox-firewall-installed

# Both messages go to stderr, so `docker logs` and the launching tool's output
# each show why the container never started. A silent stop would be the same
# failure this script exists to fix, one layer up.
die() {
    echo "entrypoint: $*" >&2
    echo "entrypoint: refusing to start an unprotected container" >&2
    exit 1
}

# verify.sh --iptables-only ends with a machine-readable __VERIFY_COUNTS__
# trailer meant for a parent verify.sh. Keep it out of the container log.
strip_trailer() { grep -v '^__VERIFY_' || true; }

sudo -n /usr/local/bin/init-firewall.sh \
    || die "firewall installation failed"

if VERIFY_OUT=$(sudo -n /usr/local/bin/verify.sh --iptables-only 2>&1); then
    printf '%s\n' "$VERIFY_OUT" | strip_trailer
else
    printf '%s\n' "$VERIFY_OUT" | strip_trailer >&2
    die "firewall ruleset is not in whitelist mode"
fi

# /tmp is a tmpfs, recreated empty on every start, so this marker means the
# entrypoint ran *this* start rather than some earlier one. verify.sh checks it.
: > "$MARKER"

# Docker composes ENTRYPOINT with the container's command, so "$@" is whatever
# the image CMD or the launching tool supplied. On the devcontainer path that is
# the image's own keep-alive CMD, because devcontainer.json sets
# "overrideCommand": false - with the CLI's default it would instead be the CLI's
# sleep shim, and this script would not be running at all. exec replaces this
# shell, so that command stays PID 1 and keeps receiving the engine's stop
# signal directly.
if [ "$#" -eq 0 ]; then
    # Not reachable from any launch path: the image declares a CMD, so Docker
    # always supplies one. It survives for the case that clears it - `docker run
    # --entrypoint <this script> <image>`, which Docker documents as discarding
    # the image's CMD - i.e. an operator invoking the entrypoint by hand. `exec`
    # with no arguments would silently do nothing and fall off the end of the
    # script, stopping the container; a shell keeps the image runnable on its
    # own, with the firewall installed.
    exec /bin/bash
fi

exec "$@"
