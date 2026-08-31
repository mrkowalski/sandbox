#!/bin/bash
#
# init-firewall.sh - install the default-deny egress firewall for the sandbox.
#
# Builds an `allowed-domains` ipset from the hostnames listed in the whitelist
# file, then sets every iptables chain policy to DROP and accepts only traffic
# matching that set.
#
# The whitelist is read from $ALLOWED_DOMAINS_FILE, defaulting to
# /usr/local/etc/allowed-domains.txt.
#
# GUARANTEE: this script never leaves the container with more network access
# than it found. Two things make that true, and neither depends on the caller:
#
#   * The chain policies are set to DROP *before* any pre-existing rule is
#     flushed, so there is no instant at which the chains are simultaneously
#     empty and permissive.
#   * An EXIT trap seals the container - all three policies DROP, every filter
#     rule dropped, loopback only - on any abort before the ruleset is
#     complete.
#
# So an abort lands in a sealed state, not an open one. That inversion is
# deliberate and is the whole point of the ordering below: the container is
# usable the moment it starts, and the previous order (flush first, DROP some
# sixty lines later) meant every abort path in between failed loudly in the log
# and silently open on the wire.
#
# Invoked from the image ENTRYPOINT on every container start, again from
# devcontainer.json's postStartCommand, and possibly by hand
# (`sudo /usr/local/bin/init-firewall.sh`) in an already-running container. The
# guarantee holds for all three.
#
# Correctness of the resulting ruleset is asserted separately by verify.sh.

set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# ------------------------------------------------------------- fail closed ---
#
# FIREWALL_OK flips to 1 on the last line of a successful run. Until then every
# exit - an unreadable whitelist, an unresolvable name, a DNS blip, a failed
# `ipset create`, any `set -e` abort at all - runs seal() and leaves the
# container with no egress.
#
# The trap is EXIT, not ERR, on purpose: ERR is not inherited into every
# construct (subshells, command substitution, functions without `set -E`), so
# it would miss some of the exits that matter here. EXIT catches all of them.

FIREWALL_OK=0

seal() {
    local rc=$?
    if [ "$FIREWALL_OK" -eq 1 ]; then
        return 0    # successful run; leave the completed ruleset alone
    fi

    echo "ERROR: firewall setup aborted (exit $rc) - sealing the container" >&2

    # Same ordering rule as the main path: close before emptying, so the flush
    # itself cannot open a window. Best-effort throughout - a seal that hits an
    # error must still attempt every remaining step.
    iptables -P INPUT DROP   || true
    iptables -P FORWARD DROP || true
    iptables -P OUTPUT DROP  || true
    iptables -F              || true

    # Loopback is deliberately left up. It grants no egress, and a human
    # diagnosing a sealed container should not also be fighting a shell whose
    # local sockets do not work.
    iptables -A INPUT  -i lo -j ACCEPT || true
    iptables -A OUTPUT -o lo -j ACCEPT || true

    echo "Container sealed: all chain policies DROP, loopback only, no egress." >&2
}
trap seal EXIT

ALLOWED_DOMAINS_FILE="${ALLOWED_DOMAINS_FILE:-/usr/local/etc/allowed-domains.txt}"

if [ ! -r "$ALLOWED_DOMAINS_FILE" ]; then
    echo "ERROR: whitelist file not found or unreadable: $ALLOWED_DOMAINS_FILE" >&2
    exit 1
fi

# 1. Extract Docker DNS info BEFORE any flushing. These are the only
#    pre-existing rules worth keeping: without them the engine's embedded
#    resolver at 127.0.0.11 is unreachable and nothing below can resolve a
#    hostname.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# 2. Close the door before emptying the room. This ordering *is* the
#    fail-closed guarantee: from the moment the first pre-existing rule
#    disappears, the default is already deny.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 3. Flush existing rules and delete existing ipsets. The container is sealed
#    from here until the ruleset below is complete. The ipset can only be
#    destroyed once nothing references it, which the flush has just ensured.
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
ipset destroy allowed-domains 2>/dev/null || true

# 4. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# DNS and localhost must work before anything else can be resolved or allowed.
# Under a DROP policy these four rules are now the container's entire network
# access, which is exactly the intent: enough to resolve the whitelist, and
# nothing else.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Resolve and add the whitelisted domains
echo "Reading whitelist from $ALLOWED_DOMAINS_FILE"
domains=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOWED_DOMAINS_FILE" | grep -v '^$' || true)
if [ -z "$domains" ]; then
    echo "ERROR: no domains listed in $ALLOWED_DOMAINS_FILE" >&2
    exit 1
fi

for domain in $domains; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        # Aborting on an unresolvable name is the documented contract and is
        # kept as-is. Only the state it leaves behind has changed: sealed.
        echo "ERROR: Failed to resolve $domain" >&2
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip" >&2
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP" >&2
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# The policies were already set to DROP in step 2; re-assert them here so the
# final state is stated in one place and a future edit to the block above
# cannot quietly leave a chain permissive.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"

# Last line of the successful path: the ruleset is complete, so the seal trap
# must not tear it down on the way out.
FIREWALL_OK=1
