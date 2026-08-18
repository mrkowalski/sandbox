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
# Correctness of the resulting ruleset is asserted separately by verify.sh,
# which devcontainer.json runs immediately after this script.

set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

ALLOWED_DOMAINS_FILE="${ALLOWED_DOMAINS_FILE:-/usr/local/etc/allowed-domains.txt}"

if [ ! -r "$ALLOWED_DOMAINS_FILE" ]; then
    echo "ERROR: whitelist file not found or unreadable: $ALLOWED_DOMAINS_FILE"
    exit 1
fi

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# DNS and localhost must work before anything else can be resolved or allowed.
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
    echo "ERROR: no domains listed in $ALLOWED_DOMAINS_FILE"
    exit 1
fi

for domain in $domains; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
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
