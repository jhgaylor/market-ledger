package main

// Finding WoW Forever on this computer.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
)

const flavor = "_forever_"

// A WoW install root is the "World of Warcraft" folder; Forever lives in its _forever_ subfolder.
func isForeverRoot(root string) bool {
	st, err := os.Stat(filepath.Join(root, flavor, "Interface"))
	return err == nil && st.IsDir()
}

// Candidate roots: Battle.net's default install folder, the usual places, and anything saved.
func discoverRoots(saved []string) []string {
	home, _ := os.UserHomeDir()
	var cands []string
	cands = append(cands, saved...)
	if p := battleNetDefaultPath(); p != "" {
		cands = append(cands, filepath.Join(p, "World of Warcraft"))
	}
	switch runtime.GOOS {
	case "darwin":
		cands = append(cands,
			"/Applications/World of Warcraft",
			filepath.Join(home, "Applications", "World of Warcraft"),
			filepath.Join(home, "Documents", "bnet", "World of Warcraft"),
			filepath.Join(home, "Games", "World of Warcraft"),
		)
	case "windows":
		for _, drive := range []string{"C:", "D:", "E:", "F:"} {
			cands = append(cands,
				drive+`\Program Files (x86)\World of Warcraft`,
				drive+`\Program Files\World of Warcraft`,
				drive+`\World of Warcraft`,
				drive+`\Games\World of Warcraft`,
				drive+`\Battle.net\World of Warcraft`,
			)
		}
	}
	seen := map[string]bool{}
	var out []string
	for _, c := range cands {
		c = filepath.Clean(c)
		if seen[c] || !isForeverRoot(c) {
			continue
		}
		seen[c] = true
		out = append(out, c)
	}
	return out
}

// Battle.net keeps its default install folder in Battle.net.config (JSON).
func battleNetDefaultPath() string {
	var cfg string
	switch runtime.GOOS {
	case "darwin":
		home, _ := os.UserHomeDir()
		cfg = filepath.Join(home, "Library", "Application Support", "Battle.net", "Battle.net.config")
	case "windows":
		cfg = filepath.Join(os.Getenv("APPDATA"), "Battle.net", "Battle.net.config")
	default:
		return ""
	}
	b, err := os.ReadFile(cfg)
	if err != nil {
		return ""
	}
	var v struct {
		Client struct {
			Install struct {
				DefaultInstallPath string
			}
		}
	}
	if json.Unmarshal(b, &v) != nil {
		return ""
	}
	return v.Client.Install.DefaultInstallPath
}

func addonsDir(root string) string { return filepath.Join(root, flavor, "Interface", "AddOns") }

// Every account's SavedVariables folder under a root.
func savedVariablesDirs(root string) []string {
	dirs, _ := filepath.Glob(filepath.Join(root, flavor, "WTF", "Account", "*", "SavedVariables"))
	sort.Strings(dirs)
	return dirs
}
