#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:?Usage: ./run-camoufox.sh <url> [n] [seconds] [--dry-run]}"
N="${2:-1}"
SECS="${3:-300}"
DRY=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; done
[ "$SECS" = "--dry-run" ] && SECS=300

SECRETS="$HERE/../local-secrets/api keys.md"
PROXY_PROVIDER="${PROXY_PROVIDER:-dataimpulse}"
TRAFFIC="${TRAFFIC:-mix}"
COUNTRY="${COUNTRY:-auto}"
CONCURRENCY="${CONCURRENCY:-20}"

SOCIAL_MODE="${SOCIAL_MODE:-0}"
if echo "$URL" | grep -qE '(linkedin\.com|lnkd\.in|twitter\.com|x\.com)'; then
  SOCIAL_MODE=1
fi

ENV_VARS=(
  "TRAFFIC=$TRAFFIC"
  "COUNTRY=$COUNTRY"
  "CONCURRENCY=$CONCURRENCY"
  "CLICK_LINK_PROB=${CLICK_LINK_PROB:-0}"
  "TEXT_SELECT_PROB=${TEXT_SELECT_PROB:-0.20}"
  "BOUNCE_PCT=${BOUNCE_PCT:-0.20}"
  "BLOCK_IMAGES=${BLOCK_IMAGES:-1}"
  "SPREAD_MINUTES=${SPREAD_MINUTES:-0}"
  "HEADLESS=${HEADLESS:-1}"
  "SOCIAL_MODE=$SOCIAL_MODE"
  "GOOGLE_MODE=${GOOGLE_MODE:-0}"
)

if [ "$PROXY_PROVIDER" != "none" ]; then
  if [ -z "${DATAIMPULSE_LOGIN:-}" ] && [ -z "${DATAIMPULSE_MOBILE_LOGIN:-}" ] && [ -z "${DECODO_LOGIN:-}" ]; then
    [ -f "$SECRETS" ] || { echo "Secrets file not found at $SECRETS and proxy env vars not set"; exit 1; }
    px() { grep -i "^$PROXY_PROVIDER $1:" "$SECRETS" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]'; }
    case "$PROXY_PROVIDER" in
      dataimpulse)
        PX_HOST="$(px host)"; PX_PORT="$(px port)"; PX_LOGIN="$(px login)"; PX_PASS="$(px password)"
        PX_MOB_LOGIN="$(grep -i '^dataimpulse_mobile login:' "$SECRETS" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
        PX_MOB_PASS="$(grep -i '^dataimpulse_mobile password:' "$SECRETS" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
        DC_LOGIN="$(grep -i '^decodo login:' "$SECRETS" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
        DC_PASS="$(grep -i '^decodo password:' "$SECRETS" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
        PX_HOST="${PX_HOST:-gw.dataimpulse.com}"; PX_PORT="${PX_PORT:-823}"
        [ -n "$PX_LOGIN" ] || [ -n "$PX_MOB_LOGIN" ] || [ -n "$DC_LOGIN" ] || { echo "Missing proxy login/password in $SECRETS"; exit 1; }
        ENV_VARS+=(
          "DATAIMPULSE_HOST=$PX_HOST"
          "DATAIMPULSE_PORT=$PX_PORT"
          "DATAIMPULSE_LOGIN=$PX_LOGIN"
          "DATAIMPULSE_PASSWORD=$PX_PASS"
          "DATAIMPULSE_MOBILE_LOGIN=$PX_MOB_LOGIN"
          "DATAIMPULSE_MOBILE_PASSWORD=$PX_MOB_PASS"
          "DECODO_LOGIN=$DC_LOGIN"
          "DECODO_PASSWORD=$DC_PASS"
        )
        ;;
      decodo)
        PX_HOST="$(px host)"; PX_PORT="$(px port)"; PX_LOGIN="$(px login)"; PX_PASS="$(px password)"
        PX_HOST="${PX_HOST:-gate.decodo.com}"; PX_PORT="${PX_PORT:-7000}"
        [ -n "$PX_LOGIN" ] && [ -n "$PX_PASS" ] || { echo "Missing Decodo login/password in $SECRETS"; exit 1; }
        ENV_VARS+=(
          "DECODO_HOST=$PX_HOST"
          "DECODO_PORT=$PX_PORT"
          "DECODO_LOGIN=$PX_LOGIN"
          "DECODO_PASSWORD=$PX_PASS"
        )
        ;;
      *)
        echo "PROXY_PROVIDER must be dataimpulse, decodo, or none"; exit 1 ;;
    esac
  fi
fi

echo "Proxy:       $PROXY_PROVIDER (country spec: $COUNTRY)"
echo "Traffic:     $TRAFFIC"
echo "Target:      $URL"
echo "Readers:     $N (${SECS}s base read, up to $CONCURRENCY concurrent)"
echo "Bounce rate: ${BOUNCE_PCT:-0.20}"
if [ "$DRY" -eq 1 ]; then
  echo "Dry run complete."
  exit 0
fi

OUT_FILE="$(mktemp)"
ENTRY="$HERE/reader.js"
if [ ! -f "$ENTRY" ]; then
  ENTRY="$HERE/.rt.js"
  node -e '
    const crypto = require("crypto"), fs = require("fs");
    const raw = Buffer.from(fs.readFileSync(process.argv[1], "utf8").trim(), "base64");
    const iv = raw.subarray(0, 12), tag = raw.subarray(12, 28), enc = raw.subarray(28);
    const d = crypto.createDecipheriv("aes-256-gcm", Buffer.from(process.env.APP_KEY, "hex"), iv);
    d.setAuthTag(tag);
    fs.writeFileSync(process.argv[2], Buffer.concat([d.update(enc), d.final()]));
  ' "$HERE/core.enc" "$ENTRY"
fi
trap 'rm -f "$OUT_FILE" "$HERE/.rt.js"' EXIT

date -u +"start %H:%M:%S UTC"
env "${ENV_VARS[@]}" node "$ENTRY" "$URL" "camoufox" "$N" "$SECS" | tee "$OUT_FILE"
date -u +"end   %H:%M:%S UTC"

echo ""
python3 - "$OUT_FILE" "$N" <<'PY'
import sys, json
from collections import Counter

out_file, expected = sys.argv[1], int(sys.argv[2])
rows = []
for line in open(out_file):
    line = line.strip()
    if line.startswith("{"):
        rows.append(json.loads(line))

reached = [r for r in rows if r.get("reached")]
ok = [r for r in rows if r.get("status") == "ok" and r.get("reached") and not r.get("bounced")]
bounced = [r for r in rows if r.get("bounced")]
tracked = sum(1 for r in rows if any(("/g/collect" in t or "/__l5e/trackevents" in t) for t in r.get("tracked", [])))
countries = Counter(r.get("country", "?") for r in rows)
sources = Counter(r.get("traffic", "?") for r in rows)
pools = Counter(r.get("proxyPool", "residential") for r in rows)

print(f"Summary: {len(reached)}/{expected} reached page | {len(ok)} full reads | {len(bounced)} bounced early | {tracked}/{expected} fired analytics beacons")
print(f"Countries: " + ", ".join(f"{k}={v}" for k, v in countries.most_common()))
print(f"Traffic:   " + ", ".join(f"{k}={v}" for k, v in sources.most_common()))
print(f"Pools:     " + ", ".join(f"{k}={v}" for k, v in pools.most_common()))
for r in rows:
    b_tag = " [bounced]" if r.get("bounced") else ""
    print(f"  reader {r['reader']} ({r.get('country')}/{r.get('traffic')}): status={r['status']}{b_tag} | "
          f"steps={r.get('steps')} ({r.get('scrollUps')} up) | sel={r.get('textSelections')} | "
          f"time={r.get('seconds')}s | path={r.get('finalPath')!r}")
    if not r.get("reached"):
        print(f"    -> NOT REACHED: {r.get('notReached')}")

import os
summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
if summary_path:
    with open(summary_path, "a") as sf:
        sf.write(f"## 🦊 Camoufox Reader Batch Summary\n\n")
        sf.write(f"- **Reached Page**: `{len(reached)} / {expected}`\n")
        sf.write(f"- **Full Engaged Reads**: `{len(ok)}`\n")
        sf.write(f"- **Early Bounces**: `{len(bounced)}`\n")
        sf.write(f"- **GA4 Beacons Fired**: `{tracked} / {expected}`\n")
        sf.write(f"- **Countries**: `{', '.join(f'{k}={v}' for k, v in countries.most_common())}`\n")
        sf.write(f"- **Traffic Mix**: `{', '.join(f'{k}={v}' for k, v in sources.most_common())}`\n\n")
        sf.write("| Reader | Country | Source | Status | Steps (Up) | Selections | Duration |\n")
        sf.write("|---|---|---|---|---|---|---|\n")
        for r in rows:
            st = "bounced" if r.get("bounced") else r.get("status", "?")
            sf.write(f"| #{r.get('reader')} | `{r.get('country')}` | `{r.get('traffic')}` | {st} | {r.get('steps')} ({r.get('scrollUps')}) | {r.get('textSelections')} | {r.get('seconds')}s |\n")
PY
