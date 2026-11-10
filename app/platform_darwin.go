package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
