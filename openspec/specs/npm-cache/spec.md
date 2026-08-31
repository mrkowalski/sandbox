## Purpose

Gives the sandbox a writable, exec-capable npm cache so that ordinary JavaScript tooling (`npm install`, `npx <tool>`) works against a project mounted at `/workspace`, while holding the sandbox's existing confinement guarantees — read-only rootfs, default-deny egress, no `git push` — unchanged.

## Requirements

### Requirement: npm commands that fetch from the registry succeed

The sandbox SHALL provide npm with a cache directory it can write to, so that npm operations requiring a registry fetch complete successfully rather than failing with `EROFS`.

#### Scenario: npx runs a tool that is not already installed

- **WHEN** a user in the container runs `npx prettier --check <file>` with no local `prettier` installed
- **THEN** npm fetches `prettier` from `registry.npmjs.org`, writes it to the cache, and executes it
- **AND** the command reports prettier's own formatting verdict
- **AND** no `EROFS` or `read-only file system` error is emitted

#### Scenario: npm install writes into a project

- **WHEN** a user runs `npm install` in a project under `/workspace`
- **THEN** the install completes without a read-only-filesystem error from the cache directory

### Requirement: The npm cache is exec-capable

The npm cache directory SHALL reside on a filesystem mounted without `noexec`, because `npx` executes package binaries staged inside the cache. A writable-but-`noexec` cache is not sufficient and SHALL NOT be treated as satisfying this capability.

#### Scenario: A staged package binary can be executed

- **WHEN** an executable file is created inside the npm cache directory and run
- **THEN** it executes rather than failing with `Permission denied` (exit code 126)

#### Scenario: The cache is not placed on the noexec /tmp tmpfs

- **WHEN** the container's mount table is inspected
- **THEN** the npm cache directory is not backed by the `/tmp` tmpfs, which is mounted `noexec`

### Requirement: The npm cache persists across container restarts

The npm cache SHALL be backed by storage that survives a container restart and is scoped to a single dev container instance, so that a package downloaded in one session need not be re-downloaded in the next, and so that two dev containers do not share cache state.

#### Scenario: Cached package survives a restart

- **WHEN** a package is fetched in one session and the container is restarted
- **THEN** the cached package is still present and is served from cache rather than re-fetched

#### Scenario: Cache starts warm on first creation

- **WHEN** the cache storage is created for the first time for a given dev container
- **THEN** it contains the cache content baked into the image by the image's own global npm installs, rather than being empty

### Requirement: The writable cache does not widen the sandbox's egress policy

Providing the cache SHALL NOT add any reachable host. The set of hosts the container can reach SHALL remain exactly the set resolved from `allowed-domains.txt`, and every existing egress guarantee SHALL continue to hold.

#### Scenario: Arbitrary egress remains blocked

- **WHEN** verification probes a non-whitelisted host such as `example.com` by name and by IP, over HTTP and HTTPS
- **THEN** every probe fails to establish a TCP connection

#### Scenario: The whitelist file is unchanged by this capability

- **WHEN** the egress whitelist is compared before and after this capability is provided
- **THEN** no hostname has been added, removed, or changed

#### Scenario: git push remains impossible

- **WHEN** verification attempts `git push --dry-run` over SSH and over HTTPS
- **THEN** both attempts fail

### Requirement: The writable cache does not widen the read-only rootfs

The cache SHALL be the only new writable location, and it SHALL NOT be a path from which executables, scripts, or configuration on the system's trusted paths are read. Every other part of the rootfs SHALL remain read-only.

#### Scenario: Security-critical paths stay read-only

- **WHEN** a write is attempted to `/usr/local/bin/`, to `/usr/local/etc/allowed-domains.txt`, and to the global node_modules directory holding the Claude Code binary
- **THEN** each write fails with a read-only-filesystem error

#### Scenario: The rootfs at large stays read-only

- **WHEN** a write is attempted to a location on the rootfs outside the sanctioned writable paths
- **THEN** the write fails with a read-only-filesystem error

#### Scenario: No new container capability is granted

- **WHEN** the container's capability set is inspected
- **THEN** it grants no capability beyond `NET_ADMIN` and `NET_RAW`

### Requirement: The cache guarantees are verified at every container start

Consistent with the sandbox's design that guarantees are checked rather than documented, the verification suite SHALL assert both halves of this capability — that the cache is writable and exec-capable, and that the rootfs and egress restrictions still hold. A failure SHALL block the container from starting.

#### Scenario: Verification asserts the cache is usable

- **WHEN** the verification suite runs at container start
- **THEN** it reports a passing check that the npm cache directory is writable and exec-capable

#### Scenario: A broken cache mount blocks launch

- **WHEN** the cache directory is missing, not writable, or mounted `noexec`
- **THEN** verification reports a failure, prints `NOT VERIFIED`, exits non-zero, and the container launch fails

#### Scenario: A regression in confinement blocks launch

- **WHEN** the rootfs is writable where it should not be, or arbitrary egress becomes reachable
- **THEN** verification reports a failure and the container launch fails
