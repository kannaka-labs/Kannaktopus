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
            "schema_version": "1.0",
            "ts": <unix milliseconds>,
            "agent_id": "<arm_id>",
            "ok": true | false,
            "result": { ... },
            "error": "<message if !ok>"
        }

    Every reply — including the malformed-JSON and unknown-command errors —
    carries the canonical constellation envelope (schema_version / ts /
    agent_id), matching queensync_presence.py::_envelope(). `agent_id` is
    what makes broadcast replies individually attributable: NATS delivers
    every arm's reply into the requester's single `_INBOX.<id>`, so without
    an arm identity in the payload the replies are indistinguishable and
    `nc.request()` silently keeps one at random (see #60). Clients wanting
    fan-out subscribe to their own inbox, publish with it as `reply`, and
    collect until a deadline — see docs/control-panel-api.md.

Supported commands (initial set; expand as the control panel grows):

    ping              — liveness probe; returns {pong: true, arm_id, ts}
    status            — reports MCP / orchestrate / HRM availability
    capabilities      — registered skills (from skills/*/SKILL.md) + quick actions
    run               — args: {skill, prompt, [timeout_seconds]}
                        DELIBERATELY DEFERRED (#32), not a forgotten stub:
                        returns {implemented: false} by contract. Spawning
                        orchestrate.sh from this handler table would make the
                        anon-publishable KANNAKA.ask.broadcast subject a
                        remote-code-execution path, so the bus ACLs, a command
                        allowlist, timeouts and bounded output capture all have
                        to be settled before it can ship.
    version           — reports Kannaktopus + python + NATS versions

Credentials (fail closed, #28):
    Resolved from NATS_USER + NATS_PASSWORD (or NATS_CREDS), falling back to
    parsing ~/.kannaka-nats.env — the file the constellation crons already
    source. If nothing resolves AND the subject set includes the
    authenticated-only KANNAKTOPUS.command.* subjects, the listener exits
    non-zero *before connecting* rather than joining anon and pretending to
    serve subjects it will never receive. To run a legitimately anon-only
    listener (the documented Replit control-panel path) pass --anon-only /
    set KANNAKTOPUS_ANON_ONLY=1; it binds only the KANNAKA.ask.* subjects.

Env:
    NATS_URL                       (default nats://swarm.ninja-portal.com:4222)
    NATS_USER, NATS_PASSWORD       (credentials for authenticated subjects; see
                                   above — falls back to ~/.kannaka-nats.env)
    NATS_CREDS                     (path to an nkey/JWT credentials file; an
                                   alternative to NATS_USER/NATS_PASSWORD)
    KANNAKTOPUS_ANON_ONLY          (1/true — bind only KANNAKA.ask.*, no creds
                                   required; same as --anon-only)
    KANNAKTOPUS_CREDS_FILE         (override the ~/.kannaka-nats.env path)
    KANNAKTOPUS_SKILLS_DIR         (override the discovered skills/ directory)
    KANNAKTOPUS_ARM_ID             (default kannaktopus-01)
    KANNAKTOPUS_LOG_LEVEL          (default INFO)
    HTTP_PORT                      (optional; the port mcp-server actually
                                   binds — reported as `mcp_listen_port`)

Dependency: ``pip install nats-py>=2.7``.
"""
from __future__ import annotations

import argparse
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

NATS_URL = os.environ.get("NATS_URL") or os.environ.get(
    "KANNAKA_NATS_URL", "nats://swarm.ninja-portal.com:4222"
)
NATS_USER = os.environ.get("NATS_USER", "")
NATS_PASSWORD = os.environ.get("NATS_PASSWORD", "")
ARM_ID = os.environ.get("KANNAKTOPUS_ARM_ID", "kannaktopus-01")

# The file the constellation crons and systemd launchers already source
# (see scripts/systemd/*.service EnvironmentFile=). Reused here rather than
# inventing a second credentials convention for the listener.
DEFAULT_CREDS_FILE = "~/.kannaka-nats.env"

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


# ── Reply envelope ─────────────────────────────────────────────────────

def _envelope() -> dict[str, Any]:
    """Canonical NATS envelope shared by every reply this listener publishes.

    Identical contract to queensync_presence.py::_envelope() — the
    constellation contract (consciousness-core/docs/nats-contract.yaml,
    enforced by kannaka-radio's drift detector) requires schema_version, ts
    and agent_id on every message, with:

      * `schema_version` the spec version string "1.0" — not a bare "1"
      * `ts` unix-MILLISECONDS as an integer — not seconds, not ISO-8601

    `agent_id` is the load-bearing field for #60: a broadcast request's
    replies all land in the requester's single `_INBOX.<id>`, so the arm id
    in the payload is what makes each one individually observable. Replying
    into `msg.reply` keeps working under the existing anon grant (publish
    `KANNAKA.ask.>`, subscribe `_INBOX.>`); a per-arm reply subject would
    have needed a new bus ACL everywhere before any anon client could see a
    reply at all.
    """
    return {
        "schema_version": "1.0",
        "ts": int(time.time() * 1000),
        "agent_id": ARM_ID,
    }


# ── Credentials (fail closed — #28) ────────────────────────────────────

class CredentialsError(RuntimeError):
    """No credentials resolved for a subject set that requires them."""


def _parse_env_file(path: Path) -> dict[str, str]:
    """Parse a ``KEY=value`` env file the way ``set -a; . file`` would.

    Tolerates ``export `` prefixes, surrounding single/double quotes, blank
    lines, ``#`` comments and trailing whitespace. Values are never logged.
    """
    values: dict[str, str] = {}
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        log.debug("credentials file %s unreadable: %s", path, exc)
        return values
    for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def _resolve_credentials(
    env: dict[str, str] | None = None,
    creds_file: str | None = None,
) -> dict[str, str]:
    """Resolve NATS credentials from the environment, then the creds file.

    Returns a dict with a ``source`` key describing where the credentials
    came from (``"env"`` or the file path) and either ``user``/``password``
    or ``creds``. An empty dict means nothing resolved. The secret itself is
    never logged — only the source.
    """
    env = os.environ if env is None else env
    path_str = (
        creds_file
        or env.get("KANNAKTOPUS_CREDS_FILE", "").strip()
        or DEFAULT_CREDS_FILE
    )

    user = (env.get("NATS_USER") or "").strip()
    password = (env.get("NATS_PASSWORD") or "").strip()
    if user and password:
        return {"source": "env", "user": user, "password": password}
    creds = (env.get("NATS_CREDS") or "").strip()
    if creds:
        return {"source": "env", "creds": creds}

    path = Path(os.path.expanduser(path_str))
    if not path.is_file():
        return {}
    parsed = _parse_env_file(path)
    user = (parsed.get("NATS_USER") or "").strip()
    password = (parsed.get("NATS_PASSWORD") or "").strip()
    if user and password:
        return {"source": str(path), "user": user, "password": password}
    creds = (parsed.get("NATS_CREDS") or "").strip()
    if creds:
        return {"source": str(path), "creds": creds}
    return {}


def _creds_error_message(creds_file: str) -> str:
    return (
        "kannaktopus_listener: refusing to start — no NATS credentials resolved, "
        "but the subject set includes KANNAKTOPUS.command.* which the "
        "constellation bus restricts to authenticated users. Connecting anon "
        "here produces a daemon that looks healthy and is silently deaf on "
        "every command subject it was deployed to serve.\n"
        f"  Expected credentials file: {os.path.expanduser(creds_file)}\n"
        "  Supply credentials either way:\n"
        "    1. export NATS_USER=... NATS_PASSWORD=...   (or NATS_CREDS=/path/to.creds)\n"
        f"    2. write NATS_USER=/NATS_PASSWORD= lines into {creds_file}\n"
        "  Or, to run a legitimately anonymous listener bound to the "
        "anon-publishable KANNAKA.ask.* subjects only:\n"
        "    kannaktopus_listener.py --anon-only   (or KANNAKTOPUS_ANON_ONLY=1)\n"
    )


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


def _skills_dir() -> Path:
    """Directory holding the shipped skills: ``<repo>/skills/<name>/SKILL.md``.

    That is the set validate-release.sh already treats as canonical (it
    checks every folder has a SKILL.md whose frontmatter `name` matches) and
    what Claude Code 2.x auto-discovers. Deliberately *not* .claude/skills or
    .claude/commands — those are the OpenClaw generator's input, and that
    generated registry is being deleted (#59).
    """
    override = os.environ.get("KANNAKTOPUS_SKILLS_DIR", "").strip()
    if override:
        return Path(os.path.expanduser(override))
    return Path(__file__).resolve().parent.parent / "skills"


def _frontmatter_name(text: str) -> str | None:
    """Return the frontmatter ``name`` of a SKILL.md, or None if absent.

    ``\\r\\n`` is normalized to ``\\n`` *before* parsing. This is the same
    defect fixed in openclaw/src/skill-loader.ts (#73), now appearing a
    second time in Python: without normalization the `---` terminator carries
    a trailing `\\r`, the frontmatter block is never closed, and every value
    keeps a stray `\\r` — which is how #34 silently renamed
    `octopus-architecture` to `skill-architecture`.
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        key, sep, value = line.partition(":")
        if not sep or key.strip() != "name":
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        return value.strip() or None
    return None


# (signature, skills) — the signature is a cheap stat-only fingerprint of the
# skills tree, so the 62 file reads happen once and then only when something
# on disk actually changes. `capabilities` is fine to serve at control-panel
# frequency; it is not fine to re-read 62 files if anything polls it (#19).
_SKILLS_CACHE: tuple[tuple[tuple[str, int], ...], list[str]] | None = None


def _skills_signature(skill_files: list[Path]) -> tuple[tuple[str, int], ...]:
    sig: list[tuple[str, int]] = []
    for path in skill_files:
        try:
            sig.append((str(path), path.stat().st_mtime_ns))
        except OSError:
            sig.append((str(path), -1))
    return tuple(sig)


def discover_skills() -> list[str]:
    """Names of every shipped skill, from ``skills/*/SKILL.md`` frontmatter.

    Identifiers come from the frontmatter `name`, never the directory
    basename: frontmatter names survive directory renames, and if `run` (#32)
    is ever built these identifiers become an execution allowlist where
    stability is a security property. A skill whose frontmatter has no `name`
    is skipped and logged rather than falling back to the basename — that
    fallback is precisely what produced #34's wrong identifiers.
    """
    global _SKILLS_CACHE

    root = _skills_dir()
    try:
        skill_files = sorted(root.glob("*/SKILL.md"))
    except OSError as exc:
        log.warning("skills discovery failed for %s: %s", root, exc)
        return []
    if not skill_files:
        log.warning("no skills discovered under %s/*/SKILL.md", root)
        return []

    signature = _skills_signature(skill_files)
    if _SKILLS_CACHE is not None and _SKILLS_CACHE[0] == signature:
        return list(_SKILLS_CACHE[1])

    names: list[str] = []
    for path in skill_files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            log.warning("skipping skill %s: unreadable (%s)", path, exc)
            continue
        name = _frontmatter_name(text)
        if not name:
            log.warning(
                "skipping skill %s: frontmatter has no `name` "
                "(not falling back to the directory basename — see #34)",
                path,
            )
            continue
        names.append(name)

    names = sorted(set(names))
    _SKILLS_CACHE = (signature, names)
    log.info("discovered %d skills from %s", len(names), root)
    return list(names)


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
        "skills": discover_skills(),
    }


def cmd_run(args: dict[str, Any]) -> dict[str, Any]:
    """RESERVED by contract — a deliberate deferral, not an unfinished stub.

    `run` would spawn scripts/orchestrate.sh from this handler table, and
    that table is reachable from KANNAKA.ask.broadcast, which is
    anon-publishable per the bus's ADR-0026 ACL config. Shipping it as-is
    would convert an unauthenticated bus subject into remote code execution
    on every arm. Tracked as a design task with a security review attached
    (#32); minimum bar recorded there is: bind `run` to authenticated
    subjects only (never KANNAKA.ask.*), an allowlist of invocable commands
    rather than free-form argv, timeouts, and bounded output capture.
    """
    return {
        "implemented": False,
        "status": "deferred",
        "tracking_issue": (
            "https://github.com/NickFlach/Kannaktopus/issues/32"
        ),
        "note": (
            "run is deliberately deferred, not unimplemented-by-oversight: it "
            "is RESERVED in the published contract (docs/control-panel-api.md) "
            "and returns implemented:false by design. Executing skills from "
            "this handler table would expose remote code execution over the "
            "anon-publishable KANNAKA.ask.broadcast subject, so the bus ACLs, "
            "an invocable-command allowlist, timeouts and bounded output "
            "capture must be settled first. See "
            "https://github.com/NickFlach/Kannaktopus/issues/32."
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

def _connect_kwargs(creds: dict[str, str] | None = None) -> dict[str, Any]:
    kw: dict[str, Any] = {
        "name": f"{ARM_ID}-listener",
        "connect_timeout": 5,
        "max_reconnect_attempts": -1,
        "reconnect_time_wait": 2,
    }
    creds = creds or {}
    if creds.get("user") and creds.get("password"):
        kw["user"] = creds["user"]
        kw["password"] = creds["password"]
    elif creds.get("creds"):
        kw["user_credentials"] = creds["creds"]
    return kw


async def _connect_with_backoff(creds: dict[str, str] | None = None) -> "nats.NATS":
    creds = creds or {}
    delay = 1.0
    while True:
        try:
            nc = await nats.connect(NATS_URL, **_connect_kwargs(creds))
            if creds.get("user"):
                log.info(
                    "connected to NATS %s as %s (credentials from %s)",
                    NATS_URL, creds["user"], creds.get("source", "env"),
                )
            elif creds.get("creds"):
                log.info(
                    "connected to NATS %s with a credentials file (from %s)",
                    NATS_URL, creds.get("source", "env"),
                )
            else:
                # Only reachable in the explicit anon-only mode: the startup
                # gate refuses to get here when authed subjects are wanted.
                log.info(
                    "connected to NATS %s as anon (--anon-only): serving the "
                    "anon-publishable KANNAKA.ask.* subjects only",
                    NATS_URL,
                )
            return nc
        except Exception as exc:  # noqa: BLE001
            log.warning("NATS connect failed (%s); retrying in %.1fs", exc, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60.0)


async def _reply(nc: "nats.NATS", reply_subject: str, payload: dict[str, Any]) -> None:
    """Publish one reply, always wrapped in the canonical envelope (#60).

    Every reply goes through here — success, handler error, unknown command
    and malformed JSON alike — so there is no path on which a broadcast
    reply arrives without an `agent_id` to attribute it to.
    """
    if not reply_subject:
        return
    body = {**_envelope(), **payload}
    try:
        await nc.publish(reply_subject, json.dumps(body).encode("utf-8"))
    except NatsError as exc:
        log.warning("reply publish failed on %s: %s", reply_subject, exc)


async def _handle_message(nc: "nats.NATS", msg: "Msg") -> None:
    reply_subject = msg.reply
    try:
        body = json.loads(msg.data.decode("utf-8") or "{}")
    except json.JSONDecodeError as exc:
        log.warning("malformed JSON on %s: %s", msg.subject, exc)
        await _reply(nc, reply_subject, {"ok": False, "error": f"json_decode: {exc}"})
        return

    cmd = body.get("cmd", "")
    args = body.get("args", {}) or {}
    handler = HANDLERS.get(cmd)
    if handler is None:
        log.info("unknown command %r on %s", cmd, msg.subject)
        await _reply(
            nc,
            reply_subject,
            {
                "ok": False,
                "error": f"unknown_command: {cmd}",
                "supported": list(HANDLERS.keys()),
            },
        )
        return

    log.info("command=%s subject=%s reply=%s", cmd, msg.subject, reply_subject)
    try:
        result = handler(args)
        payload: dict[str, Any] = {"ok": True, "result": result}
    except Exception as exc:  # noqa: BLE001
        log.exception("handler %s raised", cmd)
        payload = {"ok": False, "error": f"handler_error: {exc}"}

    await _reply(nc, reply_subject, payload)


ANON_SUBJECTS = (ASK_SUBJECT, ASK_BROADCAST_SUBJECT)
AUTHED_SUBJECTS = (DIRECT_SUBJECT, BROADCAST_SUBJECT)
ALL_SUBJECTS = AUTHED_SUBJECTS + ANON_SUBJECTS


def wanted_subjects(anon_only: bool) -> tuple[str, ...]:
    """Subjects to bind. Anon-only mode drops the authenticated-only ones.

    KANNAKA.ask.> is legitimately anon-publishable (the documented path for
    the Replit control panel), so an operator may deliberately run an
    anon-only listener — it just binds only what it is actually allowed to
    serve, instead of claiming the KANNAKTOPUS.command.* subjects it will
    never receive.
    """
    return ANON_SUBJECTS if anon_only else ALL_SUBJECTS


def _env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


def preflight(argv: list[str] | None = None) -> tuple[bool, dict[str, str]]:
    """Resolve mode + credentials and fail closed *before* connecting (#28).

    Raises CredentialsError when the subject set includes the
    authenticated-only KANNAKTOPUS.command.* subjects and no credentials
    resolve. Doing this here, rather than letting an ACL rejection surface
    several layers down, makes a missing credentials file one clear message.
    """
    parser = argparse.ArgumentParser(
        prog="kannaktopus_listener.py",
        description="NATS command-channel listener for Kannaktopus.",
    )
    parser.add_argument(
        "--anon-only",
        action="store_true",
        default=_env_flag("KANNAKTOPUS_ANON_ONLY"),
        help=(
            "Run without credentials, binding only the anon-publishable "
            "KANNAKA.ask.* subjects (env: KANNAKTOPUS_ANON_ONLY=1)."
        ),
    )
    args = parser.parse_args(argv)

    creds = _resolve_credentials()
    if args.anon_only:
        if creds:
            log.info(
                "--anon-only: ignoring credentials from %s and binding the "
                "KANNAKA.ask.* subjects only", creds.get("source"),
            )
        return True, {}
    if not creds:
        raise CredentialsError(
            _creds_error_message(
                os.environ.get("KANNAKTOPUS_CREDS_FILE", "").strip()
                or DEFAULT_CREDS_FILE
            )
        )
    return False, creds


async def run(anon_only: bool = False, creds: dict[str, str] | None = None) -> int:
    wanted = wanted_subjects(anon_only)
    log.info(
        "starting command listener arm_id=%s anon_only=%s subjects=%s",
        ARM_ID, anon_only, ", ".join(wanted),
    )

    nc = await _connect_with_backoff(creds)

    async def _on_msg(msg: "Msg") -> None:
        await _handle_message(nc, msg)

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


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=os.environ.get("KANNAKTOPUS_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        anon_only, creds = preflight(argv)
    except CredentialsError as exc:
        # Deliberately stderr rather than a log record: this is a startup
        # refusal, and it must be legible in `systemctl status` / journal
        # even if the log level was turned down.
        sys.stderr.write(f"{exc}\n")
        return 3
    return asyncio.run(run(anon_only, creds))


if __name__ == "__main__":
    sys.exit(main())
