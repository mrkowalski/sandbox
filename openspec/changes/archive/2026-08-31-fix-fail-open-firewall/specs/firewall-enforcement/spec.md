## Purpose

Defines when the sandbox's default-deny egress firewall is installed and what must be true when installing it fails. The sandbox's other guarantees all assume the firewall is present; this capability makes that assumption hold for every way a container can start, and makes every failure path end with less network access rather than more.

## ADDED Requirements

### Requirement: The firewall is installed on every container start

Firewall installation SHALL be anchored to the container itself, not to the tool used to launch it. It SHALL run on every start of the container, regardless of how the container was started, and SHALL complete before any process that could use the network is reachable.

Anchoring alone does not satisfy this requirement; the launch configuration must also honour the anchor, per "The launch configuration cannot detach the enforcement point" below.

#### Scenario: Started by the devcontainer CLI

- **WHEN** the container is started with `devcontainer up`
- **THEN** the firewall is installed before the container's main process begins
- **AND** the ruleset is in whitelist mode

#### Scenario: Restarted outside the devcontainer CLI

- **WHEN** a stopped container is started again by any means that does not run `postStartCommand` — `docker start`, a container-engine UI restart control, or an automatic restart after a host reboot
- **THEN** the firewall is installed again for the new network namespace
- **AND** the ruleset is in whitelist mode, exactly as after a `devcontainer up`

#### Scenario: An attached session cannot precede the firewall

- **WHEN** a session is attached to the container with `devcontainer exec` or an equivalent
- **THEN** the firewall is already installed, because the container's main process is not reachable until installation has succeeded

### Requirement: The launch configuration cannot detach the enforcement point

Anchoring installation to the image is not sufficient on its own: a launch tool may override the image's entrypoint, and such an override is recorded in the container's configuration, so it persists for the container's whole life rather than applying to one start. The sandbox's launch configuration SHALL therefore be pinned so that the image's entrypoint is honoured, and SHALL supply whatever the image needs to keep running once the launch tool stops providing it.

A configuration that detaches the enforcement point SHALL NOT fail silently. Because a container whose entrypoint was discarded is indistinguishable from a healthy one by inspecting its main process, detection SHALL rest on positive evidence that installation ran during the current start.

#### Scenario: The launch tool would override the image entrypoint by default

- **WHEN** the container is created by a launch tool whose default behaviour is to replace the image's entrypoint
- **THEN** the sandbox's launch configuration disables that behaviour
- **AND** the image's entrypoint runs, so the firewall is installed before the container's command begins

#### Scenario: The container stays running without the launch tool's command

- **WHEN** the launch tool no longer supplies the container's command, because its override is disabled
- **THEN** the image supplies a command of its own that keeps the container running
- **AND** the container remains attachable and still stops promptly when the engine asks it to

#### Scenario: A detached enforcement point is detected, not assumed

- **WHEN** the container is started in a way that bypasses the image's entrypoint, whether by configuration or by a launch path that predates it
- **THEN** verification reports a failure at FAIL severity, on the evidence that installation did not run during this start
- **AND** it does not rely on the identity of the container's main process, which is identical whether the entrypoint ran or not

### Requirement: Failed firewall installation leaves no usable container

When firewall installation or its structural verification fails, the container SHALL NOT become usable. It SHALL stop rather than continue running without a firewall, so that no session can attach to an unprotected container.

#### Scenario: Firewall installation fails at start

- **WHEN** firewall installation returns a non-zero status during container start
- **THEN** the container's main process is never started and the container stops
- **AND** an attempt to attach a session to it fails, because there is no running container

#### Scenario: Structural verification fails at start

- **WHEN** the firewall installs but the ruleset is not in whitelist mode
- **THEN** the container stops rather than starting its main process

#### Scenario: The failure is attributable

- **WHEN** the container stops because firewall installation failed
- **THEN** the reason is written to the container's log where the launching tool and `docker logs` will show it

### Requirement: The start-time gate does not depend on network reachability

The check that gates container start SHALL assert only properties of the local ruleset and require no network access, so that an unreachable external host cannot prevent the sandbox from starting. Reachability SHALL continue to be verified after start, where a failure is reported rather than fatal.

#### Scenario: An upstream outage does not block startup

- **WHEN** the firewall installs correctly but a whitelisted endpoint such as `api.anthropic.com` is unreachable
- **THEN** the container starts normally
- **AND** the post-start verification reports the unreachable endpoint as a failure

#### Scenario: A broken ruleset does block startup

- **WHEN** the ruleset is not in whitelist mode at start — the OUTPUT policy is not DROP, the ipset is missing or empty, or the ipset ACCEPT rule is absent
- **THEN** the container stops

### Requirement: Firewall setup fails closed

`init-firewall.sh` SHALL never leave the container with more network access than it had before the script ran. Chain policies SHALL be set to DROP before any existing rules are flushed, and any abort before setup completes SHALL leave the container sealed: all three chain policies DROP, with no rule permitting general egress.

This SHALL hold however the script is invoked, including a manual re-run in an already-running container, so that its safety does not depend on the caller.

#### Scenario: An unresolvable whitelist entry aborts

- **WHEN** a hostname in the whitelist cannot be resolved
- **THEN** setup aborts, as it does today
- **AND** the container is left sealed — all chain policies DROP and no general-egress ACCEPT rule — rather than open

#### Scenario: Any other mid-setup abort

- **WHEN** setup aborts for any other reason — an unreadable whitelist, an empty whitelist, an invalid address from DNS, a failure to create the ipset, or an undetectable host IP
- **THEN** the container is left sealed rather than open

#### Scenario: A manual re-run that fails does not open the container

- **WHEN** `init-firewall.sh` is re-run by hand in a container that already has a working firewall, and the run aborts partway
- **THEN** the container is sealed, not returned to unrestricted egress

#### Scenario: There is no open window during a successful run

- **WHEN** setup runs to completion
- **THEN** at no point between the first flush and the final ruleset are the chain policies ACCEPT with the original rules removed

### Requirement: The enforcement guarantees are verified

`verify.sh` SHALL assert the properties above rather than assuming them, consistent with the repo's design that guarantees are checked at every start. A failure SHALL be reported at FAIL severity.

#### Scenario: Verification detects an absent firewall

- **WHEN** the ruleset is not in whitelist mode
- **THEN** verification reports a failure, prints `NOT VERIFIED`, and exits non-zero

#### Scenario: Verification confirms the start-time enforcement point exists

- **WHEN** verification runs in a correctly built container
- **THEN** it reports a passing check that firewall installation is anchored to container start rather than only to the launch tool
