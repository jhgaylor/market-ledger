#!/bin/bash
# Builds the Market Ledger companion app for Mac and Windows, and (with --publish) uploads both to
# the server, which serves them at /downloads/app/<name>. Run on a Mac.
#
#   app/release.sh             build into app/dist/
#   app/release.sh --publish   build, then upload (admin token from the Keychain: wow-market/upload)
#
# Mac signing: uses the first "Developer ID Application" identity in your keychain (or $SIGN_IDENTITY).
# Without one the app is signed ad hoc, which only runs on this Mac. Notarizing needs a notarytool
# profile, made once with:
#   xcrun notarytool store-credentials marketledger --apple-id <you> --team-id <TEAM> --password <app-specific password>
# ($NOTARY_PROFILE picks another name.)
#
# Windows: the app is wrapped in an NSIS installer (installer.nsi, built with makensis in Docker) with
# version info and an icon embedded by go-winres. Signing uses Azure Trusted Signing through jsign
# (brew install jsign azure-cli; az login) when ~/.config/marketledger/windows-signing.env exists:
#   TS_ENDPOINT=https://<region>.codesigning.azure.net   TS_ACCOUNT=<account>   TS_PROFILE=<certificate profile>
# Without it the Windows build is unsigned (SmartScreen warns on first run).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
V=$(cat VERSION)
SERVER=${SERVER:-https://wow-market.apps.inevitable.fyi}
PUBLISH=false
[ "${1:-}" = "--publish" ] && PUBLISH=true
DIST="$HERE/dist"
rm -rf "$DIST" && mkdir -p "$DIST"
say() { printf '==> %s\n' "$*"; }

# --- Windows ------------------------------------------------------------------------------------
WIN_SIGN_ENV="$HOME/.config/marketledger/windows-signing.env"
WIN_SIGNED=false
win_sign() { # sign a Windows exe with Azure Trusted Signing, if it's set up
  [ -f "$WIN_SIGN_ENV" ] || return 0
  # shellcheck source=/dev/null
  . "$WIN_SIGN_ENV"
  local token
  token=$(az account get-access-token --resource https://codesigning.azure.net --query accessToken -o tsv)
  jsign --storetype TRUSTEDSIGNING --keystore "$TS_ENDPOINT" --storepass "$token" --alias "$TS_ACCOUNT/$TS_PROFILE" \
    --tsaurl http://timestamp.acs.microsoft.com --tsmode RFC3161 --replace "$1"
  WIN_SIGNED=true
}

say "Windows build $V"
"$(go env GOPATH)/bin/go-winres" make --in winres/winres.json --arch amd64 --product-version "$V" --file-version "$V"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-H=windowsgui -X main.version=$V" -o "$DIST/MarketLedger.exe" .
win_sign "$DIST/MarketLedger.exe"
say "Windows installer"
# makensis runs in a container (build/nsis.Dockerfile): Homebrew's crashes on recent macOS.
docker build -q -t marketledger-nsis -f build/nsis.Dockerfile build >/dev/null
docker run --rm -v "$HERE":/work marketledger-nsis -V2 -DVERSION="$V" installer.nsi
win_sign "$DIST/MarketLedger-Setup.exe"
rm "$DIST/MarketLedger.exe"
$WIN_SIGNED && say "Windows build signed" || say "Windows build NOT signed (no $WIN_SIGN_ENV)"

# --- Mac ----------------------------------------------------------------------------------------
say "Mac build $V (arm64 + amd64)"
CGO_ENABLED=1 GOARCH=arm64 go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$DIST/ml-arm64" .
CGO_ENABLED=1 GOARCH=amd64 CC="clang -arch x86_64" go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$DIST/ml-amd64" .
APP="$DIST/Market Ledger.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/MarketLedger" "$DIST/ml-arm64" "$DIST/ml-amd64"
rm "$DIST/ml-arm64" "$DIST/ml-amd64"

ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/logo-400.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); [ $d -gt 400 ] && d=400
  sips -z $d $d assets/logo-400.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>fyi.inevitable.marketledger</string>
  <key>CFBundleName</key><string>Market Ledger</string>
  <key>CFBundleDisplayName</key><string>Market Ledger</string>
  <key>CFBundleExecutable</key><string>MarketLedger</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$V</string>
  <key>CFBundleVersion</key><string>$V</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>Market Ledger reads your WoW saved data to upload auction scans and installs its addon, if World of Warcraft is in your Documents folder.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Market Ledger reads your WoW saved data to upload auction scans and installs its addon, if World of Warcraft is on your Desktop.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Market Ledger reads your WoW saved data to upload auction scans and installs its addon, if World of Warcraft is in your Downloads folder.</string>
</dict>
</plist>
EOF

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
if [ -n "$IDENTITY" ]; then
  say "signing with $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  say "no Developer ID Application certificate: signing ad hoc (runs on this Mac only)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

MAC_ZIP="$DIST/MarketLedger-mac.zip"
ditto -c -k --keepParent "$APP" "$MAC_ZIP"
PROFILE=${NOTARY_PROFILE:-marketledger}
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  say "notarizing (a few minutes)"
  xcrun notarytool submit "$MAC_ZIP" --keychain-profile "$PROFILE" --wait
  # Stapling fetches the ticket from Apple's CDN, which occasionally drops the connection: retry.
  # A notarized app passes Gatekeeper without the staple too (it looks the ticket up online); the
  # staple only helps first launch offline, so a failure here is a warning, not a stop.
  STAPLED=false
  for i in 1 2 3 4 5; do xcrun stapler staple "$APP" >/dev/null 2>&1 && { STAPLED=true; break; }; sleep 15; done
  $STAPLED || say "warning: couldn't staple the notarization ticket (Apple's CDN); shipping notarized but unstapled"
  rm "$MAC_ZIP" && ditto -c -k --keepParent "$APP" "$MAC_ZIP"
  spctl --assess --type execute --verbose "$APP"
elif [ -n "$IDENTITY" ]; then
  say "not notarized: no notarytool profile \"$PROFILE\" (see the top of this script)"
fi

ls -la "$DIST"

# --- publish ------------------------------------------------------------------------------------
if $PUBLISH; then
  if [ -z "$IDENTITY" ]; then echo "refusing to publish an ad-hoc signed Mac app" >&2; exit 1; fi
  TOKEN=$(security find-generic-password -s wow-market -a upload -w)
  for f in "$MAC_ZIP" "$DIST/MarketLedger-Setup.exe"; do
    say "publishing $(basename "$f")"
    curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @"$f" \
      "$SERVER/api/admin/release/$(basename "$f")?version=$V"
    echo
  done

  say "publishing source to github.com/jhgaylor/market-ledger"
  "$HERE/publish-source.sh"
fi
