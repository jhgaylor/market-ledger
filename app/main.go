// Market Ledger: the companion app for the Market Ledger addon.
//
// It sits in the menu bar (Mac) or system tray (Windows) and, in the background:
//   - finds WoW Forever and installs or updates the Market Ledger addon in it,
//   - uploads your Auctionator scans whenever the game saves them,
//   - downloads the guild's merged prices and writes them into the addon (Data/Feed.lua),
//     so in-game price checks use everyone's latest scans.
//
// It registers itself with the server on first run: no account or token to set up.
package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/ncruces/zenity"
)

var version = "dev" // set at build time: -ldflags "-X main.version=1.2.3"

const defaultServer = "https://goblin.trading"

// Earlier versions saved this address in their settings; it still works, but move them over.
const oldDefaultServer = "https://wow-market.apps.inevitable.fyi"

//go:embed icon.png
var iconPNG []byte

//go:embed icon.ico
var iconICO []byte

type Config struct {
	Server    string            `json:"server"`
	InstallID string            `json:"install_id"`
	Secret    string            `json:"secret"`
	Roots     []string          `json:"wow_roots,omitempty"` // folders the user picked
	FeedETag  string            `json:"feed_etag,omitempty"`
	Uploaded  map[string]string `json:"uploaded"` // file path -> sha256 last uploaded
	NoLogin   bool              `json:"no_start_at_login,omitempty"`
}

type App struct {
	mu       sync.Mutex
	cfg      Config
	dir      string
	logger   *log.Logger
	status   map[string]string
	items    map[string]*systray.MenuItem
	syncNow  chan struct{}
	lastRoot []string
	update   *systray.MenuItem
}

const lockAddr = "127.0.0.1:47613"

func main() {
	// "--quit" asks a running copy to exit (the Windows installer uses it before replacing the app).
	if len(os.Args) > 1 && os.Args[1] == "--quit" {
		if c, err := net.DialTimeout("tcp", lockAddr, 2*time.Second); err == nil {
			_, _ = c.Write([]byte("quit\n"))
			_ = c.Close()
			time.Sleep(1500 * time.Millisecond)
		}
		return
	}
	if handled := maybeSelfInstall(); handled {
		return
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.TempDir()
	}
	dir = filepath.Join(dir, "MarketLedger")
	if d := os.Getenv("MARKETLEDGER_CONFIG_DIR"); d != "" { // development
		dir = d
	}
	_ = os.MkdirAll(dir, 0o700)

	// One copy at a time: the second one just exits.
	// One copy at a time. If one's already running, ask it to quit and take over (so opening a
	// newer version, or an update, replaces the old one); a copy too old to answer keeps running.
	lock, err := net.Listen("tcp", lockAddr)
	if err != nil {
		if c, derr := net.DialTimeout("tcp", lockAddr, 2*time.Second); derr == nil {
			_, _ = c.Write([]byte("quit\n"))
			_ = c.Close()
		}
		for i := 0; i < 20 && err != nil; i++ {
			time.Sleep(250 * time.Millisecond)
			lock, err = net.Listen("tcp", lockAddr)
		}
		if err != nil {
			return
		}
	}
	defer lock.Close()
	go func() {
		for {
			c, err := lock.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 16)
			_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
			n, _ := c.Read(buf)
			_ = c.Close()
			if strings.HasPrefix(string(buf[:n]), "quit") {
				systray.Quit()
				return
			}
		}
	}()

	logFile, _ := os.OpenFile(filepath.Join(dir, "marketledger.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	a := &App{
		dir:     dir,
		logger:  log.New(logFile, "", log.LstdFlags),
		status:  map[string]string{},
		items:   map[string]*systray.MenuItem{},
		syncNow: make(chan struct{}, 1),
	}
	a.loadConfig()
	a.log("Market Ledger %s starting", version)
	cleanupUpdateLeftovers()
	systray.Run(a.onReady, func() { a.log("quit") })
}

func (a *App) log(format string, args ...any) { a.logger.Printf(format, args...) }

func (a *App) loadConfig() {
	b, err := os.ReadFile(filepath.Join(a.dir, "config.json"))
	if err == nil {
		_ = json.Unmarshal(b, &a.cfg)
	}
	if a.cfg.Server == "" || a.cfg.Server == oldDefaultServer {
		a.cfg.Server = defaultServer
	}
	if s := os.Getenv("MARKETLEDGER_SERVER"); s != "" { // development
		a.cfg.Server = s
	}
	if a.cfg.Uploaded == nil {
		a.cfg.Uploaded = map[string]string{}
	}
}

func (a *App) saveConfig() error {
	b, _ := json.MarshalIndent(a.cfg, "", "  ")
	return writeAtomic(filepath.Join(a.dir, "config.json"), b)
}

func (a *App) roots() []string {
	var r []string
	if env := os.Getenv("MARKETLEDGER_WOW_ROOTS"); env != "" { // development: only these
		for _, p := range filepath.SplitList(env) {
			if isForeverRoot(p) {
				r = append(r, p)
			}
		}
	} else {
		r = discoverRoots(a.cfg.Roots)
	}
	a.mu.Lock()
	a.lastRoot = r
	a.mu.Unlock()
	return r
}

// --- the menu ------------------------------------------------------------------------------------

func (a *App) onReady() {
	if runtime.GOOS == "windows" {
		systray.SetIcon(iconICO)
	} else {
		systray.SetIcon(iconPNG)
	}
	systray.SetTooltip("Market Ledger")

	for _, key := range []string{"wow", "addon", "upload", "feed"} {
		it := systray.AddMenuItem("…", "")
		it.Disable()
		a.items[key] = it
	}
	systray.AddSeparator()
	a.update = systray.AddMenuItem("Update available", "Download and install the newer Market Ledger app")
	a.update.Hide()
	syncItem := systray.AddMenuItem("Sync now", "Upload new scans and download the latest prices")
	siteItem := systray.AddMenuItem("Open the Market Ledger website", "")
	mineItem := systray.AddMenuItem("See my uploads", "Check that your scans reached the website")
	folderItem := systray.AddMenuItem("Choose WoW folder…", "If it didn't find World of Warcraft by itself")
	loginItem := systray.AddMenuItemCheckbox("Start at login", "", !a.cfg.NoLogin)
	logItem := systray.AddMenuItem("Show log", "")
	systray.AddSeparator()
	about := systray.AddMenuItem("Market Ledger "+version, "")
	about.Disable()
	quitItem := systray.AddMenuItem("Quit", "")

	if err := setStartAtLogin(!a.cfg.NoLogin); err != nil {
		a.log("start at login: %v", err)
	}

	go func() {
		for {
			select {
			case <-a.update.ClickedCh:
				go a.updateNow()
			case <-syncItem.ClickedCh:
				a.kick()
			case <-siteItem.ClickedCh:
				openURL(a.cfg.Server)
			case <-mineItem.ClickedCh:
				openURL(a.cfg.Server + "/#/activity?source=install:" + a.cfg.InstallID)
			case <-folderItem.ClickedCh:
				a.chooseFolder()
			case <-loginItem.ClickedCh:
				a.cfg.NoLogin = !a.cfg.NoLogin
				if a.cfg.NoLogin {
					loginItem.Uncheck()
				} else {
					loginItem.Check()
				}
				_ = a.saveConfig()
				if err := setStartAtLogin(!a.cfg.NoLogin); err != nil {
					a.log("start at login: %v", err)
				}
			case <-logItem.ClickedCh:
				openURL("file://" + filepath.Join(a.dir, "marketledger.log"))
			case <-quitItem.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
	go a.loop()
}

func (a *App) setStatus(key, text string) {
	a.mu.Lock()
	a.status[key] = text
	it := a.items[key]
	a.mu.Unlock()
	if it != nil {
		it.SetTitle(text)
	}
}

func (a *App) kick() {
	select {
	case a.syncNow <- struct{}{}:
	default:
	}
}

func (a *App) chooseFolder() {
	start := "/Applications"
	if runtime.GOOS == "windows" {
		start = `C:\Program Files (x86)`
	}
	dir, err := zenity.SelectFile(zenity.Title("Choose your World of Warcraft folder"), zenity.Directory(), zenity.Filename(start))
	if err != nil || dir == "" {
		return
	}
	// Accept the WoW folder itself, or its _forever_ folder.
	if filepath.Base(dir) == flavor {
		dir = filepath.Dir(dir)
	}
	if !isForeverRoot(dir) {
		_ = zenity.Error("That folder doesn't contain WoW Forever (no _forever_ folder inside). Pick the \"World of Warcraft\" folder.",
			zenity.Title("Market Ledger"))
		return
	}
	a.cfg.Roots = append(a.cfg.Roots, dir)
	_ = a.saveConfig()
	a.kick()
}

// --- the background loop -------------------------------------------------------------------------

func (a *App) loop() {
	lastFeed, lastAddon := time.Time{}, time.Time{}
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		roots := a.roots()
		if len(roots) == 0 {
			a.setStatus("wow", "WoW Forever not found: use \"Choose WoW folder…\"")
		} else {
			a.setStatus("wow", fmt.Sprintf("WoW Forever: %s", roots[0]))
			if err := a.register(); err != nil {
				a.setStatus("upload", "Can't reach the server: "+err.Error())
			} else {
				if time.Since(lastAddon) > 6*time.Hour {
					a.ensureAddon()
					a.checkAppUpdate()
					lastAddon = time.Now()
				}
				a.uploadChanged()
				if time.Since(lastFeed) > 10*time.Minute {
					a.refreshFeed()
					lastFeed = time.Now()
				}
			}
		}
		select {
		case <-tick.C:
		case <-a.syncNow:
			lastFeed, lastAddon = time.Time{}, time.Time{}
		}
	}
}

func openURL(u string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", u)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	_ = cmd.Start()
}

// Show "Update available" when the server has a newer build of this app for this platform.
func (a *App) checkAppUpdate() {
	name := "MarketLedger-mac.zip"
	if runtime.GOOS == "windows" {
		name = "MarketLedger-Setup.exe"
	}
	resp, err := client.Get(a.cfg.Server + "/downloads/app/releases.json")
	if err != nil {
		return
	}
	defer resp.Body.Close()
	var rels []struct{ Name, Version string }
	if json.NewDecoder(resp.Body).Decode(&rels) != nil {
		return
	}
	for _, r := range rels {
		if r.Name == name && version != "dev" && newer(r.Version, version) {
			a.update.SetTitle("Update to " + r.Version + " now")
			a.update.Show()
			if os.Getenv("MARKETLEDGER_TEST_UPDATE") == "1" { // development: exercise the updater
				go a.updateNow()
			}
			return
		}
	}
	a.update.Hide()
}

// newer reports whether dotted version x is greater than y ("0.10.0" > "0.9.2").
func newer(x, y string) bool {
	px, py := strings.Split(x, "."), strings.Split(y, ".")
	for i := 0; i < len(px) || i < len(py); i++ {
		var a, b int
		if i < len(px) {
			a, _ = strconv.Atoi(px[i])
		}
		if i < len(py) {
			b, _ = strconv.Atoi(py[i])
		}
		if a != b {
			return a > b
		}
	}
	return false
}
