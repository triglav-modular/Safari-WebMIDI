#!/bin/bash
# How many times Web MIDI has been downloaded: what the worker counted
# (deploy/worker.js), by day, month and version, and GitHub's own count for
# each release beside it.
#
#   ./tools/downloads.sh
#
# The worker counts a browser's click on the page's Download, a link to it or
# the address typed, so it is a floor: a download straight from GitHub, or by
# curl, is not in it.  GitHub counts every fetch of the asset, from anywhere: bots, direct
# links, and tools/release.sh's own check of each new release (from v0.1.7 on),
# one each.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="triglav-modular/Safari-WebMIDI"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

npx wrangler kv key list --binding COUNTS --prefix dl: --remote > "$T/keys.json"
gh api "repos/$REPO/releases" --paginate \
    --jq '.[] | [.tag_name, ([.assets[] | select(.name == "Web-MIDI.dmg") | .download_count] | add // 0)] | @tsv' \
    > "$T/github.tsv"

python3 - "$T/keys.json" "$T/github.tsv" <<'EOF'
import collections, datetime, json, sys

keys = json.load(open(sys.argv[1]))
days, months, versions = collections.Counter(), collections.Counter(), collections.Counter()
for k in keys:
    day = k["name"].split(":")[1]
    days[day] += 1
    months[day[:7]] += 1
    versions[(k.get("metadata") or {}).get("version") or "unknown"] += 1

def vkey(v):
    return [int(x) for x in v.split(".")] if v[0].isdigit() else [-1]

print(f"Counted by the worker: {len(keys)}" + (f", since {min(days)}" if days else ""))
if keys:
    since = (datetime.date.today() - datetime.timedelta(days=29)).isoformat()
    recent = sorted(d for d in days if d >= since)
    if recent:
        print("  last 30 days")
        for d in recent:
            print(f"    {d}  {days[d]:6}")
    print("  by month")
    for m in sorted(months):
        print(f"    {m}     {months[m]:6}")
    print("  by version")
    for v in sorted(versions, key=vkey):
        print(f"    {v:10} {versions[v]:6}")

rows = [line.rstrip("\n").split("\t") for line in open(sys.argv[2]) if line.strip()]
rows.sort(key=lambda r: vkey(r[0].lstrip("v")))
print(f"GitHub's count: {sum(int(n) for _, n in rows)}, "
      "with one fetch in each release from v0.1.7 on by tools/release.sh's check")
for tag, n in rows:
    print(f"    {tag:10} {int(n):6}")
EOF
