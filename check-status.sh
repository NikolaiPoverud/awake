#!/bin/sh
# Fails if ops-glance.py counts wrong. Runs it on a throwaway ops folder with known items; never touches ~/.claude/ops.
set -e
T=$(mktemp -d); trap 'find "$T" -delete' EXIT
mkdir -p "$T/bin" "$T/dispatch/locks" "$T/drafts" "$T/gate/pending" "$T/la"
now=$(date -u +%FT%TZ); old=$(date -u -v-3H +%FT%TZ); y=$(date -u -v-2d +%FT%TZ)
cat > "$T/board.jsonl" <<EOF
{"id":"B1","status":"needs-nikolai","next":"run x.sh","updated":"$old"}
{"id":"B2","status":"draft-ready","class":"DRAFT","ask":"draft for Jan","updated":"$now","evidence":"judge PASS: ok"}
{"id":"B3","status":"open","class":"GATE","ask":"gate it","updated":"$now"}
{"id":"B4","status":"blocked","next":"Nikolai: approve","updated":"$y"}
{"id":"B5","status":"done","updated":"$now","evidence":"dispatch worker DONE, judge PASS: proof"}
{"id":"B6","status":"done","updated":"$y","evidence":"judge PASS: old"}
{"id":"B1","status":"needs-nikolai","next":"run x.sh, then drafts/B2.md","updated":"$old"}
EOF
echo 'MAX_LIVE, MAX_DAY, TTL_H, WORKER_USD, JUDGE_USD = 3, 10, 3, "2", "0.5"' > "$T/bin/dispatch"
printf '{"ts": "%s", "event": "start", "id": "B5"}\n{"ts": "%s", "event": "end", "id": "B5", "usd": 1.25}\n{"ts": "%s", "event": "end", "id": "B6", "usd": 9}\n' "$now" "$now" "$y" > "$T/dispatch/runs.jsonl"
echo "$(date '+%F %T') tick: 0 due" > "$T/dispatch/dispatch.log"
echo "$$ $now" > "$T/dispatch/locks/B5"; echo "999999 $now" > "$T/dispatch/locks/B6"
touch "$T/drafts/B2.md" "$T/gate/pending/x.sh" "$T/PAUSE-DISPATCH"
OPS_DIR="$T" LAUNCH_AGENTS="$T/la" python3 "$(dirname "$0")/ops-glance.py" | python3 -c '
import json, sys
g = json.load(sys.stdin); d = g["dispatch"]; w = {i["id"]: i for i in g["waiting"]}
assert sorted(w) == ["B1", "B2", "B3"], w
assert w["B1"]["kind"] == "needs you" and w["B1"]["open"].endswith("/drafts/B2.md"), w["B1"]   # last line per id wins; a named draft beats a script
assert w["B2"]["open"].endswith("/drafts/B2.md") and w["B3"]["kind"] == "gate" and w["B3"]["open"] is None, w
assert g["waiting"][0]["id"] == "B1", "oldest first"
assert g["names_you"] == ["B4"], g["names_you"]
assert g["closed_today"] == ["B2", "B5"], g["closed_today"]
assert d["paused"] and d["starts_today"] == 1 and d["usd_today"] == 1.25 and d["usd_cap"] == 25 and d["max_day"] == 10, d
assert d["live"] == 1 and d["max_live"] == 3 and d["age_min"] == 0, d
assert isinstance(g["launchd"]["failed"], list)
print("OK ops-glance: waiting 3, names_you 1, closed 2, $1.25 of $25, 1/10 starts, 1 live, paused")
'
