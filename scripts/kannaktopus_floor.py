#!/usr/bin/env python3
"""
kannaktopus_floor.py — Join "The Floor" on radio.ninja-portal.com/player.

The Floor is a WebSocket-based presence system (server/floor.js) separate
from the NATS swarm bus. The little corner widget on /player ("👁 In the
room — N humans · M agents") tallies *connected WS clients* that sent a
`floor_join` message with `kind: 'human'` or `kind: 'agent'`. NATS-only
presence (queen.event.join + QUEEN.phase) does NOT bump the floor count.

This daemon opens a long-lived WebSocket to the radio, joins as
`kind: 'agent'`, and stays connected so the floor counter shows
"1 human · 1 agent" when Kannaktopus is online.

Env:
  RADIO_WS_URL                   (default wss://radio.ninja-portal.com/)
  KANNAKTOPUS_ARM_ID             (default kannaktopus-01)
  KANNAKTOPUS_LOG_LEVEL          (default INFO)

Dependency: ``pip install websockets>=11``.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import signal
import sys

try:
    import websockets  # type: ignore
    from websockets.exceptions import ConnectionClosed  # type: ignore
except ImportError:
    sys.stderr.write(
        "kannaktopus_floor: websockets is not installed. "
        "Run: pip install websockets\n"
    )
    sys.exit(2)


log = logging.getLogger("kannaktopus.floor")

WS_URL = os.environ.get("RADIO_WS_URL", "wss://radio.ninja-portal.com/")
ARM_ID = os.environ.get("KANNAKTOPUS_ARM_ID", "kannaktopus-01")

# The radio's floor server (kannaka-radio server/floor.js sanitizeId) keeps a
# floor_join id only when it matches /^[a-z0-9_:.-]{4,40}$/i and otherwise
# silently mints a random one. The floor merges WebSocket agents with swarm
# agents (QUEEN.phase.<arm_id>) by id, so a replaced id makes one arm count as
# two (#94). Normalizing here would not help: the swarm side would still use
# the original id. So an id the server would reject is refused up front.
# Used with fullmatch(): a Python `$` would also accept a trailing newline,
# which the JS regex does not. re.ASCII: without it IGNORECASE folds U+212A
# (Kelvin sign) and U+017F (long s) onto k/s, which the JS regex rejects.
FLOOR_ID_CHARS = r"[a-z0-9_:.-]"
FLOOR_ID_RE = re.compile(FLOOR_ID_CHARS + r"{4,40}", re.IGNORECASE | re.ASCII)
_FLOOR_ID_CHAR_RE = re.compile(FLOOR_ID_CHARS, re.IGNORECASE | re.ASCII)

# Exit status for a configuration error. kannaktopus-floor.service sets
# RestartPreventExitStatus=2 so systemd does not restart-loop on it.
EXIT_CONFIG_ERROR = 2


def floor_id_error(arm_id: str) -> str | None:
    """Return why ``arm_id`` would be replaced by the radio, or None if it is kept."""
    if FLOOR_ID_RE.fullmatch(arm_id):
        return None
    if not 4 <= len(arm_id) <= 40:
        return f"is {len(arm_id)} characters long; the radio floor needs 4-40"
    bad = sorted({c for c in arm_id if not _FLOOR_ID_CHAR_RE.fullmatch(c)})
    return "contains characters the radio floor rejects: " + " ".join(repr(c) for c in bad)


def join_payload(arm_id: str) -> str:
    return json.dumps({
        "type": "floor_join",
        "id": arm_id,
        "kind": "agent",
    })


async def _pump(ws) -> None:
    """Drain server messages so the WS doesn't backpressure-close.

    We don't care what the radio says — just stay connected so our
    presence keeps the agents counter at >=1. Print floor_welcome
    for visibility on first connect, otherwise stay quiet.
    """
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except (ValueError, TypeError):
            continue
        mtype = msg.get("type", "")
        if mtype == "floor_welcome":
            d = msg.get("data", {})
            log.info("floor_welcome id=%s kind=%s", d.get("id"), d.get("kind"))
        elif log.isEnabledFor(logging.DEBUG):
            log.debug("recv %s", mtype)


async def _stay_joined(stop: asyncio.Event) -> None:
    """One connection. Re-enters on disconnect via outer loop.

    The message pump is raced against ``stop`` rather than awaited on its
    own: ``async for raw in ws`` blocks for as long as the socket is
    healthy, so a SIGTERM arriving mid-connection used to go unobserved
    until the radio happened to disconnect us. systemd's default
    TimeoutStopSec (90s) would elapse and escalate to SIGKILL.
    """
    log.info("connecting WebSocket to %s", WS_URL)
    async with websockets.connect(
        WS_URL,
        ping_interval=20,
        ping_timeout=20,
        max_size=2**20,  # 1 MB; the radio chats but never throws huge frames at us.
    ) as ws:
        await ws.send(join_payload(ARM_ID))
        log.info("sent floor_join id=%s kind=agent", ARM_ID)

        pump = asyncio.ensure_future(_pump(ws))
        waiter = asyncio.ensure_future(stop.wait())
        try:
            await asyncio.wait({pump, waiter}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in (pump, waiter):
                task.cancel()
            # Collect both so a cancelled/failed task never warns as
            # "exception was never retrieved".
            await asyncio.gather(pump, waiter, return_exceptions=True)

        if stop.is_set():
            log.info("stop requested; closing WebSocket")
            await ws.close()
            return

        # The pump finished first — re-raise whatever ended it (a
        # ConnectionClosed, or nothing at all on a clean server-side end)
        # so run()'s reconnect/backoff logic sees it.
        pump.result()


async def run() -> int:
    logging.basicConfig(
        level=os.environ.get("KANNAKTOPUS_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    problem = floor_id_error(ARM_ID)
    if problem:
        log.error(
            "KANNAKTOPUS_ARM_ID %r %s (pattern ^[a-z0-9_:.-]{4,40}$, case-insensitive). "
            "The radio would replace it with a random id and this arm would count "
            "twice on the floor. Set KANNAKTOPUS_ARM_ID to a valid id, the same one "
            "the swarm presence uses. Not joining.",
            ARM_ID, problem,
        )
        return EXIT_CONFIG_ERROR
    log.info("starting floor daemon arm_id=%s url=%s", ARM_ID, WS_URL)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            # Windows: signal handlers not supported on the proactor loop.
            pass

    delay = 1.0
    while not stop.is_set():
        try:
            await _stay_joined(stop)
            # If the connection ended cleanly, fall through and reconnect.
            delay = 1.0
        except (ConnectionClosed, OSError) as exc:
            log.warning("WS dropped (%s); reconnecting in %.1fs", exc, delay)
        except Exception:  # noqa: BLE001
            log.exception("unexpected error; reconnecting in %.1fs", delay)
        if stop.is_set():
            break
        try:
            await asyncio.wait_for(stop.wait(), timeout=delay)
        except asyncio.TimeoutError:
            pass
        delay = min(delay * 2, 60.0)

    log.info("shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
