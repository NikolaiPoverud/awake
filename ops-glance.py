#!/usr/bin/python3
# Owner: Nikolai Poverud
# ops-glance.py: the numbers for the Awake notch panel (zero-base 25 Nov 2026). Reads live files only, writes nothing, prints one JSON object.
# Sources (OPS = $OPS_DIR or ~/.claude/ops):
#   waiting      board.jsonl, last line per id: status needs-nikolai or draft-ready, or class GATE with status open. Age = now - updated.
#   names_you    board.jsonl: other items not done/parked whose next starts with "Nikolai" (the rest of the 08:15 digest "Waiting on you").
#   dispatch     PAUSE-DISPATCH, launchctl list com.catalystone.ops-dispatch, dispatch/dispatch.log (last line), dispatch/locks,
#                dispatch/runs.jsonl (local today), caps parsed from bin/dispatch, StartInterval from the LaunchAgent plist.
#   launchd      launchctl list: every com.catalystone.* job whose last exit status is not 0. Log = StandardErrorPath of its plist.
#   closed_today board.jsonl: status done or draft-ready, updated today (local), evidence carries "judge PASS".
#   cards        cards/<id>.json with state open, queued or failed (queue design 25 Nov): type, summary, what Approve runs, body file,
#                age, last error. The panel's Approve / Edit / Kill buttons run CARD_APPROVE (bin/card-approve); max_cards from bin/_chat.py.
# Check: ./check-status.sh (runs this on a fixture folder and asserts every number).
import json, os, re, glob, plistlib, subprocess, datetime as dt
OPS = os.environ.get("OPS_DIR") or os.path.expanduser("~/.claude/ops")
AGENTS = os.environ.get("LAUNCH_AGENTS") or os.path.expanduser("~/Library/LaunchAgents")
P = lambda *a: os.path.join(OPS, *a)
now = dt.datetime.now(dt.timezone.utc)
today = dt.datetime.now().date()
CLOSED = {"done", "parked", "parked-weekend", "dropped", "cancelled"}

def ts(s):
    try: t = dt.datetime.fromisoformat((s or "").replace("Z", "+00:00"))
    except ValueError: return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)
def local_day(s):
    t = ts(s); return t.astimezone().date() if t else None
def ex(p): return p if p and os.path.isfile(p) else None
short = lambda s, n: re.sub(r"\s+", " ", s or "").strip()[:n]

board = {}
for l in open(P("board.jsonl")):
    try: i = json.loads(l)
    except ValueError: continue
    board[i.get("id")] = i   # last line per id wins (same as digest-daily.py)

def target(i):
    """The file to open for an item: its draft, the gate script or draft its next names, then the worker output, then the spec."""
    iid, txt = i["id"], (i.get("next") or "") + " " + (i.get("evidence") or "")
    if i.get("status") == "draft-ready" and ex(P("drafts", iid + ".md")): return P("drafts", iid + ".md")
    for m in re.findall(r"drafts/[\w./-]+?\.md", i.get("next") or ""):
        if ex(P(m)): return P(m)
    for m in re.findall(r"[\w.-]+\.(?:sh|ps1)\b", i.get("next") or ""):
        if ex(P("gate", "pending", m)): return P("gate", "pending", m)
    for m in re.findall(r"gate/pending/[\w.-]+\.(?:sh|ps1)\b", txt):
        if ex(P(m)): return P(m)
    return ex(P("dispatch", "out", iid + ".md")) or ex(P("spec", iid + ".md"))

wait = []
for i in board.values():
    kind = {"needs-nikolai": "needs you", "draft-ready": "yes?"}.get(i.get("status"))
    if not kind and i.get("class") == "GATE" and i.get("status") == "open": kind = "gate"
    if not kind: continue
    u = ts(i.get("updated")) or ts(i.get("created"))
    age_h = round((now - u).total_seconds() / 3600, 1) if u else None
    text = i.get("next") or i.get("ask") or ""
    if kind == "yes?": text = short(i.get("ask") or i.get("title") or text, 200)
    wait.append({"id": i["id"], "kind": kind, "text": short(text, 200), "age_h": age_h, "open": target(i)})
wait.sort(key=lambda w: -(w["age_h"] or 0))
wids = {w["id"] for w in wait}
names_you = sorted(i["id"] for i in board.values() if i.get("id") not in wids and i.get("status") not in CLOSED
                   and re.match(r"(?i)^nikolai\b", i.get("next") or ""))

# Dispatcher
src = open(P("bin", "dispatch")).read() if ex(P("bin", "dispatch")) else ""
m = re.search(r'MAX_LIVE, MAX_DAY, TTL_H, WORKER_USD, JUDGE_USD = (\d+), (\d+), \d+, "([\d.]+)", "([\d.]+)"', src)
max_live, max_day, w_usd, j_usd = (int(m[1]), int(m[2]), float(m[3]), float(m[4])) if m else (None, None, None, None)
ll = subprocess.run(["launchctl", "list"], capture_output=True, text=True).stdout.splitlines()
jobs = {}
for l in ll[1:]:
    f = l.split("\t")
    if len(f) == 3 and f[2].startswith("com.catalystone."): jobs[f[2]] = {"pid": f[0], "status": f[1]}
def plist(label):
    try: return plistlib.load(open(os.path.join(AGENTS, label + ".plist"), "rb"))
    except (OSError, plistlib.InvalidFileException): return {}
DL = "com.catalystone.ops-dispatch"
interval = plist(DL).get("StartInterval")
last_tick, last_line = None, ""
if ex(P("dispatch", "dispatch.log")):
    for l in open(P("dispatch", "dispatch.log")).readlines()[-50:]:
        mm = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)", l)
        if mm: last_tick, last_line = dt.datetime.strptime(mm[1], "%Y-%m-%d %H:%M:%S").astimezone(), mm[2].strip()
age_min = int((now - last_tick).total_seconds() // 60) if last_tick else None
def alive(f):
    try: os.kill(int(open(f).read().split()[0]), 0); return True
    except (OSError, ValueError, IndexError): return False
live = sum(1 for f in glob.glob(P("dispatch", "locks", "*")) if alive(f))
starts, usd = 0, 0.0
if ex(P("dispatch", "runs.jsonl")):
    for l in open(P("dispatch", "runs.jsonl")):
        try: r = json.loads(l)
        except ValueError: continue
        if local_day(r.get("ts")) != today: continue
        if r.get("event") == "start": starts += 1
        if r.get("event") == "end": usd += float(r.get("usd") or 0)
paused = os.path.exists(P("PAUSE-DISPATCH"))
loaded = DL in jobs
stale = age_min is None or (interval is not None and age_min > interval / 60 * 1.5 + 5)
dispatch = {"paused": paused, "loaded": loaded, "exit": jobs.get(DL, {}).get("status"), "ok": loaded and not stale and jobs.get(DL, {}).get("status") in ("0", "-"),
            "last_tick": last_tick.strftime("%H:%M") if last_tick else None, "last_line": short(last_line, 120), "age_min": age_min,
            "interval_min": interval // 60 if interval else None, "live": live, "max_live": max_live, "starts_today": starts, "max_day": max_day,
            "usd_today": round(usd, 2), "usd_cap": round(max_day * (w_usd + j_usd), 2) if m else None, "pause_file": P("PAUSE-DISPATCH"),
            "log": ex(P("dispatch", "dispatch.log")), "runs": ex(P("dispatch", "runs.jsonl"))}

failed = []
for label, j in sorted(jobs.items()):
    if j["status"] not in ("0", "-"):
        pl = plist(label)
        failed.append({"label": label.replace("com.catalystone.", ""), "status": j["status"],
                       "log": ex(pl.get("StandardErrorPath")) or ex(pl.get("StandardOutPath"))})

closed = sorted(i["id"] for i in board.values() if i.get("status") in ("done", "draft-ready")
                and local_day(i.get("updated")) == today and "judge PASS" in (i.get("evidence") or ""))

cards = []
for f in sorted(glob.glob(P("cards", "*.json"))):
    try: c = json.load(open(f))
    except (OSError, ValueError): continue
    if c.get("state") not in ("open", "queued", "failed"): continue
    u = ts(c.get("created")); acts = c.get("actions") or []
    does = ", ".join({"teams_send_chat_message": "Teams chat", "teams_reply_channel_message": "Teams reply", "teams_send_channel_message": "Teams post",
                      "outlook_send_mail": "mail", "merge": "merge", "command": "command", "decision": "yes"}.get(a.get("kind"), a.get("kind") or "?") for a in acts)
    cards.append({"id": c.get("id"), "type": c.get("type") or "other", "state": c["state"], "summary": short(c.get("summary") or c.get("ask"), 200),
                  "does": does, "age_h": round((now - u).total_seconds() / 3600, 1) if u else None, "error": short(c.get("last_error"), 160) or None,
                  "open": next((a["body_file"] for a in acts if ex(a.get("body_file"))), None) or f})
cards.sort(key=lambda c: -(c["age_h"] or 0))
mc = re.search(r"MAX_CARDS = (\d+)", open(P("bin", "_chat.py")).read()) if ex(P("bin", "_chat.py")) else None
wait = [w for w in wait if w["id"] not in {c["id"] for c in cards}]

digest = ex(P("digest", today.isoformat() + ".md"))
print(json.dumps({"now": dt.datetime.now().strftime("%H:%M"), "waiting": wait, "names_you": names_you, "digest": digest,
                  "board": P("board.jsonl"), "dispatch": dispatch, "launchd": {"jobs": len(jobs), "failed": failed},
                  "closed_today": closed, "cards": cards, "max_cards": int(mc[1]) if mc else None,
                  "card_approve": P("bin", "card-approve")}, ensure_ascii=False))
