#!/usr/bin/env python3
"""Can this Mac open a UDP socket at all?  Prints `ok` or an errno name.

This exists because `dig ... 2>/dev/null` cannot tell "the resolver did not
answer" from "this machine could not send the question". On 2026-10-07 the
second one was true for over an hour: every UDP dig failed with
`isc_socket_bind: address not available` (ephemeral-port exhaustion), and
Hopwatch told the user to restart their router. The probe below does not
depend on dig's wording: it asks the kernel for a UDP socket bound to port 0
(any free ephemeral port) and reports what the kernel said.

Output, one line, always exit 0 (a helper that can fail loudly is a helper
the caller has to guard; the output is the answer):

  ok            a UDP socket could be created and bound
  EADDRNOTAVAIL (or any other errno name) the kernel refused. The name is
                the symbolic errno, never the translated message, so a
                caller matches on a stable token.
  error         the failure was not an OS error at all (no socket module,
                an unexpected exception) -- the caller must NOT read this
                as "the Mac cannot open sockets".

Bash calls this only after a dig came back empty, so the healthy path pays
nothing for it (lib/common.sh, dns_local_fault_check).

No privileges, no network traffic: binding to port 0 sends nothing.
"""

from __future__ import annotations

import errno
import socket
import sys


def check(socket_factory=socket.socket) -> str:
    """Return `ok` or the errno name for a failed UDP bind to port 0.

    `socket_factory` is injectable so tests can simulate the kernel
    refusing, without having to exhaust the machine's real port range.
    """
    try:
        s = socket_factory(socket.AF_INET, socket.SOCK_DGRAM)
    except OSError as exc:
        return errno.errorcode.get(exc.errno or 0, "error")
    try:
        s.bind(("", 0))
    except OSError as exc:
        return errno.errorcode.get(exc.errno or 0, "error")
    finally:
        try:
            s.close()
        except OSError:
            pass
    return "ok"


def main() -> int:
    try:
        print(check())
    except Exception:  # noqa: BLE001 -- the contract is "one line, exit 0"
        print("error")
    return 0


if __name__ == "__main__":
    sys.exit(main())
