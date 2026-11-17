#!/bin/sh
# Fails if the ops dashboard /api/status is down or has the wrong shape. Awake's hover panel reads exactly these fields.
curl -sf --max-time 5 http://127.0.0.1:8788/api/status | python3 -c '
import json, sys
s = json.load(sys.stdin)
a = s["agents"]
assert a and all({"name", "health", "progress", "done_today"} <= set(x) for x in a), "agents shape"
assert all(x["health"] in ("earning", "quiet", "stuck", "paused", "error") for x in a), "health value"
assert isinstance(s["decisions"]["count"], int) and isinstance(s["decisions"]["oldest"], list), "decisions shape"
assert isinstance(s["runner"]["ok"], bool) and isinstance(s["triage"]["on"], bool) and "failing" in s["jobs"], "global shape"
print("OK", len(a), "agents,", s["decisions"]["count"], "decisions")
' || { echo "FAIL: /api/status broken"; exit 1; }
