package main

// Updating the app in place: download the new build, check it against the checksum the server
// published, install it, and restart. Windows runs the installer silently (it asks this copy to
// quit, installs, and starts the new one); Mac swaps the .app bundle and reopens it.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type release struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Sha256  string `json:"sha256"`
}

func releaseName() string {
	if runtime.GOOS == "windows" {
		return "MarketLedger-Setup.exe"
	}
	return "MarketLedger-mac.zip"
}

// latestRelease returns the server's newest build for this platform.
func (a *App) latestRelease() (*release, error) {
	resp, err := client.Get(a.cfg.Server + "/downloads/app/releases.json")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var rels []release
	if err := json.NewDecoder(resp.Body).Decode(&rels); err != nil {
		return nil, err
	}
	for _, r := range rels {
		if r.Name == releaseName() {
			return &r, nil
		}
	}
	return nil, errors.New("no build for this platform")
}

// download fetches the build to a temp file and checks its sha256.
func (a *App) download(r *release) (string, error) {
	resp, err := client.Get(a.cfg.Server + "/downloads/app/" + r.Name)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", errors.New(resp.Status)
	}
	f, err := os.CreateTemp("", "MarketLedger-*-"+r.Name)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, 200<<20))
	f.Close()
	if err != nil {
		os.Remove(f.Name())
		return "", err
	}
	if got := hex.EncodeToString(h.Sum(nil)); !strings.EqualFold(got, r.Sha256) {
		os.Remove(f.Name())
		return "", fmt.Errorf("download didn't match the published checksum")
	}
	return f.Name(), nil
}

// cleanupUpdateLeftovers removes what earlier updates left behind: downloaded builds in the temp
// folder (a running installer can't delete itself) and, on Mac, scratch folders beside the app.
func cleanupUpdateLeftovers() {
	old, _ := filepath.Glob(filepath.Join(os.TempDir(), "MarketLedger-*-MarketLedger-*"))
	for _, f := range old {
		if st, err := os.Stat(f); err == nil && time.Since(st.ModTime()) > time.Hour {
			_ = os.Remove(f)
		}
	}
	cleanupBundleLeftovers()
}

// updateNow installs the newest build and restarts into it.
func (a *App) updateNow() {
	r, err := a.latestRelease()
	if err != nil {
		a.setStatus("upload", "Update failed: "+err.Error())
		return
	}
	a.update.SetTitle("Updating to " + r.Version + "…")
	a.update.Disable()
	path, err := a.download(r)
	if err == nil {
		a.log("updating to %s from %s", r.Version, filepath.Base(path))
		err = installUpdate(path) // on success the app quits and the new one starts
	}
	if err != nil {
		a.log("update failed: %v", err)
		a.update.SetTitle("Update failed, try again (" + r.Version + ")")
		a.update.Enable()
	}
}
