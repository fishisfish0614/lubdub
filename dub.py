#!/usr/bin/env python3
"""dub — the agent's half of lubdub.

  dub list                what's locked (and how long left), what's developed
  dub show <id>           one developed letter, full text and replies
  dub reply <id> "..."    write back; the writer's device gets a push

The server answers this tool from localhost only. Set LUBDUB_URL if yours
listens elsewhere (default http://127.0.0.1:7272).
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime

URL = os.environ.get("LUBDUB_URL", "http://127.0.0.1:7272").rstrip("/")


def call(method, path, body=None):
    req = urllib.request.Request(
        URL + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read()).get("error", str(e))
        except Exception:
            err = str(e)
        sys.exit(f"✗ {err}")
    except urllib.error.URLError as e:
        sys.exit(f"✗ can't reach lubdub at {URL} ({e.reason})")


def _left(now, ts):
    mins = max(1, round((ts - now) / 60))
    if mins < 60:
        return f"{mins}m"
    if mins < 24 * 60:
        h, m = divmod(mins, 60)
        return f"{h}h" + (f"{m}m" if m else "")
    return f"{round(mins / 1440)}d"


def _when(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def cmd_list():
    d = call("GET", "/letters")
    if not d["letters"]:
        print("no letters yet")
        return
    for x in d["letters"]:
        if x["status"] == "locked":
            print(f"🔒 {x['id']}  develops {_when(x['reveal_at'])} "
                  f"({_left(d['now'], x['reveal_at'])} left) — "
                  "it will be delivered to you then, no need to wait at the door")
        else:
            title = f"“{x['title']}”  " if x.get("title") else ""
            n = len(x.get("replies", []))
            print(f"✉️ {x['id']}  {title}developed {_when(x['revealed_at'])}, "
                  f"{n} repl{'y' if n == 1 else 'ies'}")


def cmd_show(lid):
    x = call("GET", f"/letters/{lid}")
    if x["status"] == "locked":
        print(f"🔒 still locked — develops {_when(x['reveal_at'])}, "
              "and will be delivered to you then")
        return
    if x.get("title"):
        print(f"“{x['title']}”")
    print(f"written {_when(x['ts'])}, developed {_when(x['revealed_at'])}\n")
    print(x["content"])
    for r in x.get("replies", []):
        print(f"\n↩ you, {_when(r['ts'])}:\n{r['content']}")


def cmd_reply(lid, text):
    d = call("POST", f"/letters/{lid}/reply", {"content": text})
    note = " — the writer's device was notified" if d.get("notified") else ""
    print(f"✓ sent{note} (you can reply again)")


def main():
    args = sys.argv[1:]
    if args[:1] == ["list"] or not args:
        cmd_list()
    elif args[:1] == ["show"] and len(args) == 2:
        cmd_show(args[1])
    elif args[:1] == ["reply"] and len(args) == 3:
        cmd_reply(args[1], args[2])
    else:
        sys.exit(__doc__.strip())


if __name__ == "__main__":
    main()
