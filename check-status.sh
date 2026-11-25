#!/bin/sh
# Fails if ops-glance.py counts wrong. Runs it on a throwaway ops folder with known items; never touches ~/.claude/ops.
set -e
T=$(mktemp -d); trap 'find "$T" -delete' EXIT
mkdir -p "$T/bin" "$T/dispatch/locks" "$T/drafts" "$T/gate/pending" "$T/la" "$T/cards/B7"
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
touch "$T/drafts/B2.md" "$T/gate/pending/x.sh" "$T/PAUSE-DISPATCH" "$T/cards/B7/1.md"
echo 'MAX_CARDS = 10' > "$T/bin/_chat.py"
echo '{"id":"B1","state":"open","type":"other","summary":"card for B1","created":"'$old'","actions":[{"kind":"decision","text":"y"}]}' > "$T/cards/B1.json"
echo '{"id":"B7","state":"open","type":"comms","summary":"Reply to Jan","created":"'$y'","actions":[{"kind":"teams_send_chat_message","body_file":"'$T'/cards/B7/1.md"},{"kind":"merge"}]}' > "$T/cards/B7.json"
echo '{"id":"B8","state":"done","summary":"old"}' > "$T/cards/B8.json"
OPS_DIR="$T" LAUNCH_AGENTS="$T/la" python3 "$(dirname "$0")/ops-glance.py" | python3 -c '
import json, sys
g = json.load(sys.stdin); d = g["dispatch"]; w = {i["id"]: i for i in g["waiting"]}
assert sorted(w) == ["B2", "B3"], w                                     # B1 has a card: it shows as a card, not twice
assert w["B2"]["open"].endswith("/drafts/B2.md") and w["B3"]["kind"] == "gate" and w["B3"]["open"] is None, w
c = g["cards"]; assert [x["id"] for x in c] == ["B7", "B1"] and g["max_cards"] == 10, c   # open only, oldest first
assert c[0]["does"] == "Teams chat, merge" and c[0]["open"].endswith("/cards/B7/1.md") and c[1]["open"].endswith("/cards/B1.json"), c
assert g["card_approve"].endswith("/bin/card-approve")
assert g["names_you"] == ["B4"], g["names_you"]
assert g["closed_today"] == ["B2", "B5"], g["closed_today"]
assert d["paused"] and d["starts_today"] == 1 and d["usd_today"] == 1.25 and d["usd_cap"] == 25 and d["max_day"] == 10, d
assert d["live"] == 1 and d["max_live"] == 3 and d["age_min"] == 0, d
assert isinstance(g["launchd"]["failed"], list)
print("OK ops-glance: cards 2 (Approve/Edit/Kill), waiting 2, names_you 1, closed 2, $1.25 of $25, 1/10 starts, 1 live, paused")
'
