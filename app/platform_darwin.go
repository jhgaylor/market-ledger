package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"fyne.io/systray"
)

const launchLabel = "fyi.inevitable.marketledger"

func maybeSelfInstall() bool { return false } // Mac: the app is dragged into Applications

// A LaunchAgent that opens the app at login. Points at the .app bundle we're running from.
func setStartAtLogin(on bool) error {
	home, _ := os.UserHomeDir()
	plist := filepath.Join(home, "Library", "LaunchAgents", launchLabel+".plist")
	if !on {
		err := os.Remove(plist)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	bundle := exe
	if i := strings.Index(exe, ".app/"); i >= 0 {
		bundle = exe[:i+4]
	} else {
		return nil // not running from an .app (development): don't register
	}
	body := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-g</string><string>%s</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
`, launchLabel, xmlEscape(bundle))
	if err := os.MkdirAll(filepath.Dir(plist), 0o755); err != nil {
		return err
	}
	if old, err := os.ReadFile(plist); err == nil && string(old) == body {
		return nil
	}
	if err := os.WriteFile(plist, []byte(body), 0o644); err != nil {
		return err
	}
	_ = exec.Command("launchctl", "bootstrap", fmt.Sprintf("gui/%d", os.Getuid()), plist).Run()
	return nil
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// installUpdate replaces the running .app bundle with the one in the downloaded zip, then reopens
// it and quits. The zip is notarized; it isn't quarantined, since the app (not a browser) fetched it.
func installUpdate(zipPath string) error {
	defer os.Remove(zipPath)
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	i := strings.Index(exe, ".app/")
	if i < 0 {
		return fmt.Errorf("not running from an .app bundle")
	}
	bundle := exe[:i+4]
	tmp, err := os.MkdirTemp(filepath.Dir(bundle), ".MarketLedger-update-")
	if err != nil {
		return fmt.Errorf("can't write next to %s: %w", bundle, err)
	}
	defer os.RemoveAll(tmp)
	if out, err := exec.Command("ditto", "-x", "-k", zipPath, tmp).CombinedOutput(); err != nil {
		return fmt.Errorf("unzipping: %v %s", err, out)
	}
	fresh := filepath.Join(tmp, "Market Ledger.app")
	if _, err := os.Stat(fresh); err != nil {
		return fmt.Errorf("the download had no Market Ledger.app")
	}
	old := filepath.Join(tmp, "previous.app")
	if err := os.Rename(bundle, old); err != nil {
		return err
	}
	if err := os.Rename(fresh, bundle); err != nil {
		_ = os.Rename(old, bundle)
		return err
	}
	// Clean up now: quitting ends the process before deferred calls would run.
	_ = os.RemoveAll(tmp)
	_ = os.Remove(zipPath)
	// Reopen once we've quit (the new copy would otherwise find us still holding the lock).
	_ = exec.Command("/bin/sh", "-c", "sleep 2; /usr/bin/open "+shellQuote(bundle)).Start()
	systray.Quit()
	return nil
}

// cleanupBundleLeftovers removes scratch folders an interrupted update left beside the app.
func cleanupBundleLeftovers() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	exe, _ = filepath.EvalSymlinks(exe)
	if i := strings.Index(exe, ".app/"); i >= 0 {
		old, _ := filepath.Glob(filepath.Join(filepath.Dir(exe[:i+4]), ".MarketLedger-update-*"))
		for _, d := range old {
			_ = os.RemoveAll(d)
		}
	}
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
