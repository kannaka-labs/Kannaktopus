#!/usr/bin/env python3
"""
kannaktopus_listener.py — NATS command-channel listener for Kannaktopus.

Subscribes to ``KANNAKTOPUS.command.<arm_id>`` and ``KANNAKTOPUS.command.broadcast``
on the swarm bus so external controllers (the QueenSync Queen Console
control panel, the constellation orchestrator, manual ``nats req`` calls)
can drive this Kannaktopus instance without touching its host.

Pairs with ``queensync_presence.py``:
  - presence beacon publishes ``queen.event.join`` so observers see us
  - this listener subscribes to commands so observers can drive us

The two are independent processes — run both for full bidirectional control.

Protocol (request/reply, ``_INBOX.*`` reply subject):

    Request payload (JSON):
        {
            "cmd": "<command-name>",
            "args": { ... command-specific ... }
        }

    Reply payload (JSON):
        {
            "ok": true | false,
            "result": { ... },
            "error": "<message if !ok>"
        }

Supported commands (initial set; expand as the control panel grows):

    ping              — liveness probe; returns {pong: true, arm_id, ts}
    status            — reports MCP / orchestrate / HRM availability
    capabilities      — list registered skills / quick actions
    run               — args: {skill, prompt, [timeout_seconds]}
                        spawns the named skill via orchestrate.sh and
                        returns the stdout. NOT YET — placeholder for a
                        future iteration; today it returns "unimplemented".
    version           — reports Kannaktopus + python + NATS versions

Env:
    NATS_URL                       (default nats://swarm.ninja-portal.com:4222)
    NATS_USER, NATS_PASSWORD       (both required for authenticated subjects;
                                   without them the listener connects anon and
                                   logs a WARNING — the constellation bus
                                   restricts KANNAKTOPUS.command.* to
                                   authenticated users, so an anon listener may
                                   only ever receive KANNAKA.ask.*)
    KANNAKTOPUS_ARM_ID             (default kannaktopus-01)
    KANNAKTOPUS_LOG_LEVEL          (default INFO)
    HTTP_PORT                      (optional; the port mcp-server actually
                                   binds — reported as `mcp_listen_port`)

Dependency: ``pip install nats-py>=2.7``.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import platform
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Any

try:
    import nats  # type: ignore
    from nats.aio.msg import Msg  # type: ignore
    from nats.errors import Error as NatsError  # type: ignore
except ImportError:
    sys.stderr.write(
        "kannaktopus_listener: nats-py is not installed. "
        "Run: pip install nats-py\n"
    )
    sys.exit(2)


log = logging.getLogger("kannaktopus.listener")

NATS_URL = os.environ.get("NATS_URL", "nats://swarm.ninja-portal.com:4222")
NATS_USER = os.environ.get("NATS_USER", "")
NATS_PASSWORD = os.environ.get("NATS_PASSWORD", "")
ARM_ID = os.environ.get("KANNAKTOPUS_ARM_ID", "kannaktopus-01")

DIRECT_SUBJECT = f"KANNAKTOPUS.command.{ARM_ID}"
BROADCAST_SUBJECT = "KANNAKTOPUS.command.broadcast"
# Anon-publishable mirror per the bus's ADR-0026 authz config: anon clients
# are allowed to publish to KANNAKA.ask.> and subscribe to _INBOX.>, so the
# Replit control panel can hit this without holding kannaka_internal creds.
# Same payload schema as KANNAKTOPUS.command.<arm_id>; the same handlers
# fire on either subject.
ASK_SUBJECT = f"KANNAKA.ask.{ARM_ID}"
ASK_BROADCAST_SUBJECT = "KANNAKA.ask.broadcast"

KANNAKTOPUS_VERSION = os.environ.get("KANNAKTOPUS_VERSION", "dev")


# ── Command handlers ───────────────────────────────────────────────────

def cmd_ping(_args: dict[str, Any]) -> dict[str, Any]:
    return {"pong": True, "arm_id": ARM_ID, "ts": time.time()}


def _resolve_orchestrate() -> str | None:
    """Absolute path to orchestrate.sh, or None if it isn't installed.

    Checked in order: alongside THIS script (the ordinary case — the repo
    checkout ships scripts/orchestrate.sh but never puts it on PATH), then
    PATH, then the /opt install prefix. Probing only PATH and /opt made
    every non-/opt deployment report orchestrate_available=false even with
    the script sitting in the same directory as this listener.
    """
    local = Path(__file__).resolve().with_name("orchestrate.sh")
    if local.is_file():
        return str(local)
    on_path = shutil.which("orchestrate.sh")
    if on_path:
        return on_path
    packaged = "/opt/kannaktopus/scripts/orchestrate.sh"
    if os.path.isfile(packaged):
        return packaged
    return None


def _resolve_mcp_port() -> int | None:
    """Port the MCP HTTP server actually binds, or None if none is configured.

    mcp-server/src/index.ts starts its HTTP server only when HTTP_PORT is
    set; KANNAKTOPUS_MCP_PORT appears nowhere in mcp-server/src, so the old
    `KANNAKTOPUS_MCP_PORT or 8787` default advertised a port that nothing
    was listening on. KANNAKTOPUS_MCP_PORT is still honoured as an explicit
    operator override (e.g. a proxy fronting the server on another port) but
    is no longer invented when unset.
    """
    for var in ("HTTP_PORT", "KANNAKTOPUS_MCP_PORT"):
        raw = os.environ.get(var, "").strip()
        if not raw:
            continue
        try:
            return int(raw)
        except ValueError:
            log.warning("ignoring non-numeric %s=%r", var, raw)
    return None


def cmd_status(_args: dict[str, Any]) -> dict[str, Any]:
    """Best-effort probe of locally-resolvable Kannaktopus surfaces."""
    orchestrate_path = _resolve_orchestrate()
    kannaka_bin = shutil.which("kannaka")
    return {
        "arm_id": ARM_ID,
        # null when no HTTP listener is configured — see _resolve_mcp_port.
        "mcp_listen_port": _resolve_mcp_port(),
        "orchestrate_available": orchestrate_path is not None,
        "orchestrate_path": orchestrate_path,
        "kannaka_bin_available": bool(kannaka_bin),
        "platform": platform.platform(),
    }


def cmd_capabilities(_args: dict[str, Any]) -> dict[str, Any]:
    # Mirror queensync_presence.py CAPABILITIES so the control panel
    # can render matching quick-action buttons. Keep the two in sync;
    # eventually one constant should be sourced from a shared config.
    return {
        "capabilities": [
            "multi_model_query",
            "tool_orchestration",
            "consensus_review",
            "dream",
        ],
        "skills": [
            # Discovered later from skills/ dir; static placeholder for now.
        ],
    }


def cmd_run(args: dict[str, Any]) -> dict[str, Any]:
    # Placeholder. A full implementation should:
    #   1. Validate args.skill against the registered skill list.
    #   2. Spawn orchestrate.sh with the skill + prompt.
    #   3. Return either the stdout (if ≤ 64 KB) or a cursor + log path.
    # Deferred so this PR stays small — the control panel can stub against
    # this command and switch when the implementation lands.
    return {
        "implemented": False,
        "note": (
            "run command is reserved but not yet implemented. "
            "When it lands it will spawn orchestrate.sh with the named "
            "skill and stream output back via the reply inbox."
        ),
        "received_args": args,
    }


def cmd_version(_args: dict[str, Any]) -> dict[str, Any]:
    return {
        "kannaktopus": KANNAKTOPUS_VERSION,
        "python": platform.python_version(),
        "nats_py": getattr(nats, "__version__", "unknown"),
    }


def cmd_wake(args: dict[str, Any]) -> dict[str, Any]:
    """Wake-from-idle handshake for the QueenSync control panel.

    The Replit app sets KANNAKTOPUS_WAKE_URL=nats://swarm.ninja-portal.com:4222
    and posts `{"cmd":"wake"}` to `KANNAKA.ask.<arm_id>` (anon-publishable per
    the bus's ADR-0026 ACL). We acknowledge with the arm's identity + the
    same status payload `cmd_status` returns, so the Console can render the
    arm-detail panel in one round trip.

    Side effect: log a wake event so operators can correlate panel actions
    with arm activity. No actual idle/wake state machine is implemented
    yet — Kannaktopus is always-on while the systemd unit is enabled.
    """
    log.info("wake requested by control panel; reason=%r", args.get("reason"))
    return {
        "awake": True,
        "arm_id": ARM_ID,
        "ts": time.time(),
        "status": cmd_status({}),
    }


HANDLERS = {
    "ping": cmd_ping,
    "status": cmd_status,
    "capabilities": cmd_capabilities,
    "run": cmd_run,
    "version": cmd_version,
    "wake": cmd_wake,
}


# ── NATS plumbing ──────────────────────────────────────────────────────

def _connect_kwargs() -> dict[str, Any]:
    kw: dict[str, Any] = {
        "name": f"{ARM_ID}-listener",
        "connect_timeout": 5,
        "max_reconnect_attempts": -1,
        "reconnect_time_wait": 2,
    }
    if NATS_USER and NATS_PASSWORD:
        kw["user"] = NATS_USER
        kw["password"] = NATS_PASSWORD
    return kw


async def _connect_with_backoff() -> "nats.NATS":
    delay = 1.0
    while True:
        try:
            nc = await nats.connect(NATS_URL, **_connect_kwargs())
            if NATS_USER and NATS_PASSWORD:
                log.info("connected to NATS %s as %s", NATS_URL, NATS_USER)
            else:
                # Not fatal — KANNAKA.ask.> is anon-publishable — but every
                # KANNAKTOPUS.command.* subject we subscribe to is restricted
                # to authenticated users on the constellation bus, so an anon
                # listener is a half-deaf listener. Say so loudly.
                log.warning(
                    "connected to NATS %s as anon - KANNAKTOPUS.command.* is "
                    "restricted to authenticated users on this bus; set "
                    "NATS_USER and NATS_PASSWORD to receive those commands",
                    NATS_URL,
                )
            return nc
        except Exception as exc:  # noqa: BLE001
            log.warning("NATS connect failed (%s); retrying in %.1fs", exc, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60.0)


async def _handle_message(nc: "nats.NATS", msg: "Msg") -> None:
    reply_subject = msg.reply
    try:
        body = json.loads(msg.data.decode("utf-8") or "{}")
    except json.JSONDecodeError as exc:
        log.warning("malformed JSON on %s: %s", msg.subject, exc)
        if reply_subject:
            await nc.publish(
                reply_subject,
                json.dumps({"ok": False, "error": f"json_decode: {exc}"}).encode(),
            )
        return

    cmd = body.get("cmd", "")
    args = body.get("args", {}) or {}
    handler = HANDLERS.get(cmd)
    if handler is None:
        log.info("unknown command %r on %s", cmd, msg.subject)
        if reply_subject:
            await nc.publish(
                reply_subject,
                json.dumps(
                    {
                        "ok": False,
                        "error": f"unknown_command: {cmd}",
                        "supported": list(HANDLERS.keys()),
                    }
                ).encode(),
            )
        return

    log.info("command=%s subject=%s reply=%s", cmd, msg.subject, reply_subject)
    try:
        result = handler(args)
        payload = {"ok": True, "result": result}
    except Exception as exc:  # noqa: BLE001
        log.exception("handler %s raised", cmd)
        payload = {"ok": False, "error": f"handler_error: {exc}"}

    if reply_subject:
        try:
            await nc.publish(reply_subject, json.dumps(payload).encode("utf-8"))
        except NatsError as exc:
            log.warning("reply publish failed on %s: %s", reply_subject, exc)


async def run() -> int:
    logging.basicConfig(
        level=os.environ.get("KANNAKTOPUS_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    log.info(
        "starting command listener arm_id=%s direct=%s broadcast=%s ask=%s ask_bcast=%s",
        ARM_ID, DIRECT_SUBJECT, BROADCAST_SUBJECT, ASK_SUBJECT, ASK_BROADCAST_SUBJECT,
    )

    nc = await _connect_with_backoff()

    async def _on_msg(msg: "Msg") -> None:
        await _handle_message(nc, msg)

    wanted = (DIRECT_SUBJECT, BROADCAST_SUBJECT, ASK_SUBJECT, ASK_BROADCAST_SUBJECT)
    subscribed: list[str] = []
    for subject in wanted:
        # Per-subject guard: these subjects live under two different ACL
        # groups (KANNAKTOPUS.command.* is authenticated-only, KANNAKA.ask.*
        # is anon-publishable). Subscribing to all four in one unguarded
        # loop meant a single rejected subject aborted startup and took the
        # listener down with it, including the subjects it *was* allowed.
        try:
            await nc.subscribe(subject, cb=_on_msg)
        except Exception as exc:  # noqa: BLE001
            log.error("subscribe to %s failed (%s); continuing", subject, exc)
            continue
        subscribed.append(subject)

    if not subscribed:
        log.error(
            "subscribed to 0/%d subjects — the listener is running but deaf; "
            "check NATS credentials and bus ACLs", len(wanted),
        )
    else:
        log.info(
            "subscribed to %d/%d subjects (%s); awaiting commands",
            len(subscribed), len(wanted), ", ".join(subscribed),
        )

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            # Windows: signal handlers not supported on the proactor loop.
            pass

    await stop.wait()
    log.info("draining and shutting down")
    try:
        await nc.drain()
    except Exception:  # noqa: BLE001
        pass
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
