package main

// Talking to the Market Ledger server: registering this install, uploading scans, keeping the
// addon installed and up to date, and writing the merged price feed into it.

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

var client = &http.Client{Timeout: 5 * time.Minute}

func (a *App) register() error {
	if a.cfg.InstallID != "" {
		return nil
	}
	body, _ := json.Marshal(map[string]string{"platform": runtime.GOOS + "/" + runtime.GOARCH, "version": version})
	resp, err := client.Post(a.cfg.Server+"/api/installs", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("registering: %s", resp.Status)
	}
	var v struct{ ID, Secret string }
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		return err
	}
	a.cfg.InstallID, a.cfg.Secret = v.ID, v.Secret
	a.log("registered as install %s", v.ID)
	return a.saveConfig()
}

func (a *App) authHeader() string { return "Install " + a.cfg.InstallID + "." + a.cfg.Secret }

// --- uploads -------------------------------------------------------------------------------------

var uploadFiles = []struct{ kind, name string }{
	{"auctionator", "Auctionator.lua"},
	{"marketledger", "MarketLedger.lua"},
}

// Upload any saved-variables file that changed since its last upload. WoW writes these when you
// log out or /reload; a file written in the last few seconds is left for the next pass.
func (a *App) uploadChanged() {
	for _, root := range a.roots() {
		for _, dir := range savedVariablesDirs(root) {
			for _, f := range uploadFiles {
				path := filepath.Join(dir, f.name)
				st, err := os.Stat(path)
				if err != nil || time.Since(st.ModTime()) < 5*time.Second {
					continue
				}
				data, err := os.ReadFile(path)
				if err != nil {
					a.setStatus("upload", "Can't read "+f.name+": "+err.Error())
					continue
				}
				if f.kind == "auctionator" {
					data = keepTopLevel(data, auctionatorKeep)
					if len(data) == 0 {
						continue // no price data in it yet
					}
				}
				sum := sha256.Sum256(data)
				h := hex.EncodeToString(sum[:])
				if a.cfg.Uploaded[path] == h {
					continue
				}
				if err := a.upload(f.kind, data); err != nil {
					a.log("upload %s failed: %v", path, err)
					a.setStatus("upload", "Upload failed: "+err.Error())
					continue
				}
				a.cfg.Uploaded[path] = h
				_ = a.saveConfig()
				a.log("uploaded %s", path)
				a.setStatus("upload", "Scans uploaded "+time.Now().Format("Jan 2 15:04"))
			}
		}
	}
}

func (a *App) upload(kind string, data []byte) error {
	req, _ := http.NewRequest("POST", a.cfg.Server+"/api/upload/"+kind, bytes.NewReader(data))
	req.Header.Set("Authorization", a.authHeader())
	req.Header.Set("Content-Type", "application/octet-stream")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 {
		// Our registration is gone (or banned): start over with a new one next time.
		a.cfg.InstallID, a.cfg.Secret = "", ""
		_ = a.saveConfig()
		return errors.New("the server didn't accept this install")
	}
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	return nil
}

// --- the addon -----------------------------------------------------------------------------------

var tocVersion = regexp.MustCompile(`(?m)^## Version:\s*(\S+)`)

func installedAddonVersion(root string) string {
	b, err := os.ReadFile(filepath.Join(addonsDir(root), "MarketLedger", "MarketLedger.toc"))
	if err != nil {
		return ""
	}
	if m := tocVersion.FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return "?"
}

// Install or update the Market Ledger addon in every WoW folder. A folder that's a symlink (a
// developer's checkout) is left alone.
func (a *App) ensureAddon() {
	resp, err := client.Get(a.cfg.Server + "/downloads/version.json")
	if err != nil {
		a.log("version check: %v", err)
		return
	}
	var v struct{ Version string }
	_ = json.NewDecoder(resp.Body).Decode(&v)
	resp.Body.Close()
	if v.Version == "" {
		return
	}
	for _, root := range a.roots() {
		dest := filepath.Join(addonsDir(root), "MarketLedger")
		if fi, err := os.Lstat(dest); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			a.setStatus("addon", "Market Ledger addon: developer copy")
			continue
		}
		have := installedAddonVersion(root)
		if have == v.Version {
			a.setStatus("addon", "Market Ledger addon "+have)
			continue
		}
		if err := a.installAddon(root); err != nil {
			a.log("installing addon in %s: %v", root, err)
			a.setStatus("addon", "Couldn't install the addon: "+err.Error())
			continue
		}
		a.log("installed addon %s in %s (had %q)", v.Version, root, have)
		a.setStatus("addon", "Market Ledger addon "+v.Version+" installed: restart WoW to load it")
		a.cfg.FeedETag = "" // write the feed into the fresh copy
	}
}

func (a *App) installAddon(root string) error {
	resp, err := client.Get(a.cfg.Server + "/downloads/MarketLedger.zip")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return errors.New(resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 20<<20))
	if err != nil {
		return err
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return err
	}
	addons := addonsDir(root)
	if err := os.MkdirAll(addons, 0o755); err != nil {
		return err
	}
	// Unpack beside the old copy, then swap, so WoW never sees half an addon.
	tmp, err := os.MkdirTemp(addons, ".MarketLedger-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	for _, f := range zr.File {
		name := filepath.Clean(f.Name)
		if !strings.HasPrefix(name, "MarketLedger") || strings.Contains(name, "..") {
			continue
		}
		target := filepath.Join(tmp, name)
		if f.FileInfo().IsDir() {
			_ = os.MkdirAll(target, 0o755)
			continue
		}
		_ = os.MkdirAll(filepath.Dir(target), 0o755)
		rc, err := f.Open()
		if err != nil {
			return err
		}
		b, err := io.ReadAll(io.LimitReader(rc, 20<<20))
		rc.Close()
		if err != nil {
			return err
		}
		if err := os.WriteFile(target, b, 0o644); err != nil {
			return err
		}
	}
	dest := filepath.Join(addons, "MarketLedger")
	old := dest + ".old"
	_ = os.RemoveAll(old)
	if _, err := os.Stat(dest); err == nil {
		if err := os.Rename(dest, old); err != nil {
			return err
		}
	}
	if err := os.Rename(filepath.Join(tmp, "MarketLedger"), dest); err != nil {
		_ = os.Rename(old, dest)
		return err
	}
	_ = os.RemoveAll(old)
	return nil
}

// --- the price feed ------------------------------------------------------------------------------

// Download the merged prices and write them into the addon's Data/Feed.lua. WoW reads it the next
// time you log in or /reload.
func (a *App) refreshFeed() {
	req, _ := http.NewRequest("GET", a.cfg.Server+"/api/feed.lua", nil)
	if a.cfg.FeedETag != "" {
		req.Header.Set("If-None-Match", a.cfg.FeedETag)
	}
	resp, err := client.Do(req)
	if err != nil {
		a.setStatus("feed", "Can't reach the server: "+err.Error())
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode == 304 {
		a.setStatus("feed", "Guild prices up to date ("+time.Now().Format("15:04")+")")
		return
	}
	if resp.StatusCode != 200 {
		a.setStatus("feed", "Price download failed: "+resp.Status)
		return
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 50<<20))
	if err != nil || !bytes.Contains(body, []byte("MARKETLEDGER_FEED")) {
		a.setStatus("feed", "Price download was incomplete")
		return
	}
	wrote := 0
	for _, root := range a.roots() {
		dir := filepath.Join(addonsDir(root), "MarketLedger")
		if _, err := os.Stat(dir); err != nil {
			continue
		}
		if err := writeAtomic(filepath.Join(dir, "Data", "Feed.lua"), body); err != nil {
			a.log("writing feed in %s: %v", root, err)
			continue
		}
		wrote++
	}
	if wrote > 0 {
		a.cfg.FeedETag = resp.Header.Get("ETag")
		_ = a.saveConfig()
		a.setStatus("feed", "Guild prices updated "+time.Now().Format("Jan 2 15:04")+" (/reload in game)")
	}
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
