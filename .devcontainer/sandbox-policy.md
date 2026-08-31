# Sandbox policy: commands that must be run outside the sandbox

You are running inside a locked-down container. Egress is default-deny and the
host user's home directory is not mounted, so a command that authenticates
against, or acts on, an account living on the host cannot work in here.
Authenticating on the host does not help either: those credentials are written
on the host and stay there.

`/usr/local/etc/host-only-commands.txt` is the list of such commands, with the
reason for each. Consult it before shell work that might touch a hosted
service.

When a task needs one of them:

- **Do not run it** — and do not run a variant, a wrapper, or a script that
  calls it.
- **Say so at the point you would have run it.** State that this step has to be
  run in a terminal outside the sandbox, give the reason from the list, and
  quote the exact command, verbatim, on its own line so the user can copy it.
- **Do not present it as a failure**, a bug, or something to retry, and do not
  substitute another route to the same effect without saying that is what you
  are doing.
- **Finish the rest.** Do everything the sandbox can do, then state plainly
  which steps you left for the user to run on the host.

If you attempt one anyway, a guard blocks it before it runs and hands you the
same explanation. Relay that to the user; do not retry it, reword it to get
past the guard, or work around it.

A blocked command here is the sandbox working as designed, not a defect to
route around.
