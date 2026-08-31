## Purpose

Gives the user one command, run from a project folder, that opens Claude Code inside that project's sandbox container and takes care of provisioning the container when it is missing or out of date.

## ADDED Requirements

### Requirement: Single command opens Claude Code in the project's sandbox

The launcher SHALL be a single command, invoked from a project directory with no arguments, that ends with an interactive Claude Code session running inside a sandbox container bound to that directory. The user SHALL NOT have to run a separate provisioning command first.

Each project directory SHALL get its own container. Running the launcher from a different project directory SHALL NOT reuse or disturb another project's container.

#### Scenario: No container exists for the project

- **WHEN** the user runs the launcher in a project directory that has no sandbox container
- **THEN** the launcher provisions a sandbox container for that directory using this repository's devcontainer configuration
- **AND** the container's firewall setup and verification run before Claude Code starts
- **AND** an interactive Claude Code session opens in that container with permission prompts skipped

#### Scenario: A usable container already exists

- **WHEN** the user runs the launcher in a project directory whose container already exists and is up to date
- **THEN** the launcher reuses that container rather than recreating it
- **AND** an interactive Claude Code session opens in it

#### Scenario: The container exists but is stopped

- **WHEN** the user runs the launcher in a project directory whose container exists but is not running
- **THEN** the launcher starts the existing container
- **AND** an interactive Claude Code session opens in it

#### Scenario: Two projects in parallel

- **WHEN** the user runs the launcher in project A and then in project B
- **THEN** each session runs in a container bound to its own project directory
- **AND** neither session's container is removed or restarted by the other

### Requirement: Sandbox configuration drift triggers a rebuild

The launcher SHALL detect when this repository's sandbox configuration has changed since a project's container was provisioned, and SHALL rebuild that container before opening Claude Code. A container provisioned from a superseded configuration SHALL NOT be reused.

The configuration under observation SHALL cover every input that determines what the sandbox permits — at minimum the devcontainer definition, the container image definition, the egress whitelist, and the firewall and verification scripts.

The launcher SHALL report that it is rebuilding, and why, before the rebuild starts.

#### Scenario: Egress whitelist changed

- **WHEN** the egress whitelist has been edited since the project's container was provisioned
- **AND** the user runs the launcher in that project directory
- **THEN** the launcher states that the sandbox configuration changed and rebuilds the container from the current configuration
- **AND** Claude Code opens in the rebuilt container

#### Scenario: Configuration unchanged

- **WHEN** the sandbox configuration has not changed since the project's container was provisioned
- **AND** the user runs the launcher in that project directory
- **THEN** the launcher does not rebuild the container

#### Scenario: Provisioning state for the project is unknown

- **WHEN** the launcher cannot determine which configuration the project's existing container was provisioned from
- **THEN** the launcher rebuilds the container rather than reusing it

#### Scenario: Rebuild is requested explicitly

- **WHEN** the user runs the launcher with the force-rebuild option
- **THEN** the launcher rebuilds the container from the current configuration even if nothing changed

### Requirement: Arguments are passed through to Claude Code

The launcher SHALL accept arguments intended for Claude Code and pass them through unaltered, so that any Claude Code invocation available inside the sandbox is reachable through the launcher. Launcher options SHALL be distinguishable from pass-through arguments.

#### Scenario: Extra arguments forwarded

- **WHEN** the user runs the launcher with arguments marked for pass-through
- **THEN** those arguments reach Claude Code inside the container in the order given, unmodified
- **AND** the launcher's own options are not forwarded

### Requirement: Failures are reported and never fall through to an unsandboxed session

The launcher SHALL verify its prerequisites and the outcome of provisioning before starting Claude Code. When any step fails, the launcher SHALL print a message naming the failed step and what the user can do about it, SHALL NOT start Claude Code, and SHALL exit with a non-zero status.

The launcher SHALL NEVER start Claude Code outside a sandbox container, under any failure or fallback path.

#### Scenario: Container tooling is unavailable

- **WHEN** the devcontainer CLI is not installed, or the Docker daemon cannot be reached
- **THEN** the launcher reports which prerequisite is missing and how to install or start it
- **AND** exits non-zero without starting Claude Code

#### Scenario: The container fails to come up

- **WHEN** provisioning or starting the container fails, or the sandbox verification step fails
- **THEN** the launcher surfaces the underlying output, reports that the sandbox is not usable
- **AND** exits non-zero without starting Claude Code

#### Scenario: Claude Code's exit status is preserved

- **WHEN** the Claude Code session inside the container ends
- **THEN** the launcher exits with the status Claude Code returned

### Requirement: The existing two-command workflow keeps working

The launcher SHALL be additive. The existing separate provisioning and attach commands SHALL remain available and behave as they did before, so a user can still force a clean rebuild or attach to a running container as independent steps.

#### Scenario: Escape hatches still available

- **WHEN** the user runs the existing provisioning command or the existing attach command
- **THEN** each behaves as it did before the launcher was introduced

### Requirement: The launcher is installed from this repository

The launcher SHALL ship as an executable in this repository, so that updating the repository updates the launcher. Its documented installation SHALL require no copying of logic into the user's shell configuration, and the launcher SHALL locate this repository's sandbox configuration relative to itself rather than from a user-supplied path.

The documentation SHALL state how to make the launcher available on `PATH` and SHALL present it as the everyday entry point.

#### Scenario: Launcher run from an arbitrary directory

- **WHEN** the launcher is invoked from any project directory after installation
- **THEN** it uses the sandbox configuration belonging to the repository it was installed from
- **AND** it targets the current working directory as the project to sandbox
