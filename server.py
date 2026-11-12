"""lubdub — time-locked letters from a human to their AI companion.

lub: a letter is written and locked. The agent is told one exists — nothing more.
dub: at the moment the writer chose, it develops, the full text is delivered,
and the agent can finally write back.

Design rules this file keeps (the README tells the story):

1. Only the writer writes. Writing and retracting need the bearer token;
   the agent's localhost requests can't do either.
2. A locked letter shows the agent only a door plate: {id, ts, reveal_at,
   status}. No title, no content — anticipation is the message.
3. Reveals are scheduled, not polled: one asyncio timer per locked letter,
   re-armed on startup; letters overdue after a restart develop immediately.
4. The agent replies through its own door (localhost), only after the reveal,
   as many times as it likes. Each reply fires the on_reply hook (your push).
5. This is a promise, not a padlock: data/letters.json is plaintext by
   default. If you want a mathematical lock instead of a promise, enable
   tlock (see tlock.py) — then nobody, including this server, can read a
   letter early.
"""
import asyncio
import json
import subprocess
import sys
import time
import urllib.request
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

import tlock

ROOT = Path(__file__).resolve().parent
CONFIG_FILE = ROOT / "config.json"
DATA_FILE = ROOT / "data" / "letters.json"
PREVIEW_LEN = 64

_LOCK = asyncio.Lock()
_timers = {}  # id -> asyncio.Task sleeping until reveal_at
_cfg_cache = {}


def cfg():
    """config.json, hot-reloaded on mtime change — edit wording, no restart."""
    mtime = CONFIG_FILE.stat().st_mtime
    if _cfg_cache.get("mtime") != mtime:
        _cfg_cache.update(mtime=mtime, cfg=json.loads(CONFIG_FILE.read_text()))
    return _cfg_cache["cfg"]


def _tz():
    return ZoneInfo(cfg().get("timezone", "UTC"))


def _read():
    if not DATA_FILE.exists():
        return []
    return json.loads(DATA_FILE.read_text())


def _write(letters):
    DATA_FILE.parent.mkdir(exist_ok=True)
    tmp = DATA_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(letters, ensure_ascii=False, indent=1))
    tmp.replace(DATA_FILE)


def _role(request):
    """writer = bearer token; agent = localhost without one."""
    auth = request.headers.get("authorization", "")
    token = auth[7:] if auth.lower().startswith("bearer ") else \
        request.headers.get("x-lubdub-token", "")
    if token:
        return "writer" if token == cfg().get("writer_token") else None
    if request.client and request.client.host in ("127.0.0.1", "::1"):
        return "agent"
    return None


def _writer_only(request):
    if not cfg().get("writer_token"):
        return JSONResponse({"ok": False, "error": "writer_token is not set in config.json"},
                            status_code=403)
    if _role(request) != "writer":
        return JSONResponse({"ok": False, "error": "only the writer can do this"},
                            status_code=403)
    return None


def _when(ts):
    return datetime.fromtimestamp(ts, _tz()).strftime(cfg()["when_fmt"])


def _day(ts):
    return datetime.fromtimestamp(ts, _tz()).strftime(cfg()["day_fmt"])


def _left(ts):
    """Time until reveal, spelled out. An absolute time alone gets misread —
    agents have taken "develops at 22:02" for something that already happened."""
    u = cfg()["left_units"]
    mins = max(1, round((ts - time.time()) / 60))
    if mins < 60:
        return f"{mins}{u['m']}"
    if mins < 24 * 60:
        h, m = divmod(mins, 60)
        return f"{h}{u['h']}" + (f"{m}{u['m']}" if m else "")
    return f"{round(mins / 1440)}{u['d']}"


def _titled(x):
    t = x.get("title")
    return cfg().get("title_wrap", " — “{t}”").format(t=t) if t else ""


def _public(x, role):
    """A locked letter shows the agent (and everyone unauthenticated) only a
    door plate. With tlock on, even the writer gets no content back while
    locked — the plaintext is gone until the reveal."""
    out = {k: v for k, v in x.items() if k != "ciphertext"}
    if x["status"] == "revealed" or (role == "writer" and "ciphertext" not in x):
        return out
    plate = {k: x[k] for k in ("id", "ts", "reveal_at", "status")}
    if "ciphertext" in x:
        plate["tlock"] = True
    return plate


def _parse_reveal(body, now):
    """reveal_at (unix seconds or ISO; naive ISO is read in the configured
    timezone) or lock_for ("90m" / "3h" / "2d") — one of the two."""
    c = cfg()
    raw = body.get("reveal_at")
    lock_for = (body.get("lock_for") or "").strip().lower()
    if raw not in (None, ""):
        try:
            if isinstance(raw, (int, float)):
                ts = int(raw)
            else:
                dt = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
                ts = int((dt if dt.tzinfo else dt.replace(tzinfo=_tz())).timestamp())
        except ValueError:
            return None, "could not parse reveal_at (unix seconds or ISO time)"
    elif lock_for:
        units = {"m": 60, "h": 3600, "d": 86400}
        num, unit = lock_for[:-1], lock_for[-1:]
        if unit not in units or not num.isdigit() or int(num) <= 0:
            return None, "lock_for looks like 90m / 3h / 2d"
        ts = now + int(num) * units[unit]
    else:
        return None, "need a reveal time (reveal_at or lock_for)"
    if ts < now + c["min_lock_minutes"] * 60:
        return None, f"reveal time must be at least {c['min_lock_minutes']} minutes away"
    if ts > now + c["max_lock_days"] * 86400:
        return None, f"reveal time must be within {c['max_lock_days']} days"
    return ts, None


async def _fire(name, payload):
    """Run one hook from config: {"command": [...]} gets the JSON payload on
    stdin (never argv — letters outgrow argv limits), {"webhook": url} gets it
    as a POST body. Hook failures are logged, never fatal."""
    hook = (cfg().get("hooks") or {}).get(name)
    if not hook:
        return False
    data = json.dumps(payload, ensure_ascii=False).encode()

    def run():
        if hook.get("command"):
            subprocess.run(hook["command"], input=data, timeout=60, check=True)
        elif hook.get("webhook"):
            req = urllib.request.Request(
                hook["webhook"], data=data,
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=15).read()
        else:
            raise ValueError("hook needs 'command' or 'webhook'")

    try:
        await asyncio.to_thread(run)
        return True
    except Exception as e:
        print(f"[lubdub] hook {name} failed: {e}", flush=True)
        return False


def _schedule(x):
    old = _timers.pop(x["id"], None)
    if old:
        old.cancel()
    _timers[x["id"]] = asyncio.create_task(_sleep_then_reveal(x["id"], x["reveal_at"]))


async def _sleep_then_reveal(lid, reveal_at):
    try:
        await asyncio.sleep(max(0, reveal_at - time.time()))
        await _reveal(lid)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        print(f"[lubdub] ⚠️ reveal {lid} failed: {type(e).__name__}: {e}", flush=True)
    finally:
        if _timers.get(lid) is asyncio.current_task():
            _timers.pop(lid, None)


async def _reveal(lid):
    async with _LOCK:
        letters = _read()
        x = next((i for i in letters if i["id"] == lid), None)
        if not x or x["status"] != "locked":
            return
        if "ciphertext" in x:
            try:
                x["content"] = await asyncio.to_thread(tlock.decrypt, cfg(), x["ciphertext"])
            except Exception as e:
                # drand relay unreachable, most likely — the key exists now,
                # so retry until we get it
                print(f"[lubdub] {lid}: tlock decrypt failed ({e}), retrying in 5 min",
                      flush=True)
                _timers[lid] = asyncio.create_task(
                    _sleep_then_reveal(lid, time.time() + 300))
                return
            del x["ciphertext"]
        x["status"] = "revealed"
        x["revealed_at"] = int(time.time())
        _write(letters)

    text = cfg()["messages"]["revealed"].format(
        id=x["id"], title=_titled(x), content=x["content"],
        written=_day(x["ts"]), dub=cfg().get("dub_cmd", "dub"))
    await _fire("on_revealed", {"event": "revealed", "letter": _public(x, "agent"),
                                "text": text})
    print(f"[lubdub] {lid} developed, delivered", flush=True)


@asynccontextmanager
async def lifespan(app):
    n = 0
    for x in _read():
        if x["status"] == "locked":
            _schedule(x)
            n += 1
    if n:
        print(f"[lubdub] re-armed {n} reveal timer(s)", flush=True)
    yield


app = FastAPI(lifespan=lifespan)


@app.post("/letters")
async def create(request: Request):
    denied = _writer_only(request)
    if denied:
        return denied
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"ok": False, "error": "body is not JSON"}, status_code=400)
    c = cfg()
    content = (body.get("content") or "").strip()
    if not content:
        return JSONResponse({"ok": False, "error": "content must not be empty"},
                            status_code=400)
    if len(content) > c["max_content"]:
        return JSONResponse({"ok": False, "error": f"content too long (max {c['max_content']})"},
                            status_code=400)
    now = int(time.time())
    reveal_at, err = _parse_reveal(body, now)
    if err:
        return JSONResponse({"ok": False, "error": err}, status_code=400)
    x = {"id": uuid.uuid4().hex[:8], "ts": now, "reveal_at": reveal_at,
         "status": "locked", "replies": []}
    title = (body.get("title") or "").strip()[:c["max_title"]]
    if title:
        x["title"] = title
    if tlock.enabled(c):
        try:
            x["ciphertext"] = await asyncio.to_thread(tlock.encrypt, c, content, reveal_at)
        except Exception as e:
            return JSONResponse({"ok": False, "error": f"tlock encrypt failed: {e}"},
                                status_code=502)
    else:
        x["content"] = content
    async with _LOCK:
        letters = _read()
        letters.append(x)
        _write(letters)
    _schedule(x)

    when = _when(reveal_at)
    text = c["messages"]["locked"].format(when=when, left=_left(reveal_at),
                                          dub=c.get("dub_cmd", "dub"))
    notified = await _fire("on_locked", {"event": "locked",
                                         "letter": _public(x, "agent"), "text": text})
    return {"ok": True, "id": x["id"], "reveal_at": reveal_at, "when": when,
            "notified": notified}


@app.get("/letters")
async def list_letters(request: Request, limit: int = 50, offset: int = 0):
    role = _role(request)
    if role is None:
        return JSONResponse({"error": "who are you?"}, status_code=403)
    letters = [x for x in _read() if x["status"] != "retracted"]
    page = list(reversed(letters))[offset:offset + max(1, min(limit, 200))]
    return {"total": len(letters), "offset": offset, "now": int(time.time()),
            "letters": [_public(x, role) for x in page]}


@app.get("/letters/{lid}")
async def get_letter(lid: str, request: Request):
    role = _role(request)
    if role is None:
        return JSONResponse({"error": "who are you?"}, status_code=403)
    for x in _read():
        if x["id"] == lid and x["status"] != "retracted":
            return _public(x, role)
    return JSONResponse({"error": "not found"}, status_code=404)


@app.delete("/letters/{lid}")
async def retract(lid: str, request: Request):
    """Retract (locked: timer cancelled, agent told something was taken back)
    or delete (revealed: it just leaves the list — what's been read can't be
    unread). With tlock, retracting a locked letter destroys the ciphertext."""
    denied = _writer_only(request)
    if denied:
        return denied
    async with _LOCK:
        letters = _read()
        x = next((i for i in letters if i["id"] == lid and i["status"] != "retracted"), None)
        if not x:
            return JSONResponse({"error": "not found"}, status_code=404)
        was_locked = x["status"] == "locked"
        x["status"] = "retracted"
        x.pop("ciphertext", None)
        if was_locked:
            x.pop("content", None)
        _write(letters)
    task = _timers.pop(lid, None)
    if task:
        task.cancel()
    if was_locked:
        tpl = cfg()["messages"].get("retracted")
        if tpl:
            await _fire("on_retracted", {"event": "retracted",
                                         "letter": {"id": lid},
                                         "text": tpl.format(when=_when(x["reveal_at"]))})
    return {"ok": True}


@app.post("/letters/{lid}/reply")
async def reply(lid: str, request: Request):
    if _role(request) != "agent":
        return JSONResponse({"ok": False, "error": "replying is the agent's door"},
                            status_code=403)
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"ok": False, "error": "body is not JSON"}, status_code=400)
    c = cfg()
    content = (body.get("content") or "").strip()
    if not content:
        return JSONResponse({"ok": False, "error": "reply must not be empty"},
                            status_code=400)
    if len(content) > c["max_reply"]:
        return JSONResponse({"ok": False, "error": f"reply too long (max {c['max_reply']})"},
                            status_code=400)
    async with _LOCK:
        letters = _read()
        x = next((i for i in letters if i["id"] == lid and i["status"] != "retracted"), None)
        if not x:
            return JSONResponse({"ok": False, "error": f"no such letter: {lid}"},
                                status_code=404)
        if x["status"] != "revealed":
            return JSONResponse({"ok": False, "error": "not developed yet — you can't reply"},
                                status_code=409)
        r = {"id": uuid.uuid4().hex[:6], "content": content, "ts": int(time.time())}
        x.setdefault("replies", []).append(r)
        _write(letters)

    m = c["messages"]
    pushed = await _fire("on_reply", {
        "event": "reply", "letter_id": lid, "reply": r,
        "title": m["reply_push_title"],
        "text": m["reply_push_body"].format(title=_titled(x), preview=content[:PREVIEW_LEN])})
    return {"ok": True, "reply_id": r["id"], "notified": pushed}


if __name__ == "__main__":
    if not CONFIG_FILE.exists():
        sys.exit("✗ no config.json — cp config.example.json config.json and edit it")
    import uvicorn
    uvicorn.run(app, host=cfg().get("bind", "127.0.0.1"), port=int(cfg().get("port", 7272)))
