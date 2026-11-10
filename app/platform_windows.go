package main

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/windows/registry"
)

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// The installer (installer.nsi) puts the app in place; nothing to do here.
func maybeSelfInstall() bool { return false }

// Start at login through the per-user Run key, pointing at this exe wherever it was installed.
func setStartAtLogin(on bool) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !on {
		err := k.DeleteValue("MarketLedger")
		if err == registry.ErrNotExist {
			return nil
		}
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.Abs(exe)
	return k.SetStringValue("MarketLedger", `"`+exe+`"`)
}
