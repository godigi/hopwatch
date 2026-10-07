# Repair actions — "Fix it" buttons

Status: proposed, not implemented. Written 2026-10-07. Decided with the
owner the same day: repairs are wanted, **including ones that ask for an
admin password**.

## Why

Hopwatch tells people what is wrong and then leaves them with a paragraph of
instructions. The audience does not know what DNS is. When the fix is one
known action, a button that does it — and then checks whether it worked — is
the better experience.

## The rule that changes

Until now the contract was "100% sudo-free" and "read-only", with no
exceptions. Both were written about monitoring and diagnosis, and both still
hold there. The new contract (see `CLAUDE.md`):

- **Monitoring and diagnosis** never ask for a password and never change
  system state. Unchanged.
- **Repairs** are a separate tier. A repair runs only when the user presses
  its button. Nothing is ever repaired automatically, on a timer, on arrival,
  or from an alert. A repair may change system state and may ask for an admin
  password, and it says so before it does either.

## Experience

1. A finding that has a repair shows **one** button, labelled with the action
   itself: "Quit Spotify", "Switch to public DNS", "Turn Wi-Fi off and on".
   Never a generic "Fix".
2. Pressing it opens a short confirmation: what will change, whether it asks
   for a password, and how to undo it if it persists.
3. The repair runs. Afterwards the app runs its quick depth on its own and
   reports one of two things: **"Fixed"**, or **"That didn't help"** with the
   next thing to try. A repair that reports nothing is not done.
4. A repair that leaves a lasting change (a DNS switch) stays visible on Home
   — "Using public DNS, set by Hopwatch on 7 Oct · Undo" — because the
   setting follows the user to every other network.
5. Every repair is written to the event journal, so "what did I change" has
   an answer later.

## Repairs in scope

| ID | What it does | Admin? | Offered by |
|---|---|---|---|
| `quit-app` | Asks one named app to quit | No | `SOCK-1`, when a visible app holds the sockets |
| `restart-mac` | Shows the standard restart dialog | No | `SOCK-1`, when no holder is visible |
| `wifi-cycle` | Wi-Fi off, then on | Believed no — **untested** | weak-link and gateway-loss rules |
| `open-sign-in` | Opens the network's sign-in page | No | the captive-portal finding |
| `set-public-dns` | Sets 1.1.1.1 and 8.8.8.8 on the Wi-Fi service; records the previous value | Believed yes — **untested** | `D6` |
| `undo-public-dns` | Restores the recorded value | Same as above | Home, after `set-public-dns` |
| `renew-lease` | Renews the DHCP lease | Yes | joined-with-no-route and DHCP findings |
| `restart-lookups` | Flushes the DNS cache and restarts the Mac's lookup service | Yes | no rule yet — see below |

Deliberately **not** in scope:

- Killing a system-owned process to free sockets. Hopwatch cannot see which
  one without root, and killing the wrong daemon is worse than a restart.
- `restart-lookups` has no rule to offer it. Every probe uses `dig`, which
  bypasses the Mac's own lookup service, so Hopwatch cannot currently tell
  that the service is stuck. The repair ships only with a detection for it.
- Relaunching Chrome after a background update. The relaunch is `quit-app`
  plus reopen; the missing part is detection. Candidate signal, untested: the
  version on disk is newer than the version running.

## Where the logic lives

The GUI holds no diagnostic logic, and that does not change.

- **Which repair a finding offers** is decided by the CLI. Each diagnosis in
  `--json` gains an optional `repairs` array; each entry carries the repair
  ID, the button label, the confirmation text, and validated parameters (an
  app's bundle id, an interface name). The prose is written in `lib/`.
- **Repairs that need no password** are run by the CLI: `hopwatch
  --repair=ID`. They are ordinary CLI surface, documented and bats-tested,
  with `--dry-run` printing what would run.
- **Repairs that need a password** are the one exception, for a security
  reason below: the app runs them from a fixed table compiled into the app.

## Security of the admin path

The risk is not the password prompt; it is what runs after it.

- **Root never executes anything a user-level process can rewrite.** The CLI
  lives in a user-writable checkout. If root ran `bin/hopwatch`, any program
  running as the user could edit that file and wait for the next repair. So
  the privileged commands are a fixed table inside the app: absolute paths to
  system binaries (`/usr/sbin/networksetup`, `/usr/sbin/ipconfig`,
  `/usr/bin/dscacheutil`, `/usr/bin/killall`) with fixed arguments.
- **Parameters are validated, never interpolated from the network.** An
  interface must match `^en[0-9]+$`; a network service name must be one the
  system itself lists. A Wi-Fi name, hostname or DHCP-supplied string never
  reaches a privileged command line.
- **One prompt, one action.** No cached credentials, no helper left running.

**Mechanism.** The app is signed ad hoc or with a local self-signed identity
(`gui/Makefile`), not an Apple Developer ID. That rules out a privileged
helper (`SMAppService`), which needs Developer ID signing and notarisation.
The available mechanism is AppleScript's `do shell script … with
administrator privileges`, run in-process. Whether the prompt names Hopwatch
or a generic process is **untested** and decides how trustworthy it looks.
If Hopwatch is later notarised, move to a privileged helper.

## Knock-on changes

- `DH-2` currently says "somebody manually overrode" the DNS. After
  `set-public-dns` it must say Hopwatch did, and offer the undo.
- `D6`'s summary still explains the manual steps; with the button present it
  should lead with the button.
- `docs/JSON-SCHEMA.md` (`repairs`), `docs/ARCHITECTURE.md` (the repair
  tier), README (the password prompt, so nobody is surprised by it).

## Order of work

1. Plumbing: `repairs` in the JSON, `--repair`, the confirmation and
   verify-after flow, journal entries. Ship with `quit-app`, `restart-mac`,
   `open-sign-in`.
2. `wifi-cycle`, once tested for whether it needs admin.
3. The admin path, with `set-public-dns` + undo first, then `renew-lease`.

## Not known yet

- Whether `wifi-cycle` and `set-public-dns` need a password on a standard
  admin account.
- What the password prompt says when raised from this app.
- Whether socket exhaustion was really the 2026-10-07 fault. `quit-app` for
  `SOCK-1` rests on that diagnosis, which is likely but unproven.
