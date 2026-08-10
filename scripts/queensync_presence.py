#!/usr/bin/env python3
"""
queensync_presence.py — Constellation presence beacon for Kannaktopus.

Publishes a `queen.event.join` message every 30s (configurable) to the public
NATS swarm bus so this Kannaktopus instance shows up as an agent on
`observatory.ninja-portal.com` and flips its arm card on the QueenSync Queen
Console from `offline` -> `idle`.

QueenSync's NATS bridge (artifacts/api-server/src/lib/nats-bridge.ts ->
handlePresence) treats every join message as a heartbeat for the named arm.
A `queen.event.leave` is published on clean shutdown so the card flips
immediately rather than waiting for the 3-min staleness sweep.

Env:
  NATS_URL                       (default nats://swarm.ninja-portal.com:4222)
  KANNAKTOPUS_ARM_ID             (default kannaktopus-01) -- this becomes the
                                 agent label in the observatory swarm map.
  KANNAKTOPUS_DISPLAY_NAME       (default "Kannaktopus")
  KANNAKTOPUS_PRESENCE_SECONDS   (default 30)

Dependency:
  pip install nats-py>=2.7

Run:
  python scripts/queensync_presence.py

This script is intentionally fault-tolerant: if NATS is unreachable it logs
and keeps trying with exponential backoff; it never raises into the caller.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
from typing import Optional

try:
    import nats  # type: ignore
    from nats.errors import Error as NatsError  # type: ignore
except ImportError:
    sys.stderr.write(
        "queensync_presence: nats-py is not installed. Run: pip install nats-py\n"
    )
    sys.exit(2)


log = logging.getLogger("kannaktopus.presence")

NATS_URL = os.environ.get("NATS_URL") or os.environ.get(
    "KANNAKA_NATS_URL", "nats://swarm.ninja-portal.com:4222"
)
ARM_ID = os.environ.get("KANNAKTOPUS_ARM_ID", "kannaktopus-01")
DISPLAY_NAME = os.environ.get("KANNAKTOPUS_DISPLAY_NAME", "Kannaktopus")

# Constellation operators ask publishers to stay >=10s between beats so the
# bus doesn't get flooded. Clamp aggressively rather than fail open.
_MIN_INTERVAL_SECONDS = 10.0
_DEFAULT_INTERVAL_SECONDS = 30.0


def _resolve_interval() -> float:
    raw = os.environ.get("KANNAKTOPUS_PRESENCE_SECONDS")
    if raw is None or raw == "":
        return _DEFAULT_INTERVAL_SECONDS
    try:
        value = float(raw)
    except ValueError:
        sys.stderr.write(
            f"queensync_presence: invalid KANNAKTOPUS_PRESENCE_SECONDS={raw!r}, "
            f"using {_DEFAULT_INTERVAL_SECONDS}s\n"
        )
        return _DEFAULT_INTERVAL_SECONDS
    if value < _MIN_INTERVAL_SECONDS:
        sys.stderr.write(
            f"queensync_presence: KANNAKTOPUS_PRESENCE_SECONDS={value} below "
            f"floor; clamping to {_MIN_INTERVAL_SECONDS}s\n"
        )
        return _MIN_INTERVAL_SECONDS
    return value


INTERVAL_SECONDS = _resolve_interval()

JOIN_SUBJECT = "queen.event.join"
LEAVE_SUBJECT = "queen.event.leave"
# Kannaka radio's NATS bridge populates `swarmState.agents` (the map
# surfaced on /api/swarm and observatory.ninja-portal.com) only from
# `QUEEN.phase.<agent_id>` messages — `queen.event.join` lands in the
# event log but NOT in the agents map. So we also publish a phase
# heartbeat each cycle so the arm shows up in the observatory's agent
# count and visualisation, not just its event ticker.
PHASE_SUBJECT = f"QUEEN.phase.{ARM_ID}"

# Capability list mirrors what Kannaktopus actually does so the Queen Console
# arm-detail panel can render the right quick-action buttons. Edit freely.
CAPABILITIES = [
    "multi_model_query",
    "tool_orchestration",
    "consensus_review",
    "dream",
]


def _envelope() -> dict:
    """Canonical NATS envelope shared by every QueenSync publish.

    The constellation contract (consciousness-core/docs/nats-contract.yaml,
    enforced by kannaka-radio's drift detector) requires schema_version,
    ts, and agent_id on every event. Without these the radio logs warnings
    and — after the 2026-06-01 cutover — drops the message entirely.
    """
    from datetime import datetime, timezone
    return {
        "schema_version": "1",
        "ts": datetime.now(timezone.utc).isoformat(),
        "agent_id": ARM_ID,
    }


def _payload() -> bytes:
    return json.dumps(
        {
            **_envelope(),
            "armId": ARM_ID,
            "displayName": DISPLAY_NAME,
            "kind": "kannaktopus_arm",
            "capabilities": CAPABILITIES,
        }
    ).encode("utf-8")


def _phase_payload(beat: int) -> bytes:
    """Heartbeat payload published on QUEEN.phase.<arm_id>.

    The radio's nats-client.js reads `phase` (or `theta`) and `display_name`,
    sets `lastSeen` itself, and prunes agents not seen for 5 min. We rotate
    the phase value gently so the observatory's swarm visualisation shows
    Kannaktopus as a *moving* oscillator rather than a static dot.
    """
    import math
    theta = (beat * 0.1) % (2 * math.pi)
    return json.dumps(
        {
            **_envelope(),
            "display_name": DISPLAY_NAME,
            "kind": "kannaktopus_arm",
            "phase": theta,
            "theta": theta,
            "frequency": 0.1,
            "memory_count": 0,
            "coherence": 0.5,
            "phi": 0.0,
            "capabilities": CAPABILITIES,
        }
    ).encode("utf-8")


async def _connect_with_backoff() -> "nats.NATS":
    delay = 1.0
    user = os.environ.get("NATS_USER", "")
    password = os.environ.get("NATS_PASSWORD", "")
    while True:
        try:
            kwargs: dict = {
                "name": f"{ARM_ID}-presence",
                "connect_timeout": 5,
                "max_reconnect_attempts": -1,
                "reconnect_time_wait": 2,
            }
            # NATS auth — required when the bus restricts queen.event.* /
            # QUEEN.phase.* publishes to authenticated users only (which is
            # the default config on the constellation bus). Without these
            # credentials, every publish is silently rejected as anon.
            if user and password:
                kwargs["user"] = user
                kwargs["password"] = password
            nc = await nats.connect(NATS_URL, **kwargs)
            log.info("connected to NATS %s as %s", NATS_URL, user or "anon")
            return nc
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "NATS connect failed (%s); retrying in %.1fs", exc, delay
            )
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60.0)


async def run() -> int:
    logging.basicConfig(
        level=os.environ.get("KANNAKTOPUS_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    log.info(
        "starting presence beacon arm_id=%s interval=%.1fs subject=%s",
        ARM_ID, INTERVAL_SECONDS, JOIN_SUBJECT,
    )

    nc = await _connect_with_backoff()
    payload = _payload()

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            # Windows: signal handlers not supported on the proactor loop.
            pass

    beat = 0
    try:
        # Send first join + phase immediately so the arm shows up within a
        # second of the daemon starting (don't wait one interval).
        await nc.publish(JOIN_SUBJECT, payload)
        await nc.publish(PHASE_SUBJECT, _phase_payload(beat))
        log.info("published initial %s + %s for %s", JOIN_SUBJECT, PHASE_SUBJECT, ARM_ID)

        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=INTERVAL_SECONDS)
            except asyncio.TimeoutError:
                pass
            if stop.is_set():
                break
            beat += 1
            try:
                # Heartbeat ONLY via QUEEN.phase. queen.event.join was being
                # republished every 30s, which the radio's nats-bridge appends
                # to its agentEvents log + broadcasts as type=queen_join — so
                # the player's activity feed showed Kannaktopus joining and
                # rejoining on every beat. The right semantic is: join once
                # at startup, leave once at shutdown, heartbeat via phase.
                # The 5min staleness sweep in nats-client.js still uses
                # lastSeen from QUEEN.phase, so liveness is preserved.
                await nc.publish(PHASE_SUBJECT, _phase_payload(beat))
                log.debug("published %s for %s (beat=%d)", PHASE_SUBJECT, ARM_ID, beat)
            except NatsError as exc:
                log.warning("publish failed: %s", exc)
    finally:
        try:
            await nc.publish(LEAVE_SUBJECT, payload)
            await nc.flush(timeout=2)
            log.info("published %s for %s on shutdown", LEAVE_SUBJECT, ARM_ID)
        except Exception as exc:  # noqa: BLE001
            log.warning("graceful leave failed: %s", exc)
        try:
            await nc.drain()
        except Exception:  # noqa: BLE001
            pass

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
