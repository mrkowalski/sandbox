## Purpose

Defines which container engines the sandbox may be run under, how a user selects one, and the guarantee that the sandbox's security restrictions are enforced identically on every supported engine.

## ADDED Requirements

### Requirement: Supported container engines

The sandbox SHALL run under Docker and under rootless Podman. Rootful Podman and any other container engine are unsupported: they are not documented and carry no guarantee.

Support means the sandbox starts, Claude Code runs inside it, and every security restriction the sandbox promises is enforced. An engine on which any security restriction cannot be enforced is not supported, regardless of whether the container starts.

#### Scenario: Docker
- **WHEN** a user launches the sandbox under Docker
- **THEN** the container starts, Claude Code is reachable inside it, and every security restriction is enforced

#### Scenario: Rootless Podman
- **WHEN** a user launches the sandbox under rootless Podman
- **THEN** the container starts, Claude Code is reachable inside it, and every security restriction is enforced

#### Scenario: Unsupported engine
- **WHEN** a user launches the sandbox under rootful Podman or another engine
- **THEN** no guarantee is made, and the documentation does not present it as a supported path

### Requirement: Explicit engine selection

The user SHALL select the container engine explicitly at launch. The sandbox SHALL NOT infer the engine from the host environment, and SHALL NOT silently substitute one engine for another.

Each supported engine SHALL have its own sandbox configuration. A configuration SHALL be usable only with the engine it targets, so that launching with a mismatched engine fails rather than producing a container with the wrong properties.

#### Scenario: Selecting an engine
- **WHEN** a user launches the sandbox
- **THEN** the engine used is the one named by the configuration and launch command the user chose, and no other

#### Scenario: Engine mismatch
- **WHEN** a user launches an engine-specific configuration with a different engine
- **THEN** the launch fails with an error, rather than starting a container whose properties differ from the ones that configuration promises

### Requirement: Identical security restrictions across engines

The sandbox SHALL enforce the same set of security restrictions on every supported engine. No restriction may be relaxed, skipped, or downgraded to a warning on one engine in order to make it run there.

The restrictions are: egress is default-deny with only whitelisted destinations reachable; `git push` is impossible; the container filesystem is read-only apart from designated writable mounts; and the container runs as an unprivileged user.

#### Scenario: Blocked egress on every engine
- **WHEN** the verification is run on any supported engine
- **THEN** a non-whitelisted host is unreachable over both HTTP and HTTPS

#### Scenario: Whitelisted egress on every engine
- **WHEN** the verification is run on any supported engine
- **THEN** the Anthropic API endpoints required by Claude Code are reachable

#### Scenario: git push blocked on every engine
- **WHEN** the verification is run on any supported engine
- **THEN** `git push` fails over both SSH and HTTPS

#### Scenario: No engine-specific exemption
- **WHEN** a security check cannot pass on a supported engine
- **THEN** the check is not weakened for that engine; either the sandbox is fixed so the check passes, or that engine ceases to be supported

### Requirement: Verification reports the engine it ran under

The sandbox's verification SHALL report which container engine and which user-namespace mode it observed, so that a passing result is attributable to a specific environment and a user cannot mistake a Docker result for a Podman one.

#### Scenario: Engine reported
- **WHEN** the verification runs
- **THEN** its output names the detected container engine and whether the container is running under a mapped (rootless) user namespace

#### Scenario: Engine undetectable
- **WHEN** the verification cannot determine the engine
- **THEN** it reports the engine as unknown and still runs and reports every security check

### Requirement: Workspace is writable under user-namespace mapping

The user the sandbox runs Claude Code as SHALL be able to read and write the mounted project workspace on every supported engine. Rootless engines map host user identities into the container, and a mapping that leaves the workspace unwritable SHALL be treated as a failure, not as a warning.

#### Scenario: Workspace writable
- **WHEN** the verification runs on any supported engine
- **THEN** it confirms the sandbox user can create, modify, and delete files in the mounted workspace

#### Scenario: Workspace not writable
- **WHEN** the sandbox user cannot write to the mounted workspace
- **THEN** the verification fails, naming the workspace as the cause

#### Scenario: Host ownership preserved
- **WHEN** the sandbox writes a file into the mounted workspace and the sandbox exits
- **THEN** the file is owned on the host by the user who launched the sandbox, and is readable and writable by them without escalation

### Requirement: Persistent state is writable and survives restarts

The sandbox's persistent state — the Claude Code configuration directory and the shell history — SHALL be writable by the sandbox user on every supported engine, and SHALL persist across sandbox restarts for the same project.

#### Scenario: Persistent state writable
- **WHEN** the verification runs on any supported engine
- **THEN** it confirms the sandbox user can write to each persistent state location

#### Scenario: State survives a restart
- **WHEN** a user stops the sandbox for a project and launches it again
- **THEN** the Claude Code configuration and shell history from the previous session are present

#### Scenario: Persistent state not writable
- **WHEN** a persistent state location is not writable by the sandbox user
- **THEN** the verification fails, naming that location

### Requirement: Name resolution survives firewall installation

Installing the egress firewall SHALL preserve the container name-resolution mechanism provided by whichever engine is in use. After the firewall is installed, resolving a whitelisted hostname SHALL succeed on every supported engine.

#### Scenario: Resolution works after firewall install
- **WHEN** the firewall has been installed on any supported engine
- **THEN** every whitelisted hostname resolves, and the whitelisted destinations are reachable

#### Scenario: Engine provides no container DNS rules
- **WHEN** the engine installs no container-DNS rules for the firewall to preserve
- **THEN** the firewall installs successfully and name resolution still works

### Requirement: Missing prerequisites fail clearly

When the selected engine is absent, unreachable, or misconfigured for rootless operation, the sandbox SHALL fail with a message naming the missing prerequisite, and SHALL NOT start Claude Code.

#### Scenario: Engine not installed
- **WHEN** a user launches the sandbox with an engine that is not installed
- **THEN** the launch fails with a message naming that engine, and Claude Code does not start

#### Scenario: Rootless prerequisites missing
- **WHEN** a user launches under rootless Podman without the user-namespace prerequisites in place
- **THEN** the launch fails with a message identifying the missing rootless prerequisite, and Claude Code does not start

#### Scenario: Verification fails
- **WHEN** any security check fails at startup
- **THEN** the failure is reported and the sandbox is not presented as ready for use
