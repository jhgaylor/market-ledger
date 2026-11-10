#!/bin/bash
# Publishes the player-facing source (addon/ and app/, plus public-repo/README.md and LICENSE) to the
# public GitHub repo jhgaylor/market-ledger. Run after a release (release.sh --publish does).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PUB=${PUB_DIR:-$HOME/.cache/market-ledger-public}
REPO=git@github.com:jhgaylor/market-ledger.git
if [ ! -d "$PUB/.git" ]; then git clone -q "$REPO" "$PUB"; fi
cd "$PUB"
git pull -q --ff-only 2>/dev/null || true
rsync -a --delete --exclude .git --exclude 'Data/Feed.lua' "$ROOT/addon/" addon/
rsync -a --delete --exclude .git --exclude 'dist/' --exclude '*.syso' "$ROOT/app/" app/
cp "$ROOT/public-repo/README.md" "$ROOT/public-repo/LICENSE" .
git add -A
if git diff --cached --quiet; then echo "public source already up to date"; exit 0; fi
git -c user.name=jhgaylor -c user.email=jhgaylor@gmail.com commit -q -m "Sync from wow-market $(git -C "$ROOT" rev-parse --short HEAD) (app $(cat "$ROOT/app/VERSION"), addon $(cat "$ROOT/addon/VERSION"))"
git push -q origin HEAD:main
echo "published to https://github.com/jhgaylor/market-ledger"
