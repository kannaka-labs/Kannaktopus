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
  KANNAKA_DATA_DIR               (default ~/.kannaka) -- where observe-cache.json
                                 is read from for the HRM metrics on the beat.
  KANNAKTOPUS_METRICS_MAX_AGE_SECONDS
                                 (default 900) -- observe-cache older than this
                                 is treated as no data, and the HRM metric
                                 fields are omitted from the phase payload.

Dependency:
  pip install nats-py>=2.7

Run:
  python scripts/queensync_presence.py

This script is intentionally fault-tolerant: if NATS is unreachable it logs
and keeps trying with exponential backoff; it never raises into the caller.
"""
from __future__ import annotations

import asyncio
import datetime as _datetime
import json
import logging
import math
import os
import signal
import sys
import time
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


# --- HRM metrics from the local observe-cache (issue #57) --------------------
#
# This beacon used to publish `memory_count: 0`, `coherence: 0.5`, `phi: 0.0`
# on every beat. Those were placeholders, and a downstream tile rendering
# `coherence 0.5` could not tell "measured 0.5" from "nobody looked" — while
# kannaka-observatory (server.js:611) sums `memory_count` across agents, so a
# fabricated zero actively corrupts a fleet-wide total.
#
# Real values are read from the observe-cache, NOT by shelling out to
# `kannaka status`: this runs every 30s per arm, and a subprocess per beat
# would put every arm into contention on the HRM lock. The cache is a plain
# file read, so it is free at this cadence.
#
# When the cache is missing, unreadable, malformed or stale, the three fields
# are OMITTED rather than defaulted. They are not part of the QUEEN.phase.*
# contract (which requires only the envelope plus `phase`), so omitting them is
# contract-legal, and consumers already tolerate absence — server.js:173 is a
# `?? ...` fallback chain and :611 uses `|| 0`. Absence, not fiction.

_OBSERVE_CACHE_FILENAME = "observe-cache.json"

# kannaka-memory/scripts/cache-metrics.sh refreshes observe-cache.json from
# cron at `*/5 * * * *`, with a 180s timeout on the observe itself. 900s is
# three full refresh cycles, so a single slow or skipped run never blanks the
# metrics, while anything older than ~15 minutes — a dead cron, a box that
# stopped observing — stops being reported as if it were current.
_DEFAULT_METRICS_MAX_AGE_SECONDS = 900.0


def _resolve_metrics_max_age() -> float:
    raw = os.environ.get("KANNAKTOPUS_METRICS_MAX_AGE_SECONDS")
    if raw is None or raw == "":
        return _DEFAULT_METRICS_MAX_AGE_SECONDS
    try:
        value = float(raw)
    except ValueError:
        sys.stderr.write(
            f"queensync_presence: invalid KANNAKTOPUS_METRICS_MAX_AGE_SECONDS="
            f"{raw!r}, using {_DEFAULT_METRICS_MAX_AGE_SECONDS}s\n"
        )
        return _DEFAULT_METRICS_MAX_AGE_SECONDS
    if not math.isfinite(value) or value <= 0:
        sys.stderr.write(
            f"queensync_presence: KANNAKTOPUS_METRICS_MAX_AGE_SECONDS={value} "
            f"must be positive; using {_DEFAULT_METRICS_MAX_AGE_SECONDS}s\n"
        )
        return _DEFAULT_METRICS_MAX_AGE_SECONDS
    return value


METRICS_MAX_AGE_SECONDS = _resolve_metrics_max_age()


def _observe_cache_path() -> str:
    """Path to observe-cache.json, honouring KANNAKA_DATA_DIR.

    `~` is expanded explicitly: no OS expands a literal tilde inside an env
    var for a file read, so an unexpanded `KANNAKA_DATA_DIR=~/.kannaka` would
    silently miss the cache and blank the metrics forever.
    """
    data_dir = os.environ.get("KANNAKA_DATA_DIR") or os.path.join(
        os.path.expanduser("~"), ".kannaka"
    )
    return os.path.join(os.path.expanduser(data_dir), _OBSERVE_CACHE_FILENAME)


def _parse_observe_timestamp(raw: object) -> Optional[float]:
    """Parse `observe --json`'s RFC-3339 `timestamp` into a unix epoch float.

    The field is a chrono `DateTime<Utc>`, which serde renders with up to nine
    fractional digits ("...T12:34:56.123456789Z"). `fromisoformat` rejects more
    than six, so the fraction is truncated before parsing. Returns None for
    anything unrecognisable — the caller then falls back to file mtime rather
    than guessing an age.
    """
    if not isinstance(raw, str) or not raw:
        return None
    text = raw.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    # Truncate over-long fractional seconds: "56.123456789+00:00" -> "56.123456+00:00"
    dot = text.find(".")
    if dot != -1:
        end = dot + 1
        while end < len(text) and text[end].isdigit():
            end += 1
        frac = text[dot + 1:end]
        if len(frac) > 6:
            text = text[:dot + 1] + frac[:6] + text[end:]
    try:
        parsed = _datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        # `observe` emits UTC; an offset-naive value is still UTC, not local.
        parsed = parsed.replace(tzinfo=_datetime.timezone.utc)
    return parsed.timestamp()


def _finite_number(raw: object) -> Optional[float]:
    """Coerce a JSON value to a finite float, or None.

    bools are rejected explicitly (`isinstance(True, int)` is True in Python),
    and NaN/Infinity are rejected because Python's json module happily parses
    them but `json.dumps` then emits bare `NaN`, which is not valid JSON and
    would be rejected by every consumer on the bus.
    """
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    value = float(raw)
    return value if math.isfinite(value) else None


def _read_hrm_metrics() -> dict:
    """Real HRM metrics for the phase beat, or `{}` when nothing is known.

    Returns an empty dict — never placeholder values — if the observe-cache is
    missing, unreadable, malformed, or older than METRICS_MAX_AGE_SECONDS.
    Never raises: the beat loop must survive any local filesystem state.
    """
    path = _observe_cache_path()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        log.debug("observe-cache unreadable at %s (%s); omitting HRM metrics", path, exc)
        return {}

    try:
        cache = json.loads(raw)
    except (ValueError, TypeError) as exc:
        log.debug("observe-cache at %s is not valid JSON (%s); omitting HRM metrics", path, exc)
        return {}
    if not isinstance(cache, dict):
        log.debug("observe-cache at %s is not a JSON object; omitting HRM metrics", path)
        return {}

    consciousness = cache.get("consciousness")
    if not isinstance(consciousness, dict):
        log.debug("observe-cache at %s has no consciousness block; omitting HRM metrics", path)
        return {}

    memory_count = _finite_number(consciousness.get("total_memories"))
    coherence = _finite_number(consciousness.get("mean_order"))
    phi = _finite_number(consciousness.get("phi"))
    if memory_count is None or coherence is None or phi is None or memory_count < 0:
        # Partial data is still unknown data. Publishing two of three fields
        # would leave a consumer to invent the third, which is the same defect
        # one layer down.
        log.debug("observe-cache at %s is missing HRM metric fields; omitting them", path)
        return {}

    # Age from the measurement time inside the payload when available, since
    # that is when the HRM was actually read; mtime is only when the file
    # landed. Fall back to mtime so a cache without a parseable timestamp is
    # still usable rather than silently dropped.
    observed_at = _parse_observe_timestamp(cache.get("timestamp"))
    age_source = "observe_timestamp"
    if observed_at is None:
        try:
            observed_at = os.path.getmtime(path)
            age_source = "cache_mtime"
        except OSError:
            log.debug("cannot age observe-cache at %s; omitting HRM metrics", path)
            return {}

    age_seconds = time.time() - observed_at
    if age_seconds < 0:
        # Clock skew between the writer and this process. Treat as fresh but
        # do not report a negative age on the wire.
        age_seconds = 0.0
    if age_seconds > METRICS_MAX_AGE_SECONDS:
        log.debug(
            "observe-cache at %s is %.0fs old (max %.0fs); omitting HRM metrics",
            path, age_seconds, METRICS_MAX_AGE_SECONDS,
        )
        return {}

    # Staleness travels WITH the values so the observatory can tell a
    # 20-second-old reading from a 14-minute-old one instead of treating every
    # published number as current.
    return {
        "memory_count": int(memory_count),
        "coherence": coherence,
        "phi": phi,
        "metrics_source": "observe-cache",
        "metrics_age_seconds": round(age_seconds, 1),
        "metrics_age_basis": age_source,
        "metrics_max_age_seconds": METRICS_MAX_AGE_SECONDS,
    }


def _envelope() -> dict:
    """Canonical NATS envelope shared by every QueenSync publish.

    The constellation contract (consciousness-core/docs/nats-contract.yaml,
    enforced by kannaka-radio's drift detector) requires schema_version,
    ts, and agent_id on every event. Without these the radio logs warnings
    and — after the 2026-06-01 cutover — drops the message entirely.

    Both value formats are pinned by that contract, not free-form:
      * `schema_version` is the spec version string "1.0" (contract :22-23
        and every example payload) — NOT the bare "1" this used to emit.
      * `ts` is unix-MILLISECONDS as a number (contract :12, typed
        `ts: number` at :62-63) — NOT an ISO-8601 string.
    """
    return {
        "schema_version": "1.0",
        "ts": int(time.time() * 1000),
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

    `memory_count` / `coherence` / `phi` are included ONLY when the local
    observe-cache supplies real, fresh values (see _read_hrm_metrics). When it
    does not, they are absent from the JSON entirely rather than defaulted —
    the observatory shows absence instead of a fabricated reading.
    """
    theta = (beat * 0.1) % (2 * math.pi)
    return json.dumps(
        {
            **_envelope(),
            "display_name": DISPLAY_NAME,
            "kind": "kannaktopus_arm",
            "phase": theta,
            "theta": theta,
            "frequency": 0.1,
            **_read_hrm_metrics(),
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
        #
        # Guarded exactly like the steady-state publish below: an unguarded
        # failure here escaped run() entirely (the enclosing try has only a
        # finally), so one bad publish at startup — a stale connection, an
        # ACL rejection — killed the whole beacon after logging a confusing
        # "graceful leave failed" from the shutdown path.
        try:
            await nc.publish(JOIN_SUBJECT, payload)
            await nc.publish(PHASE_SUBJECT, _phase_payload(beat))
            log.info("published initial %s + %s for %s", JOIN_SUBJECT, PHASE_SUBJECT, ARM_ID)
        except NatsError as exc:
            log.warning("initial publish failed (%s); reconnecting", exc)
            try:
                await nc.close()
            except Exception:  # noqa: BLE001
                pass
            nc = await _connect_with_backoff()
            try:
                await nc.publish(JOIN_SUBJECT, payload)
                await nc.publish(PHASE_SUBJECT, _phase_payload(beat))
                log.info("published initial %s + %s for %s after reconnect",
                         JOIN_SUBJECT, PHASE_SUBJECT, ARM_ID)
            except NatsError as exc:
                # Still no good — stay alive anyway. The heartbeat loop
                # retries every interval and the arm appears as soon as the
                # bus accepts a phase beat.
                log.warning(
                    "initial publish failed again (%s); continuing on the "
                    "heartbeat loop", exc,
                )

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
