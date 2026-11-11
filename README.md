# Market Ledger

Guild-wide auction house prices for **World of Warcraft Forever**: price checks in chat, and a
shared price history at **https://goblin.trading**.

This repository is the complete source of the two things players install, published so anyone can
check exactly what they do:

- [`addon/MarketLedger`](addon/MarketLedger): the in-game addon (Lua).
- [`app`](app): the Market Ledger companion app for Mac and Windows (Go).

## The addon

Runs inside WoW, which gives addons **no file access and no internet access**.

- **Price checks.** It watches guild, officer, party, raid and instance chat for lines that start
  with `?` followed by an item link, and ignores everything else. It doesn't store or forward chat.
  When it sees a price check it sends a hidden in-game addon message (prefix `MktLedger`) to the
  same channel: a number saying how many days old its price for that item is. After about a second
  every copy picks the freshest price (ties: alphabetical by name), and only that one replies in
  chat, then sends an "answered" note. See `OnChat`, `OnAddonMessage` and `Decide` in
  `MarketLedger.lua`.
- **Prices** come from [Auctionator](https://www.curseforge.com/wow/addons/auctionator) and, if
  the app is installed, from `Data/Feed.lua`, the guild's merged prices the app writes there.
- **Saved data** (`MARKETLEDGER_DB` in `SavedVariables/MarketLedger.lua`): item names and
  categories, and for each of your characters its name, class, race, level, faction, professions
  and known recipes.
- A minimap button and a guide window (`/ledger`). Nothing opens by itself.

## The app

A menu bar (Mac) / system tray (Windows) program. Everything it does is in `app/*.go`:

| | |
|---|---|
| **Reads** | Only `WTF/Account/<account>/SavedVariables/Auctionator.lua` and `MarketLedger.lua` in your WoW Forever folder, checked every 30 seconds (`sync.go`). It finds the folder from Battle.net's config file and the usual install places (`wow.go`), or the folder you pick. |
| **Writes** | Only `Interface/AddOns/MarketLedger` (installing/updating the addon) and its price file `Interface/AddOns/MarketLedger/Data/Feed.lua`, plus its own settings and log (Mac `~/Library/Application Support/MarketLedger/`, Windows `%APPDATA%\MarketLedger\`). |
| **Sends** | Only to `goblin.trading` (versions before 0.3 used its other name, `wow-market.apps.inevitable.fyi`): a one-time anonymous registration (platform and app version), and the two files above when they change. From `Auctionator.lua` it sends **only** the price database and vendor price cache; Auctionator's settings, shopping lists and posting history stay on your computer (`strip.go`). |
| **Downloads** | The merged price file every ~10 minutes, the addon when a new version is out, and a version list to tell you when the app has an update. |
| **Starts** | At login (Mac: `~/Library/LaunchAgents/fyi.inevitable.marketledger.plist`; Windows: the per-user `Run` registry value `MarketLedger`), unless you untick "Start at login". |

It doesn't read your keyboard, clipboard, screen or chat, doesn't touch Battle.net or your
password, and doesn't need admin rights. It listens only on `127.0.0.1:47613`, so a second copy
(or the Windows installer) can ask the running one to quit.

Builds: the Mac app is signed with Apple Developer ID *Jake Gaylor (HNDPMQPF22)* and notarized by
Apple (`codesign -dv --verbose=2 "/Applications/Market Ledger.app"`). Windows builds are not
code-signed; each release's VirusTotal report is linked on the site's download page.

## Building

- App: Go 1.26. `cd app && go build .` (Mac needs cgo for the menu bar). `release.sh` makes the
  signed release builds and the Windows installer (`installer.nsi`).
- Addon: copy `addon/MarketLedger` into `World of Warcraft/_forever_/Interface/AddOns/`.

This repository is published from the private repo that also holds the website; changes land here
with each release.

## License

MIT. See [LICENSE](LICENSE).
