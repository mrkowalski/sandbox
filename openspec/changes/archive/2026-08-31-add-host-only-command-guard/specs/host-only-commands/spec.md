## Purpose

Declares which commands cannot work inside the sandbox because they depend on credentials or endpoints that exist only on the host, stops the agent from attempting them, and turns each attempt into a clear handoff telling the user exactly what to run outside the sandbox.

## ADDED Requirements

### Requirement: Host-only commands are declared in one editable list

The sandbox SHALL keep a single list of the commands that cannot work inside it, installed into the container image alongside the egress whitelist. That list SHALL be the only place a command is declared host-only; no other file SHALL carry its own copy of the rules.

Each entry SHALL carry both a pattern that identifies the command and human-readable text stating why the command cannot work in the sandbox and what the user should run on the host instead. The file SHALL support comments and blank lines so entries can be annotated in place.

Extending the sandbox's knowledge of a host-only command SHALL require only adding a line to this list and rebuilding the container.

The list SHALL initially declare only the `wrangler` subcommands that authenticate against, or act on, a Cloudflare account. `wrangler` subcommands that operate purely on local files SHALL NOT be declared host-only.

#### Scenario: Adding a new host-only command

- **WHEN** the user adds an entry for a command to the list and rebuilds the container
- **THEN** that command is treated as host-only in every subsequent session
- **AND** no other file needed editing for it to take effect

#### Scenario: The list cannot be read

- **WHEN** the list is missing, unreadable, or malformed at the time a command is checked
- **THEN** the sandbox reports the problem loudly rather than silently treating every command as permitted

#### Scenario: A local-only subcommand of a listed tool

- **WHEN** the agent runs a `wrangler` subcommand that neither authenticates nor contacts a Cloudflare endpoint
- **THEN** the command runs normally and is not treated as host-only

### Requirement: A declared host-only command is never executed inside the sandbox

When the agent attempts a shell command matching an entry in the list, the sandbox SHALL prevent that command from executing and SHALL return to the agent the entry's explanation and host-side remedy. Prevention SHALL happen before the command runs, not by interpreting its failure afterwards.

Matching SHALL apply to the whole command string as the agent submits it, so that a listed command is caught when it is invoked through a package runner, or as one element of a compound or chained command.

This enforcement SHALL NOT depend on the session's permission mode; it SHALL hold when the agent is running with permission prompts skipped.

#### Scenario: Listed command invoked through a package runner

- **WHEN** the agent attempts to run a listed command by way of a package runner such as `npx`
- **THEN** the command does not execute
- **AND** the agent receives the entry's explanation and the host-side remedy

#### Scenario: Listed command chained with other commands

- **WHEN** the agent submits a compound command in which one element matches an entry in the list
- **THEN** no part of the submitted command executes
- **AND** the agent receives the entry's explanation and the host-side remedy

#### Scenario: Permission prompts are skipped

- **WHEN** the agent runs with permission prompts skipped and attempts a listed command
- **THEN** the command still does not execute

#### Scenario: Unlisted command

- **WHEN** the agent runs a command that matches no entry in the list
- **THEN** the command runs exactly as it did before this capability existed

### Requirement: The agent tells the user what to run outside the sandbox

The instructions in effect for every session SHALL direct the agent to consult the list before proposing or running shell work, to never attempt a declared host-only command, and instead to state to the user that the command must be run in a terminal outside the sandbox.

That statement SHALL name the sandbox restriction as the reason, and SHALL quote the exact command the user needs to run on the host. The agent SHALL NOT present the situation as a failure, a bug, or something to retry, and SHALL NOT substitute a workaround that attempts the same effect by other means without saying it is doing so.

When the agent nevertheless attempts a listed command and is stopped, it SHALL relay the returned explanation and host-side remedy to the user rather than retrying, rewording, or working around the command.

#### Scenario: Host-only step reached during a task

- **WHEN** completing the user's task requires a declared host-only command
- **THEN** the agent states that this step must be run outside the sandbox, quotes the command verbatim, and gives the sandbox restriction as the reason
- **AND** the agent does not attempt the command

#### Scenario: The agent is stopped mid-attempt

- **WHEN** the agent attempts a declared host-only command and enforcement stops it
- **THEN** the agent reports to the user what must be run on the host and why
- **AND** does not retry the command, reword it to evade the match, or silently substitute an alternative

#### Scenario: Remaining work continues

- **WHEN** a task contains both host-only steps and steps the sandbox can perform
- **THEN** the agent completes the steps it can and states plainly which steps were left for the user to run on the host

### Requirement: The declaration applies to every project mounted in the sandbox

The list, the enforcement, and the session instructions SHALL take effect in every sandbox session regardless of which host project is mounted as the workspace, and SHALL NOT require any per-project configuration.

The configuration that activates enforcement SHALL live outside the mounted workspace, so that content in the mounted project cannot disable it.

#### Scenario: An arbitrary host project is mounted

- **WHEN** a sandbox session is started against a project that has no knowledge of this sandbox
- **THEN** the list, the enforcement, and the session instructions are all in effect

#### Scenario: Workspace content attempts to disable enforcement

- **WHEN** the mounted project contains configuration that would turn the enforcement off
- **THEN** enforcement remains in effect

### Requirement: A deliberate single-invocation bypass exists

The sandbox SHALL provide a documented way for the user to run one specific invocation of a declared host-only command anyway, so that an over-broad or mistaken entry never requires rebuilding the container to work around.

The bypass SHALL apply to a single invocation only and SHALL NOT persist to later commands in the session. When it is used, the sandbox SHALL note that the guard was bypassed rather than passing the command through silently.

#### Scenario: Bypassing a mistaken entry

- **WHEN** the user invokes a declared host-only command using the documented bypass
- **THEN** the command runs
- **AND** the bypass is reported rather than applied silently

#### Scenario: The bypass does not persist

- **WHEN** a bypassed invocation is followed by an ordinary invocation of the same command
- **THEN** the ordinary invocation is blocked as usual

### Requirement: Start-time verification asserts the guard is installed and working

The sandbox's start-time verification SHALL assert that this capability is actually in place, not merely intended, and SHALL fail the launch when it is not. The assertions SHALL cover the list being present and parseable, the enforcement mechanism being installed and activated by configuration outside the mounted workspace, and the session instructions being installed.

Verification SHALL additionally exercise the enforcement rather than only inspecting its configuration: it SHALL confirm that a command known to be on the list is blocked and that an ordinary command is not.

#### Scenario: Enforcement is not installed

- **WHEN** the enforcement mechanism, the list, or the session instructions are missing at container start
- **THEN** verification reports the failure and the launch fails

#### Scenario: Enforcement is installed but ineffective

- **WHEN** the enforcement mechanism is present but does not block a command known to be on the list
- **THEN** verification reports the failure and the launch fails

#### Scenario: Enforcement over-blocks

- **WHEN** the enforcement mechanism blocks an ordinary command that is not on the list
- **THEN** verification reports the failure and the launch fails

#### Scenario: Everything is in place

- **WHEN** the list, the enforcement, and the session instructions are all installed and behave correctly
- **THEN** verification passes this section and the launch proceeds
