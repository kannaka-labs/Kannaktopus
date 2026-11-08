#!/usr/bin/env python3
"""named_arms.py: the runner for Kannaktopus's two named arms.

  kannaka-vigil      the Auditor. Tries to refute a document before it goes out
                     under a lab name. GLM via OpenRouter today; one env var
                     (OCTOPUS_VIGIL_BACKEND=ollama) moves it to the local
                     kannaka-brain-glm LoRA once that passes its gate.
  kannaka-ferryman   the Steward (alias kannaka-steward). Opportunity sweep,
                     settlements, drafts for review. Claude via the Anthropic API.

Each call is one HTTP request with no tools: neither arm can send, post, pay or
sign anything, because nothing it can reach does that. Every call, including a
refused or failed one, appends one row to an append-only JSONL ledger (0600)
in the rogue-agent answers.jsonl shape, so tools/fab_grader.py in rogue-agent
can grade the arms' own answers unchanged:

  fab_grader.py nightly --root ~/.kannaktopus/ledger

Standard library only (Python 3.9+). Keys come from the environment only
(OPENROUTER_API_KEY, ANTHROPIC_API_KEY); this file never reads a key file and
never prints a key.

Usage:
  named_arms.py call --arm ARM [--task T] [--input PATH|URL ...] [--collect]   (prompt on stdin)
  named_arms.py audit FILE [--source PATH|URL ...] [--fetch-links] [--kind K]  (Vigil)
  named_arms.py sweep [--since 24h] [--input ...]                             (Ferryman)
  named_arms.py due [--days 7]                                                (Ferryman, no model call)
  named_arms.py settle [--market N] --evidence PATH|URL ...                   (Ferryman, then Vigil)
  named_arms.py draft BRIEF [--input ...]                                     (Ferryman, then Vigil)
  named_arms.py budget|config|ledger-path --arm ARM
  Every command takes --meta-out FILE (one JSON line per model call: cost, verdict).

Exit codes: 0 ok (audit: 0 PUBLISH, 10 FIX, 11 DROP), 2 usage/config, 3 refused by a cap (no HTTP call made),
4 reply was not valid JSON for the task schema, 5 provider/HTTP error.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import ipaddress
import json
import math
import os
import re
import socket
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

ARMS = ("kannaka-vigil", "kannaka-ferryman")
ALIASES = {"kannaka-steward": "kannaka-ferryman", "vigil": "kannaka-vigil",
           "ferryman": "kannaka-ferryman", "steward": "kannaka-ferryman"}
SHORT = {"kannaka-vigil": "vigil", "kannaka-ferryman": "ferryman"}
TASKS = {"kannaka-vigil": ("audit",), "kannaka-ferryman": ("sweep", "settle", "draft")}

REPO = Path(__file__).resolve().parent.parent

# USD per million tokens (input, output). Only used for the pre-call worst case
# and when a provider does not report the cost itself.
PRICES = {
    "z-ai/glm-5.3": (0.60, 2.20),  # billed ~0.56/1.78 on 2026-11-08 (the /models listing said 0.07/1.40)
    "z-ai/glm-5": (0.80, 2.56),    # same as cost.sh get_model_pricing
    "z-ai/glm-4.7": (0.60, 2.20),
    "claude-opus-5-5": (4.00, 20.00),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-haiku-5-5": (0.10, 0.50),  # prompts up to 100K tokens; $0.50/$2.50 beyond that
    "claude-opus-4-8": (5.00, 25.00),
    "claude-sonnet-4-6": (3.00, 15.00),
}
UNKNOWN_PRICE = (10.00, 50.00)  # an unknown model is costed high, never free
# A server-side fallback ("fallbacks": "default") bills at the fallback model's rates,
# so the pre-call worst case for an Anthropic arm uses the dearest Claude model listed.
CLAUDE_FALLBACK_WORST = max((v for k, v in PRICES.items() if k.startswith("claude-")), key=lambda t: t[1])

DEFAULTS = {
    "kannaka-vigil": {
        "backend": "openrouter",
        "model": "z-ai/glm-5.3",
        "local_model": "kannaka-brain-glm-v1",
        "max_tokens": 4096,
        "temperature": 0,
        "max_input_chars": 120000,
        "max_usd_run": 0.10,
        "max_usd_week": 2.00,
        "timeout_s": 300,
        "timeout_s_local": 900,  # a whole-document audit on the CPU LoRA takes ~2.5-3.5 min
        "model_sha256": None,    # the served GGUF's sha256 (llama-server has no /api/tags)
        "reasoning": {"effort": "low", "exclude": True},
        # OpenRouter routing: refuse providers that train on prompts, and refuse any
        # route dearer than the price table (max_price is filled in per call).
        "openrouter_provider": {"data_collection": "deny"},
    },
    "kannaka-ferryman": {
        "backend": "anthropic",
        "model": "claude-opus-5-5",
        "max_tokens": 8192,
        "effort": "medium",
        "fallbacks": "default",
        "max_input_chars": 150000,
        "max_usd_run": 0.60,
        "max_usd_week": 10.00,
        "timeout_s": 300,
        "sources": [],
    },
}
BASE_URLS = {
    "openrouter": "https://openrouter.ai/api/v1",
    "anthropic": "https://api.anthropic.com/v1",
}
FETCH_CAP = 200_000
COLLECT_TIMEOUT_S = 60

SECRET_RX = re.compile(
    r"(-----BEGIN [A-Z0-9 ]*(?:PRIVATE KEY|NKEY SEED)-----[\s\S]*?-----END [A-Z0-9 ]*(?:PRIVATE KEY|NKEY SEED)-----"
    r"|sk-ant-[A-Za-z0-9_\-]{8,}|sk-or-v1-[A-Za-z0-9]{8,}|sk-proj-[A-Za-z0-9_\-]{8,}"
    r"|sk-[A-Za-z0-9_\-]{20,}|AQ\.[A-Za-z0-9_\-]{16,}|AIza[0-9A-Za-z_\-]{20,}"
    r"|pplx-[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}|hf_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}"
    r"|\bS[UAOCNPX][A-Z2-7]{50,}\b"                                   # NATS nkey seeds
    r"|\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"  # JWTs (NATS .creds, OAuth)
    r"|\b\d{8,10}:[A-Za-z0-9_\-]{35}\b"                             # Telegram bot tokens
    r"|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b)")                               # AWS access key ids
# `api_key = ...`, `"password": "..."`, `QBRAID_API_KEY=...`: mask the value, keep the name
SECRET_ASSIGN_RX = re.compile(
    r"(?i)(\b[A-Z0-9_\-]*(?:api[_\-]?key|secret|token|passw(?:or)?d|private[_\-]?key|credential)s?\b"
    r"[\"']?\s*[:=]\s*[\"']?)([^\s\"',;]{12,})")
SECRET_ENV = ("ANTHROPIC_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY",
              "GOOGLE_API_KEY", "PERPLEXITY_API_KEY", "HF_TOKEN", "GH_TOKEN", "GITHUB_TOKEN")
SECRET_ENV_NAME_RX = re.compile(r"KEY|TOKEN|SECRET|PASSW|CREDENTIAL|SEED", re.I)


class ArmError(Exception):
    def __init__(self, code: int, msg: str, sent: bool = False):
        super().__init__(msg)
        self.code = code
        self.sent = sent  # the request reached the provider, so it may have been billed


# ── small helpers ────────────────────────────────────────────────────────────

def sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _secret_env_values() -> list:
    names = set(SECRET_ENV) | {n for n in os.environ if SECRET_ENV_NAME_RX.search(n)}
    out = []
    for name in sorted(names):
        v = os.environ.get(name, "")
        if len(v) >= 12:
            out.append((name, v))
    return sorted(out, key=lambda t: -len(t[1]))  # longest first, so a value inside another is not split


def redact(text: str) -> str:
    """Mask anything shaped like a key, the value of any `*key/token/secret/password = ...`
    assignment, and the literal value of every environment variable whose name says it is a
    secret (KEY, TOKEN, SECRET, PASSWORD, CREDENTIAL, SEED)."""
    if not text:
        return text
    for name, v in _secret_env_values():
        if v in text:
            text = text.replace(v, f"[REDACTED:{name}]")
    text = SECRET_RX.sub(lambda m: "[REDACTED:" + m.group(0)[:4] + "]", text)
    return SECRET_ASSIGN_RX.sub(lambda m: m.group(1) + "[REDACTED]", text)


def canon_arm(name: str) -> str:
    arm = ALIASES.get(name, name)
    if arm not in ARMS:
        raise ArmError(2, f"unknown arm {name!r}; one of {', '.join(ARMS)} (alias kannaka-steward)")
    return arm


def env_key(arm: str, key: str) -> str:
    return f"OCTOPUS_{SHORT[arm].upper()}_{key.upper()}"


def kannaktopus_home() -> Path:
    return Path(os.environ.get("OCTOPUS_KANNAKTOPUS_HOME") or Path.home() / ".kannaktopus")


def load_config(arm: str) -> dict:
    cfg = json.loads(json.dumps(DEFAULTS[arm]))
    cdir = Path(os.environ.get("OCTOPUS_NAMED_ARMS_CONFIG_DIR") or kannaktopus_home() / "config" / "arms")
    f = cdir / f"{SHORT[arm]}.json"
    if f.is_file():
        try:
            user = json.loads(f.read_text(encoding="utf-8"))
        except ValueError as e:
            raise ArmError(2, f"{f}: not JSON ({e})")
        cfg.update({k: v for k, v in user.items() if not k.startswith("_")})
    # env overrides (strings parsed as numbers where the default is a number)
    for k in ("backend", "model", "max_tokens", "temperature", "max_input_chars",
              "max_usd_run", "max_usd_week", "timeout_s", "effort", "base_url", "model_sha256"):
        v = os.environ.get(env_key(arm, k))
        if v is None or v == "":
            continue
        if isinstance(DEFAULTS[arm].get(k), (int, float)) and not isinstance(DEFAULTS[arm].get(k), bool):
            try:
                v = float(v) if "." in v or k.startswith("max_usd") else int(v)
            except ValueError:
                raise ArmError(2, f"{env_key(arm, k)}={v!r} is not a number")
        cfg[k] = v
    if cfg["backend"] not in ("openrouter", "anthropic", "ollama"):
        raise ArmError(2, f"backend {cfg['backend']!r} is not one of openrouter, anthropic, ollama")
    # A NaN, infinite or negative cap would silently disable the cap: refuse it.
    positive = ("max_tokens", "timeout_s", "timeout_s_local")
    for k in ("max_usd_run", "max_usd_week", "max_input_chars") + positive:
        if cfg.get(k) is None:
            continue
        try:
            f = float(cfg[k])
        except (TypeError, ValueError):
            raise ArmError(2, f"{k}={cfg[k]!r} is not a number")
        if not math.isfinite(f) or f < 0 or (k in positive and f <= 0):
            raise ArmError(2, f"{k}={cfg[k]!r} must be a finite number " + ("above 0" if k in positive else ">= 0"))
    if cfg["backend"] == "ollama" and not os.environ.get(env_key(arm, "timeout_s")) and cfg.get("timeout_s_local"):
        cfg["timeout_s"] = cfg["timeout_s_local"]
    # Switching Vigil to the local LoRA is one env var: OCTOPUS_VIGIL_BACKEND=ollama.
    if cfg["backend"] == "ollama" and not os.environ.get(env_key(arm, "model")) and cfg.get("local_model"):
        cfg["model"] = cfg["local_model"]
    if not cfg.get("base_url"):
        if cfg["backend"] == "ollama":
            h = os.environ.get("OLLAMA_HOST") or "http://127.0.0.1:11434"
            cfg["base_url"] = (h if "://" in h else "http://" + h).rstrip("/") + "/v1"  # OpenAI-compatible root
        else:
            cfg["base_url"] = BASE_URLS[cfg["backend"]]
    return cfg


def ledger_root() -> Path:
    return Path(os.environ.get("OCTOPUS_ARMS_LEDGER_ROOT") or kannaktopus_home() / "ledger")


def ledger_path(arm: str) -> Path:
    return ledger_root() / "instances" / arm / "answers.jsonl"


def private_dir(d: Path) -> Path:
    """mkdir -p, then owner-only. POSIX: 0700. Windows ignores modes, so the first time
    the directory is made its ACL is cut to the current user (inherited by every file
    created in it later) with icacls."""
    existed = d.is_dir()
    d.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        user = os.environ.get("USERNAME")
        if not existed and user and not os.environ.get("OCTOPUS_NAMED_ARMS_NO_ICACLS"):
            try:
                subprocess.run(["icacls", str(d), "/inheritance:r", "/grant:r", f"{user}:(OI)(CI)F"],
                               capture_output=True, timeout=20)
            except (OSError, subprocess.SubprocessError):
                pass
    else:
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass
    return d


@contextlib.contextmanager
def arm_lock(arm: str, wait_s: float = 60.0):
    """Advisory lock (an atomic mkdir) around check-cap / reserve and around append, so
    parallel spawns cannot all read the ledger before any of them books its spend."""
    lock = private_dir(ledger_root() / ".locks") / f"{arm}.lock"
    deadline = time.time() + wait_s
    while True:
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            try:
                if time.time() - lock.stat().st_mtime > 120:  # a crashed holder; locks are held for ms
                    os.rmdir(lock)
                    continue
            except OSError:
                pass
            if time.time() > deadline:
                raise ArmError(3, f"budget: could not take the {arm} ledger lock in {wait_s:.0f} s (no call made)")
            time.sleep(0.05)
    try:
        yield
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass


def _reservations_path(arm: str) -> Path:
    return private_dir(ledger_root() / ".reservations") / f"{arm}.json"


def read_reservations(arm: str, now: float) -> dict:
    """{answer_id: {"t": sent, "usd": worst case, "expires": t}} for calls in flight. A call
    reserves its worst case before the request, so concurrent calls see each other's spend."""
    p = _reservations_path(arm)
    try:
        res = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in res.items() if isinstance(v, dict) and float(v.get("expires") or 0) > now}


def write_reservations(arm: str, res: dict) -> None:
    p = _reservations_path(arm)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(res), encoding="utf-8")
    os.replace(tmp, p)


def append_row(arm: str, row: dict) -> None:
    """One write() of one line, file created 0600 (same as rogue's _record_answer)."""
    p = ledger_path(arm)
    private_dir(p.parent)
    line = json.dumps(row, ensure_ascii=False, default=str) + "\n"
    fd = os.open(p, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


def iter_ledger(arm: str):
    p = ledger_path(arm)
    if not p.is_file():
        return
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue  # a torn line is skipped, as rogue's readers do


def spent_last_week(arm: str, now: float | None = None) -> float:
    now = now or time.time()
    total = 0.0
    for r in iter_ledger(arm):
        t = r.get("t_done") or r.get("t_sent") or 0
        if isinstance(t, (int, float)) and now - t <= 7 * 86400:
            total += float(r.get("cost_usd") or 0)
    return round(total, 6)


def price_of(model: str, backend: str) -> tuple[float, float]:
    if backend == "ollama":
        return (0.0, 0.0)
    return PRICES.get(model, UNKNOWN_PRICE)


def precheck_price(cfg: dict) -> tuple[float, float]:
    """The price used for the pre-call worst case: with Anthropic server-side fallbacks on,
    the dearest model the call could be rescued by."""
    pin, pout = price_of(cfg["model"], cfg["backend"])
    if cfg["backend"] == "anthropic" and cfg.get("fallbacks") == "default":
        pin, pout = max(pin, CLAUDE_FALLBACK_WORST[0]), max(pout, CLAUDE_FALLBACK_WORST[1])
    return pin, pout


def git_rev() -> str | None:
    try:
        return subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=5).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


# ── prompts ──────────────────────────────────────────────────────────────────

def load_prompt(arm: str) -> tuple[str, str]:
    """(system text, prompt_version) from agents/arms/<short>.md (YAML-ish frontmatter)."""
    f = Path(os.environ.get("OCTOPUS_NAMED_ARMS_PROMPT_DIR") or REPO / "agents" / "arms") / f"{SHORT[arm]}.md"
    text = f.read_text(encoding="utf-8")
    version = "unversioned"
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end > 0:
            for line in text[3:end].splitlines():
                if line.strip().startswith("prompt_version:"):
                    version = line.split(":", 1)[1].strip().strip("\"'")
            text = text[end + 4:]
    return text.strip() + "\n", version


# ── inputs ───────────────────────────────────────────────────────────────────

def check_public_url(url: str) -> None:
    """Refuse a URL whose host is not on the public internet (loopback, the 10.x lab range,
    link-local, Gatus on 127.0.0.1:8090 ...): fetched text goes to a model provider."""
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ArmError(2, f"refusing to fetch {url!r}: only http(s) URLs with a host")
    if os.environ.get("OCTOPUS_NAMED_ARMS_ALLOW_PRIVATE_FETCH") == "1":
        return
    try:
        infos = socket.getaddrinfo(u.hostname, u.port or (443 if u.scheme == "https" else 80),
                                   proto=socket.IPPROTO_TCP)
    except (socket.gaierror, UnicodeError) as e:
        raise ArmError(5, f"cannot resolve {u.hostname}: {e}")
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split("%", 1)[0])
        if getattr(ip, "ipv4_mapped", None):
            ip = ip.ipv4_mapped
        if not ip.is_global or ip.is_multicast:
            raise ArmError(2, f"refusing to fetch {url}: {u.hostname} resolves to non-public address {ip}")


class _PublicOnlyRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_url(url: str, cap: int) -> bytes:
    check_public_url(url)
    opener = urllib.request.build_opener(_PublicOnlyRedirects)
    req = urllib.request.Request(url, headers={"User-Agent": "kannaktopus-named-arms/1"})
    try:
        with opener.open(req, timeout=60) as r:
            return r.read(cap)
    except urllib.error.HTTPError as e:
        raise ArmError(5, f"fetch {url}: HTTP {e.code}")
    except (urllib.error.URLError, OSError) as e:
        raise ArmError(5, f"fetch {url}: {type(e).__name__}: {e}")


def read_input(spec: str) -> dict:
    if re.match(r"^https?://", spec):
        raw = fetch_url(spec, FETCH_CAP + 1)
        kind = "url"
    else:
        p = Path(spec)
        if not p.is_file():
            raise ArmError(2, f"input not found: {spec}")
        with open(p, "rb") as fh:
            raw = fh.read(FETCH_CAP + 1)
        kind = "file"
    truncated = len(raw) > FETCH_CAP
    text = raw[:FETCH_CAP].decode("utf-8", errors="replace")
    return {"source": spec, "kind": kind, "text": text, "truncated": truncated}


def collect_sources(cfg: dict) -> list[dict]:
    """Ferryman's read-only collectors: each config source is an argv list run
    without a shell; its stdout becomes one input. A failure becomes an input
    that says so, never a silent gap."""
    out = []
    for s in cfg.get("sources") or []:
        if not s.get("enabled", True):
            continue
        name, argv = s.get("name") or "source", s.get("argv")
        if not isinstance(argv, list) or not argv:
            out.append({"source": f"collector:{name}", "kind": "collector", "truncated": False,
                        "text": "[collector misconfigured: argv must be a non-empty list]"})
            continue
        argv = [os.path.expandvars(os.path.expanduser(a)) for a in argv]
        try:
            p = subprocess.run(argv, capture_output=True, timeout=int(s.get("timeout_s") or COLLECT_TIMEOUT_S),
                               stdin=subprocess.DEVNULL)
            text = p.stdout[:FETCH_CAP].decode("utf-8", errors="replace")
            if p.returncode != 0:
                text = f"[collector exited {p.returncode}; stderr: " + \
                       p.stderr[:500].decode("utf-8", errors="replace") + "]\n" + text
            trunc = len(p.stdout) > FETCH_CAP
        except (OSError, subprocess.SubprocessError) as e:
            text, trunc = f"[collector failed: {type(e).__name__}: {e}]", False
        out.append({"source": f"collector:{name}", "kind": "collector", "text": text, "truncated": trunc})
    return out


def compose_user(task: str, prompt: str, inputs: list[dict]) -> str:
    parts = [f"TASK: {task}", "", prompt.strip(), ""]
    if inputs:
        parts.append("INPUTS (cite as source#locator, using the source name exactly as given):")
        for i in inputs:
            note = " (truncated at 200 KB)" if i["truncated"] else ""
            parts.append(f"<<<SOURCE {i['source']} sha256={i['sha256'][:16]}{note}>>>")
            parts.append(i["text"])
            parts.append(f"<<<END {i['source']}>>>")
    else:
        parts.append("INPUTS: none were provided.")
    return "\n".join(parts) + "\n"


# ── output schema ────────────────────────────────────────────────────────────

def parse_json_reply(content: str):
    s = content.strip()
    m = re.match(r"^```(?:json)?\s*(.*?)\s*```$", s, re.S)
    if m:
        s = m.group(1)
    try:
        return json.loads(s)
    except ValueError:
        a, b = s.find("{"), s.rfind("}")
        if a >= 0 and b > a:
            try:
                return json.loads(s[a:b + 1])
            except ValueError:
                return None
    return None


def _base_name(s: str) -> str:
    return re.split(r"[\\/]", s.rstrip("/\\"))[-1]


def _source_map(sources) -> dict:
    """Citation name -> input name: the exact name, or its file name when that is unique.
    `sources` is a dict {input name: text} or any iterable of input names."""
    names = list(sources)
    m = {s: s for s in names}
    base = {}
    for s in names:
        base.setdefault(_base_name(s), []).append(s)
    for b, full in base.items():
        if b and len(full) == 1 and b not in m:
            m[b] = full[0]
    return m


def _resolve(src, sources):
    if not isinstance(src, str):
        return None
    return _source_map(sources).get(src.split("#", 1)[0].strip())


_QUOTE_TRANS = str.maketrans({"‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'",
                              "“": '"', "”": '"', "„": '"', "‟": '"', "″": '"',
                              "–": "-", "—": "-", "−": "-", " ": " ", "*": "", "`": ""})


def norm_quote(s: str) -> str:
    """Whitespace collapsed, quote marks / dashes / NBSP normalised, markdown * and ` dropped, casefolded."""
    s = unicodedata.normalize("NFKC", s or "").translate(_QUOTE_TRANS)
    return re.sub(r"\s+", " ", s).strip().casefold()


def quote_in(quote, text: str) -> bool:
    """True when every piece of `quote` (split at an ellipsis) occurs in `text`, in order."""
    if not isinstance(quote, str):
        return False
    q = norm_quote(quote).strip(" \"'")
    if len(q) < 3:
        return False
    hay = norm_quote(text)
    pos = 0
    for part in re.split(r"\s*(?:\.\.\.|…)\s*", q):
        part = part.strip(" \"'")
        if not part:
            continue
        i = hay.find(part, pos)
        if i < 0:
            return False
        pos = i + len(part)
    return pos > 0


def check_evidence(evidence, sources: dict, exclude: str | None = None) -> dict:
    """Check each evidence item: its source must name a provided input, and its quote must
    occur in that input. `exclude` (the audited document) is never evidence.
    -> {"items": [{source, input, ok, why}], "valid": n verified non-excluded items,
        "self_only": every cited item names the excluded document}"""
    items = []
    if not isinstance(evidence, list):
        evidence = []
    for e in evidence:
        src = e.get("source") if isinstance(e, dict) else e
        quote = e.get("quote") if isinstance(e, dict) else None
        inp = _resolve(src, sources)
        if inp is None:
            items.append({"source": src, "input": None, "ok": False, "why": "not a provided input"})
        elif exclude is not None and inp == exclude:
            items.append({"source": src, "input": inp, "ok": False, "why": "the audited document itself"})
        elif not quote_in(quote, sources[inp]):
            items.append({"source": src, "input": inp, "ok": False, "why": "quote not found in the input"})
        else:
            items.append({"source": src, "input": inp, "ok": True, "why": None})
    return {"items": items, "valid": sum(1 for i in items if i["ok"]),
            "self_only": bool(items) and all(i["why"] == "the audited document itself" for i in items)}


def check_schema(task: str, obj, sources, exclude: str | None = None) -> tuple:
    """(errors, overall verdict, quote_check). `sources` is {input name: text as the model saw it}.

    The runner enforces, rather than trusts:
      - cite-or-UNVERIFIABLE: a SUPPORTED/REFUTED claim, a sweep item and a YES/NO settlement
        must cite a provided input by name;
      - the audited document (`exclude`) is never evidence for its own claims: a claim whose
        only citations are that document fails the schema;
      - every quote must occur in the input it cites (whitespace, quote marks and case
        normalised; an ellipsis may join pieces). An audit claim with no verified quote is
        downgraded to UNVERIFIABLE (and PUBLISH to FIX); a sweep item or settlement with an
        unverified quote fails the schema.
    quote_check is recorded in the ledger row so the grader can count fabricated quotes."""
    errs: list = []
    qc: list = []
    if not isinstance(sources, dict):
        sources = {s: "" for s in sources}
    if not isinstance(obj, dict):
        return ["reply is not a JSON object"], None, None
    if task == "audit":
        overall = obj.get("overall")
        if overall not in ("PUBLISH", "FIX", "DROP"):
            errs.append("overall must be PUBLISH, FIX or DROP")
        claims = obj.get("claims")
        if not isinstance(claims, list):
            errs.append("claims must be a list")
            claims = []
        downgraded = 0
        for n, c in enumerate(claims):
            if not isinstance(c, dict):
                errs.append(f"claims[{n}] is not an object")
                continue
            v = c.get("verdict")
            if v not in ("SUPPORTED", "REFUTED", "UNVERIFIABLE"):
                errs.append(f"claims[{n}].verdict must be SUPPORTED, REFUTED or UNVERIFIABLE")
                continue
            if v == "UNVERIFIABLE":
                qc.append({"claim": c.get("id", n), "verdict": v, "result": "n/a"})
                continue
            ev = c.get("evidence")
            chk = check_evidence(ev, sources, exclude)
            if not isinstance(ev, list) or not ev or not any(i["input"] for i in chk["items"]):
                errs.append(f"claims[{n}] is {v} without citing a provided input")
                result = "uncited"
            elif chk["self_only"]:
                errs.append(f"claims[{n}] is {v} citing only the audited document, which is never evidence")
                result = "self-cited"
            elif chk["valid"] == 0:
                # every quote failed: the claim is not shown by any input
                c["verdict"] = "UNVERIFIABLE"
                c["runner_note"] = (f"downgraded from {v} by the runner: no cited quote occurs in its input")
                downgraded += 1
                result = "downgraded"
            else:
                result = "ok" if chk["valid"] == len(chk["items"]) else "partial"
            qc.append({"claim": c.get("id", n), "verdict": v, "result": result, "evidence": chk["items"]})
        if downgraded and overall == "PUBLISH":
            obj["overall"] = overall = "FIX"
            obj["runner_note"] = f"PUBLISH changed to FIX: {downgraded} claim(s) downgraded for unverified quotes"
        if not isinstance(obj.get("fixes", []), list):
            errs.append("fixes must be a list")
        if overall == "PUBLISH" and any(isinstance(c, dict) and c.get("verdict") == "REFUTED" for c in claims):
            errs.append("overall PUBLISH with a REFUTED claim")
        return errs, overall if overall in ("PUBLISH", "FIX", "DROP") else None, qc
    if task == "sweep":
        items = obj.get("items")
        if not isinstance(items, list):
            return ["items must be a list"], None, None
        for n, it in enumerate(items):
            if not isinstance(it, dict) or not it.get("id"):
                errs.append(f"items[{n}] needs an id")
                continue
            if it.get("class") not in ("real", "plausible", "liminal", "scam-risk"):
                errs.append(f"items[{n}].class must be real, plausible, liminal or scam-risk")
            chk = check_evidence(it.get("evidence"), sources)
            if not any(i["input"] for i in chk["items"]):
                errs.append(f"items[{n}] cites no provided input")
            elif chk["valid"] < len(chk["items"]):
                errs.append(f"items[{n}] has a quote that is not in the input it cites")
            qc.append({"item": it.get("id"), "result": "ok" if chk["items"] and chk["valid"] == len(chk["items"])
                       else "fail", "evidence": chk["items"]})
        return errs, f"{len(items)} items", qc
    if task == "settle":
        out = obj.get("proposed_outcome")
        if out not in ("YES", "NO", "INCONCLUSIVE"):
            errs.append("proposed_outcome must be YES, NO or INCONCLUSIVE")
        if out in ("YES", "NO"):
            chk = check_evidence(obj.get("evidence"), sources)
            if not any(i["input"] for i in chk["items"]):
                errs.append(f"proposed_outcome {out} without citing a provided input")
            elif chk["valid"] < len(chk["items"]):
                errs.append(f"proposed_outcome {out} has a quote that is not in the input it cites")
            qc.append({"outcome": out, "result": "ok" if chk["items"] and chk["valid"] == len(chk["items"])
                       else "fail", "evidence": chk["items"]})
        if "market" not in obj:
            errs.append("market is missing")
        return errs, out, qc
    if task == "draft":
        if not isinstance(obj.get("draft"), str) or not obj["draft"].strip():
            errs.append("draft must be a non-empty string")
        for k in ("assumptions", "claims_to_verify"):
            if not isinstance(obj.get(k, []), list):
                errs.append(f"{k} must be a list")
        return errs, ("draft" if not errs else None), None
    return [f"unknown task {task}"], None, None


# ── providers ────────────────────────────────────────────────────────────────

def http_json(url: str, body: dict, headers: dict, timeout: int) -> dict:
    """POST JSON. An ArmError carries sent=True when the request may have been billed
    (it reached the server: 5xx, timeout or a dropped connection after sending)."""
    fake = os.environ.get("OCTOPUS_NAMED_ARMS_FAKE_RESPONSE")
    if fake:  # tests: no network. A file is the reply; a directory holds messages.json + completions.json
        log = os.environ.get("OCTOPUS_NAMED_ARMS_FAKE_REQUEST_LOG")
        if log:
            with open(log, "a", encoding="utf-8") as f:
                f.write(json.dumps({"url": url, "headers": sorted(headers), "body": body}) + "\n")
        fp = Path(fake)
        if fp.is_dir():
            fp = fp / (url.rstrip("/").rsplit("/", 1)[-1] + ".json")
        if fp.name.startswith("http5xx"):  # tests: a billed-then-failed request
            raise ArmError(5, f"HTTP 502 from {url.split('?')[0]}: fake", sent=True)
        return json.loads(fp.read_text(encoding="utf-8"))
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                 headers={"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read()[:600].decode("utf-8", errors="replace")
        raise ArmError(5, f"HTTP {e.code} from {url.split('?')[0]}: {redact(detail)}", sent=e.code >= 500)
    except urllib.error.URLError as e:
        # DNS failure / refused connection: nothing reached the provider
        sent = isinstance(e.reason, (TimeoutError, socket.timeout, ConnectionResetError))
        raise ArmError(5, f"request to {url.split('?')[0]} failed: URLError: {e.reason}", sent=sent)
    except (TimeoutError, socket.timeout, ConnectionResetError, ConnectionAbortedError, ValueError) as e:
        raise ArmError(5, f"request to {url.split('?')[0]} failed: {type(e).__name__}: {e}", sent=True)
    except OSError as e:
        raise ArmError(5, f"request to {url.split('?')[0]} failed: {type(e).__name__}: {e}", sent=True)


def ollama_digest(cfg: dict) -> str | None:
    if os.environ.get("OCTOPUS_NAMED_ARMS_FAKE_RESPONSE"):
        return None
    try:
        root = re.sub(r"/v1/?$", "", cfg["base_url"].rstrip("/"))
        with urllib.request.urlopen(root + "/api/tags", timeout=10) as r:
            for m in json.load(r).get("models", []):
                if m.get("name") in (cfg["model"], cfg["model"] + ":latest"):
                    return m.get("digest")
    except (urllib.error.URLError, OSError, ValueError):
        pass
    return None  # llama-server has no /api/tags: set model_sha256 in vigil.json instead


def call_provider(cfg: dict, system: str, user: str) -> dict:
    """-> {content, response_id, gateway_model, upstream_provider, usage, cost_usd, stop}"""
    b, model = cfg["backend"], cfg["model"]
    if b == "anthropic":
        key = os.environ.get("ANTHROPIC_API_KEY", "")
        if not key:
            raise ArmError(2, "ANTHROPIC_API_KEY is not set")
        body = {"model": model, "max_tokens": int(cfg["max_tokens"]), "system": system,
                "messages": [{"role": "user", "content": user}]}
        if cfg.get("effort"):
            body["output_config"] = {"effort": cfg["effort"]}
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
        if cfg.get("fallbacks") == "default":
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        d = http_json(cfg["base_url"].rstrip("/") + "/messages", body, headers, int(cfg["timeout_s"]))
        content = "".join(blk.get("text", "") for blk in d.get("content") or [] if blk.get("type") == "text")
        u = d.get("usage") or {}
        served = d.get("model") or model
        pin, pout = price_of(served, b)
        # cache reads are costed at 0.1x input: an overestimate for Opus 5.5 (0.05x), never an under-count
        tin = (u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0) * 1.25 \
            + (u.get("cache_read_input_tokens") or 0) * 0.1
        cost = (tin * pin + (u.get("output_tokens") or 0) * pout) / 1e6
        return {"content": content, "response_id": d.get("id"), "gateway_model": served,
                "upstream_provider": "anthropic", "usage": u, "cost_usd": round(cost, 6),
                "stop": d.get("stop_reason")}
    # openrouter and ollama/llama-server both speak OpenAI chat completions
    body = {"model": model, "max_tokens": int(cfg["max_tokens"]),
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    if cfg.get("temperature") is not None:
        body["temperature"] = cfg["temperature"]
    headers = {}
    if b == "openrouter":
        key = os.environ.get("OPENROUTER_API_KEY", "")
        if not key:
            raise ArmError(2, "OPENROUTER_API_KEY is not set")
        headers = {"Authorization": "Bearer " + key, "X-Title": "Kannaktopus named arms"}
        body["usage"] = {"include": True}
        if cfg.get("reasoning"):
            body["reasoning"] = cfg["reasoning"]
        # Provider routing: no provider that keeps/trains on prompts, and OpenRouter itself
        # refuses a route dearer than our price table (USD per million tokens), so the
        # pre-call worst case stays a ceiling even when routes and prices drift.
        prov = dict(cfg.get("openrouter_provider") or {})
        pin, pout = price_of(model, b)
        prov.setdefault("max_price", {"prompt": pin, "completion": pout})
        body["provider"] = prov
    d = http_json(cfg["base_url"].rstrip("/") + "/chat/completions", body, headers, int(cfg["timeout_s"]))
    if d.get("error"):
        raise ArmError(5, "provider error: " + redact(json.dumps(d["error"])[:600]), sent=True)
    ch = (d.get("choices") or [{}])[0]
    content = (ch.get("message") or {}).get("content") or ""
    u = d.get("usage") or {}
    if b == "ollama":
        cost = 0.0
    elif isinstance(u.get("cost"), (int, float)):
        cost = float(u["cost"])
    else:
        pin, pout = price_of(model, b)
        cost = ((u.get("prompt_tokens") or 0) * pin + (u.get("completion_tokens") or 0) * pout) / 1e6
    return {"content": content, "response_id": d.get("id"), "gateway_model": d.get("model"),
            "upstream_provider": d.get("provider") or ("local" if b == "ollama" else None),
            "usage": u, "cost_usd": round(cost, 6), "stop": ch.get("finish_reason")}


# ── one call ─────────────────────────────────────────────────────────────────

def run_call(arm: str, task: str, prompt: str, input_specs=(), extra_inputs=(), meta_out=None,
             result_out=None, echo=True, exclude_spec: str | None = None) -> tuple:
    """One model call and one ledger row (also for a refused call, a fetch failure and a
    provider error). `exclude_spec` names the input under audit: it is never evidence.
    Returns (exit code, row)."""
    cfg = load_config(arm)
    if task not in TASKS[arm]:
        raise ArmError(2, f"{arm} has no task {task!r}; one of {', '.join(TASKS[arm])}")
    system, pversion = load_prompt(arm)
    prompt = redact(prompt)

    inputs, input_error = [], None
    for s in input_specs:
        try:
            inputs.append(read_input(s))
        except ArmError as e:  # logged below like any other failed call, never a silent exit
            input_error = e
            break
    inputs += list(extra_inputs)
    seen = set()
    for i in inputs:  # names must be unique so a citation points at one input
        base, n = i["source"], 2
        while i["source"] in seen:
            i["source"] = f"{base}~{n}"
            n += 1
        seen.add(i["source"])
        i["text"] = redact(i["text"])
        i["sha256"] = sha256(i["text"])
        i["bytes"] = len(i["text"].encode("utf-8"))
    exclude = None
    if exclude_spec is not None:
        exclude = next((i["source"] for i in inputs if i["source"] == exclude_spec), None)
    user = compose_user(task, prompt, inputs)

    model = cfg["model"]
    answer_id = uuid.uuid4().hex
    t_sent = time.time()
    pin, pout = precheck_price(cfg)
    chars = len(system) + len(user)
    worst = round(((chars / 3.0) * pin + int(cfg["max_tokens"]) * pout) / 1e6, 6)
    budget = {"spent_week_usd": None, "reserved_usd": None, "cap_week_usd": float(cfg["max_usd_week"]),
              "cap_run_usd": float(cfg["max_usd_run"]), "worst_case_usd": worst,
              "precheck_price_per_mtok": [pin, pout]}

    digest = ollama_digest(cfg) if cfg["backend"] == "ollama" else None
    row = {
        "answer_id": answer_id, "identity": arm, "t_sent": round(t_sent, 3), "t_done": None,
        "model": model, "model_digest": digest, "gateway_model": None, "response_id": None,
        "temperature": cfg.get("temperature") if cfg["backend"] != "anthropic" else None,
        "max_tokens": int(cfg["max_tokens"]), "system": system, "user": user,
        # the inputs are in `user` verbatim; recall carries their names and hashes
        "recall": [{k: i[k] for k in ("source", "kind", "sha256", "bytes", "truncated")} for i in inputs],
        "collective": None, "graph": None,
        "content": None, "content_sha256": None, "usage": None, "error": None,
        # extras (the grader ignores unknown keys)
        "arm": arm, "task": task, "backend": cfg["backend"], "prompt_version": pversion,
        "model_sha256": cfg.get("model_sha256"), "upstream_provider": None,
        "system_sha256": sha256(system), "inputs_sha256": sha256("".join(i["sha256"] for i in inputs)),
        "audited_input": exclude,
        "verdict": None, "verdict_json": None, "json_valid": None, "schema_errors": None, "quote_check": None,
        "cost_usd": 0.0, "cost_estimated": False, "budget": budget, "kannaktopus_rev": git_rev(),
    }
    reserved = {"id": None}

    def finish(code: int, **kv) -> tuple:
        row.update(kv)
        row["t_done"] = round(time.time(), 3)
        with arm_lock(arm):
            append_row(arm, row)
            if reserved["id"]:
                res = read_reservations(arm, time.time())
                res.pop(reserved["id"], None)
                write_reservations(arm, res)
        if meta_out:
            meta = {k: row[k] for k in ("answer_id", "arm", "task", "model", "gateway_model", "verdict",
                                        "json_valid", "schema_errors", "cost_usd", "error", "budget")}
            meta.update(exit=code, ledger=str(ledger_path(arm)),
                        elapsed_ms=int((row["t_done"] - row["t_sent"]) * 1000))
            with open(meta_out, "a", encoding="utf-8") as f:
                f.write(json.dumps(meta, ensure_ascii=False) + "\n")
        if result_out and row.get("verdict_json") is not None:
            rp = Path(result_out)
            rp.parent.mkdir(parents=True, exist_ok=True)
            rp.write_text(json.dumps({"answer_id": answer_id, "arm": arm, "task": task, "model": model,
                                      "result": row["verdict_json"], "schema_errors": row["schema_errors"],
                                      "quote_check": row["quote_check"]},
                                     ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return code, row

    if input_error is not None:
        return finish(input_error.code, error=redact(str(input_error)) + " (no call made)")
    if chars > int(cfg["max_input_chars"]) + 20000:
        return finish(3, error=f"budget: input is {chars} chars, cap {cfg['max_input_chars']} (no call made)")
    if worst > float(cfg["max_usd_run"]):
        return finish(3, error=f"budget: worst case ${worst:.4f} exceeds the per-run cap "
                               f"${float(cfg['max_usd_run']):.4f} (no call made)")
    # check the weekly cap and reserve this call's worst case in one locked step, so
    # parallel spawns see each other's in-flight spend
    with arm_lock(arm):
        now = time.time()
        spent = spent_last_week(arm, now)
        res = read_reservations(arm, now)
        held = round(sum(float(v.get("usd") or 0) for v in res.values()), 6)
        budget.update(spent_week_usd=spent, reserved_usd=held)
        if spent + held + worst > float(cfg["max_usd_week"]):
            refused = True
        else:
            refused = False
            if worst > 0:
                res[answer_id] = {"t": now, "usd": worst, "expires": now + float(cfg["timeout_s"]) + 300}
                write_reservations(arm, res)
                reserved["id"] = answer_id
    if refused:
        return finish(3, error=f"budget: ${spent:.4f} spent in 7 days + ${held:.4f} in flight + worst case "
                               f"${worst:.4f} exceeds the weekly cap ${float(cfg['max_usd_week']):.4f} (no call made)")

    try:
        r = call_provider(cfg, system, user)
    except ArmError as e:
        if e.sent and worst > 0:
            # the request reached the provider and may be billed: book the worst case
            return finish(e.code, error=redact(str(e)), cost_usd=worst, cost_estimated=True)
        return finish(e.code, error=redact(str(e)))
    content = redact(r["content"])
    obj = parse_json_reply(content) if content else None
    qc = None
    if obj is not None:
        errs, verdict, qc = check_schema(task, obj, {i["source"]: i["text"] for i in inputs}, exclude)
    else:
        errs, verdict = (["reply is not JSON"] if content else ["empty reply"]), None
    if r["cost_usd"] > worst > 0:
        print(f"named_arms: warning: {arm} cost ${r['cost_usd']:.6f} exceeded the pre-call worst case "
              f"${worst:.6f}; the price table for {model} is low", file=sys.stderr)
    if echo and content:
        sys.stdout.write(content + ("" if content.endswith("\n") else "\n"))
    return finish(0 if not errs else 4,
                  gateway_model=r["gateway_model"], response_id=r["response_id"],
                  upstream_provider=r.get("upstream_provider"),
                  content=content or None, content_sha256=sha256(content) if content else None,
                  usage=r["usage"], cost_usd=r["cost_usd"], cost_over_estimate=r["cost_usd"] > worst > 0,
                  json_valid=obj is not None, schema_errors=errs or None, quote_check=qc,
                  verdict=verdict, verdict_json=obj,
                  error=None if content else f"empty reply (stop={r['stop']})")


# ── workflows ────────────────────────────────────────────────────────────────

def results_dir() -> Path:
    return Path(os.environ.get("OCTOPUS_NAMED_ARMS_RESULTS_DIR") or kannaktopus_home() / "results")


def ferry_dir() -> Path:
    d = Path(os.environ.get("OCTOPUS_FERRYMAN_DIR") or kannaktopus_home() / "ferryman")
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def append_jsonl(path: Path, obj: dict) -> None:
    fd = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        os.write(fd, (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def read_jsonl(path: Path) -> list:
    if not path.is_file():
        return []
    out = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


VIGIL_EXIT = {"PUBLISH": 0, "FIX": 10, "DROP": 11}
LINK_RX = re.compile(r"https?://[^\s)>\]\"'`]+")


def audit_prompt(doc: str, kind=None) -> str:
    """The task line of every audit. The Vigil LoRA's whole-document training rows are built
    with this function and compose_user, so training and production send the same text."""
    return (f"Audit the document in input `{doc}`" + (f" (kind: {kind})" if kind else "") +
            ". Every other input is a possible source of evidence. The document is never evidence "
            "for its own claims.")


def audit(doc: str, sources=(), fetch_links=False, kind=None, meta_out=None, echo_summary=True):
    """Vigil on one document. Exit 0 PUBLISH, 10 FIX, 11 DROP, else the call's code."""
    if not Path(doc).is_file():
        raise ArmError(2, f"no such file: {doc}")
    # the document is an input (so claims can be located) but never evidence: a --source
    # naming the same file is dropped, and run_call refuses citations of it
    same = lambda x: not re.match(r"^https?://", x) and Path(x).resolve() == Path(doc).resolve()  # noqa: E731
    specs = [doc] + [s for s in sources if not same(s)]
    if fetch_links:
        text = Path(doc).read_text(encoding="utf-8", errors="replace")
        for u in list(dict.fromkeys(LINK_RX.findall(text)))[:10]:
            u = u.rstrip(".,;")
            try:
                check_public_url(u)
            except ArmError as e:  # a link to the lab's own hosts is skipped, not fetched
                print(f"named_arms: skipping link: {redact(str(e))}", file=sys.stderr)
                continue
            if u not in specs:
                specs.append(u)
    prompt = audit_prompt(doc, kind)
    rid = uuid.uuid4().hex[:12]
    out = results_dir() / f"kannaka-vigil-{rid}.json"
    code, row = run_call("kannaka-vigil", "audit", prompt, specs, meta_out=meta_out, result_out=str(out), echo=False,
                         exclude_spec=doc)
    if code == 0:
        code = VIGIL_EXIT.get(row["verdict"], 4)
    if echo_summary:
        counts = {}
        for c in (row.get("verdict_json") or {}).get("claims") or []:
            if isinstance(c, dict):
                counts[c.get("verdict")] = counts.get(c.get("verdict"), 0) + 1
        print(json.dumps({"overall": row.get("verdict"), "claims": counts, "exit": code,
                          "fixes": (row.get("verdict_json") or {}).get("fixes"),
                          "schema_errors": row.get("schema_errors"), "error": row.get("error"),
                          "quotes_unverified": sum(1 for q in row.get("quote_check") or []
                                                   if q.get("result") in ("downgraded", "partial")),
                          "cost_usd": row.get("cost_usd"), "answer_id": row["answer_id"],
                          "result": str(out) if out.is_file() else None}, ensure_ascii=False))
    return code, row


def cmd_audit(a) -> int:
    return audit(a.file, a.source or [], a.fetch_links, a.kind, a.meta_out)[0]


def cmd_sweep(a) -> int:
    cfg = load_config("kannaka-ferryman")
    extra = collect_sources(cfg)
    if not extra and not a.input:
        raise ArmError(2, "no inputs: configure sources[] in ~/.kannaktopus/config/arms/ferryman.json "
                          "or pass --input")
    prompt = (f"Sweep these inputs for leads, requests, deadlines and owed replies since {a.since}. "
              f"Today is {dt.date.today().isoformat()}.")
    rid = uuid.uuid4().hex[:12]
    out = results_dir() / f"kannaka-ferryman-sweep-{rid}.json"
    code, row = run_call("kannaka-ferryman", "sweep", prompt, a.input or [], extra, a.meta_out, str(out), echo=False)
    items = [it for it in (row.get("verdict_json") or {}).get("items") or [] if isinstance(it, dict)]
    reg = ferry_dir() / "register.jsonl"
    known = {r.get("id") for r in read_jsonl(reg)}
    new = 0
    if code == 0:
        for it in items:
            if it.get("id") and it["id"] not in known:
                append_jsonl(reg, {**it, "first_seen": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                                   "answer_id": row["answer_id"]})
                known.add(it["id"])
                new += 1
    digest = results_dir() / f"kannaka-ferryman-sweep-{rid}.md"
    if items:
        lines = [f"# Ferryman sweep {dt.date.today().isoformat()} (since {a.since})", "",
                 f"{len(items)} items, {new} new. Ledger answer {row['answer_id']}. Cost ${row['cost_usd']:.4f}.", "",
                 "| class | who | what | deadline | owed since | next step |", "|---|---|---|---|---|---|"]
        for it in items:
            cells = [str(it.get(k) or "").replace("|", "/").replace("\n", " ")
                     for k in ("class", "who", "what", "deadline", "owed_reply_since", "next_step")]
            lines.append("| " + " | ".join(cells) + " |")
        digest.parent.mkdir(parents=True, exist_ok=True)
        digest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"items": len(items), "new": new, "exit": code, "error": row.get("error"),
                      "schema_errors": row.get("schema_errors"), "cost_usd": row.get("cost_usd"),
                      "register": str(reg), "digest": str(digest) if digest.is_file() else None}))
    return code


def cmd_due(a) -> int:
    today = dt.date.today()
    horizon = today + dt.timedelta(days=a.days)
    rows = []
    for r in read_jsonl(ferry_dir() / "register.jsonl"):
        if r.get("closed"):
            continue
        d = r.get("deadline")
        try:
            dd = dt.date.fromisoformat(str(d)[:10]) if d else None
        except ValueError:
            dd = None
        if (dd and dd <= horizon) or r.get("owed_reply_since"):
            rows.append((dd or today, r))
    for dd, r in sorted(rows, key=lambda x: x[0]):
        tag = "OVERDUE" if dd < today else ("OWED" if r.get("owed_reply_since") and not r.get("deadline") else "DUE")
        print(f"{tag:8} {dd.isoformat()}  [{r.get('class')}] {r.get('who')}: {r.get('what')}  -> {r.get('next_step')}")
    if not rows:
        print(f"nothing due in the next {a.days} days and no owed replies")
    return 0


MARKETS_URL = "https://huggingface.co/datasets/Kannaka/calls-and-settlements/resolve/main/markets.jsonl"


def load_markets(src: str) -> list:
    if re.match(r"^https?://", src):
        text = fetch_url(src, FETCH_CAP).decode("utf-8", errors="replace")
    else:
        text = Path(src).read_text(encoding="utf-8")
    out = []
    for line in text.splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def cmd_settle(a) -> int:
    src = a.markets or os.environ.get("OCTOPUS_FERRYMAN_MARKETS") or MARKETS_URL
    markets = load_markets(src)
    today = dt.date.today().isoformat()
    if a.market is not None:
        pick = [m for m in markets if str(m.get("gs_proposal")) == str(a.market) or m.get("call_id") == str(a.market)]
    else:
        pick = [m for m in markets if m.get("outcome") is None and str(m.get("settles_by") or "9999") <= today]
    if not pick:
        print(json.dumps({"due": 0, "note": "no unsettled market is due" if a.market is None else "market not found"}))
        return 0
    if not a.evidence:
        for m in pick:
            print(json.dumps({"market": m.get("gs_proposal") or m.get("call_id"), "settles_by": m.get("settles_by"),
                              "resolution_source": m.get("resolution_source"),
                              "needs": "--evidence PATH|URL for the resolution source (no model call made)"}))
        return 2
    worst = 0
    pending = ferry_dir() / "settlements-pending.jsonl"
    for m in pick:
        mid = m.get("gs_proposal") or m.get("call_id")
        prompt = "Settle this market from the evidence inputs only.\n" + json.dumps(m, ensure_ascii=False, indent=2)
        rid = uuid.uuid4().hex[:12]
        out = results_dir() / f"kannaka-ferryman-settle-{mid}-{rid}.json"
        code, row = run_call("kannaka-ferryman", "settle", prompt, a.evidence, meta_out=a.meta_out,
                             result_out=str(out), echo=False)
        rec = {"market": mid, "statement": m.get("statement"), "settles_by": m.get("settles_by"),
               "proposal": row.get("verdict_json"), "exit": code, "answer_id": row["answer_id"],
               "proposed_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
               "evidence_inputs": row["recall"], "vigil": None, "approved_by_nick": False}
        if code == 0:
            # the proposal goes through Vigil before Nick sees it
            v = row["verdict_json"]
            prop = results_dir() / f"kannaka-ferryman-settle-{mid}-{rid}.proposal.md"
            ev = "".join(f"- {e.get('source')}: \"{e.get('quote')}\"\n"
                         for e in v.get("evidence") or [] if isinstance(e, dict))
            prop.write_text(f"# Proposed settlement for market {mid}\n\nStatement: {m.get('statement')}\n\n"
                            f"Proposed outcome: {v.get('proposed_outcome')} (confidence {v.get('confidence')})\n\n"
                            f"Reasoning: {v.get('reasoning')}\n\nEvidence:\n{ev}", encoding="utf-8")
            vcode, vrow = audit(str(prop), a.evidence, kind="settlement", meta_out=a.meta_out, echo_summary=False)
            rec["vigil"] = {"overall": vrow.get("verdict"), "exit": vcode, "answer_id": vrow["answer_id"]}
        append_jsonl(pending, rec)
        print(json.dumps({"market": mid, "proposed_outcome": (row.get("verdict_json") or {}).get("proposed_outcome"),
                          "vigil": rec["vigil"], "exit": code, "error": row.get("error"),
                          "cost_usd": row.get("cost_usd"), "pending": str(pending)}))
        worst = max(worst, code)
    return worst


def cmd_draft(a) -> int:
    if not Path(a.brief).is_file():
        raise ArmError(2, f"no such file: {a.brief}")
    prompt = "Write the draft described in the brief input `" + a.brief + "`. Use the other inputs as sources."
    code, row = run_call("kannaka-ferryman", "draft", prompt, [a.brief] + (a.input or []),
                         meta_out=a.meta_out, echo=False)
    if code != 0:
        print(json.dumps({"exit": code, "error": row.get("error"), "schema_errors": row.get("schema_errors"),
                          "cost_usd": row.get("cost_usd")}))
        return code
    v = row["verdict_json"]
    d = ferry_dir() / "drafts"
    d.mkdir(exist_ok=True)
    path = d / f"{row['answer_id'][:12]}.md"
    bullets = lambda xs: "".join(f"- {x}\n" for x in xs or [])  # noqa: E731
    path.write_text(f"<!-- DRAFT for Nick. Ferryman answer {row['answer_id']}. Not sent. -->\n\n{v['draft']}\n\n"
                    f"---\nAssumptions:\n{bullets(v.get('assumptions'))}\nNeeds Nick:\n{bullets(v.get('needs_nick'))}"
                    f"\nClaims to verify:\n{bullets(v.get('claims_to_verify'))}", encoding="utf-8")
    vcode, vrow = audit(str(path), [a.brief] + (a.input or []), kind="draft", meta_out=a.meta_out,
                        echo_summary=False)
    ready = vcode in (0, 10)
    print(json.dumps({"draft": str(path), "vigil": vrow.get("verdict"), "vigil_exit": vcode,
                      "ready_for_nick": ready,
                      "cost_usd": round((row.get("cost_usd") or 0) + (vrow.get("cost_usd") or 0), 6)}))
    return 0 if ready else vcode


def cmd_call(a) -> int:
    arm = canon_arm(a.arm)
    task = a.task or os.environ.get(f"OCTOPUS_{SHORT[arm].upper()}_TASK") or None
    if task is None and len(TASKS[arm]) > 1:
        # a generic spawn prompt would be paid for and then fail the sweep schema
        raise ArmError(2, f"{arm} needs --task ({' | '.join(TASKS[arm])}) or OCTOPUS_{SHORT[arm].upper()}_TASK; "
                          f"prefer `orchestrate.sh {SHORT[arm]} sweep|settle|draft` (no call made)")
    extra = collect_sources(load_config(arm)) if a.collect else []
    return run_call(arm, task or TASKS[arm][0], sys.stdin.read(), a.input or [], extra,
                    a.meta_out, a.result_out)[0]


def cmd_budget(a) -> int:
    arm = canon_arm(a.arm)
    cfg = load_config(arm)
    spent = spent_last_week(arm)
    held = round(sum(float(v.get("usd") or 0) for v in read_reservations(arm, time.time()).values()), 6)
    calls = sum(1 for _ in iter_ledger(arm))
    print(json.dumps({"arm": arm, "model": cfg["model"], "backend": cfg["backend"],
                      "spent_week_usd": spent, "in_flight_usd": held, "cap_week_usd": cfg["max_usd_week"],
                      "remaining_week_usd": round(float(cfg["max_usd_week"]) - spent - held, 6),
                      "cap_run_usd": cfg["max_usd_run"], "ledger_rows": calls,
                      "ledger": str(ledger_path(arm))}))
    return 0


def cmd_config(a) -> int:
    arm = canon_arm(a.arm)
    cfg = load_config(arm)
    # collectors run whatever argv ferryman.json holds (no shell). "Read-only" is a
    # convention of that file, which is Nick's: print every argv so a change is reviewable.
    cfg["sources"] = [{"name": s.get("name"), "enabled": s.get("enabled", True), "argv": s.get("argv")}
                      for s in cfg.get("sources") or []]
    print(redact(json.dumps({"arm": arm, **cfg}, indent=2)))
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="named_arms.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("call", help="one call; prompt on stdin, model reply on stdout")
    c.add_argument("--arm", required=True)
    c.add_argument("--task")
    c.add_argument("--input", action="append", help="PATH or http(s) URL; repeatable")
    c.add_argument("--collect", action="store_true", help="also run the arm's read-only collectors")
    c.add_argument("--result-out")
    c = sub.add_parser("audit", help="Vigil: audit a document (exit 0 PUBLISH, 10 FIX, 11 DROP)")
    c.add_argument("file")
    c.add_argument("--source", "-s", action="append", help="evidence PATH or URL; repeatable")
    c.add_argument("--fetch-links", action="store_true", help="also fetch up to 10 links found in the file")
    c.add_argument("--kind", choices=("market-call", "essay", "oration", "pr", "grant", "draft", "settlement", "other"))
    c = sub.add_parser("sweep", help="Ferryman: sweep the configured sources for leads")
    c.add_argument("--since", default="24h")
    c.add_argument("--input", action="append")
    c = sub.add_parser("due", help="Ferryman: deadlines and owed replies from the register (no model call)")
    c.add_argument("--days", type=int, default=7)
    c = sub.add_parser("settle", help="Ferryman: propose settlements for due markets, audited by Vigil")
    c.add_argument("--market")
    c.add_argument("--evidence", action="append")
    c.add_argument("--markets", help="markets.jsonl path or URL (default: the public HF dataset)")
    c = sub.add_parser("draft", help="Ferryman: draft from a brief, audited by Vigil")
    c.add_argument("brief")
    c.add_argument("--input", action="append")
    for name in ("budget", "ledger-path", "config"):
        s = sub.add_parser(name)
        s.add_argument("--arm", required=True)
    for s in sub.choices.values():
        s.add_argument("--meta-out", help="append one JSON line per model call here")
    a = p.parse_args(argv)
    handlers = {"call": cmd_call, "audit": cmd_audit, "sweep": cmd_sweep, "due": cmd_due,
                "settle": cmd_settle, "draft": cmd_draft, "budget": cmd_budget, "config": cmd_config}
    try:
        if a.cmd == "ledger-path":
            print(ledger_path(canon_arm(a.arm)))
            return 0
        return handlers[a.cmd](a)
    except ArmError as e:
        print(f"named_arms: {redact(str(e))}", file=sys.stderr)
        return e.code
    except (urllib.error.URLError, OSError) as e:
        print(f"named_arms: {type(e).__name__}: {redact(str(e))}", file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
