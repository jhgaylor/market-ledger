# Market Ledger app

The companion app: a menu bar (Mac) / system tray (Windows) program that finds WoW Forever,
installs and updates the Market Ledger addon, uploads Auctionator scans as they're saved, and
writes the guild's merged prices into the addon (`Data/Feed.lua`) every 10 minutes. It registers
itself with the server on first run (`POST /api/installs`); there's no token to hand out.

- `release.sh` builds both platforms into `dist/`; `release.sh --publish` uploads them to the
  server (served at `/downloads/app/…`). Mac builds are signed with your "Developer ID
  Application" certificate and notarized with a `notarytool` profile (see the script's header).
- Develop against a local server and a fake WoW folder:
  `MARKETLEDGER_SERVER=http://127.0.0.1:8098 MARKETLEDGER_CONFIG_DIR=/tmp/ml MARKETLEDGER_WOW_ROOTS="/tmp/fake/World of Warcraft" go run .`
- Config and log: `~/Library/Application Support/MarketLedger/` (Mac),
  `%APPDATA%\MarketLedger\` (Windows). Windows installs itself to `%LOCALAPPDATA%\MarketLedger`.
