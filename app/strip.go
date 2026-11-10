package main

import (
	"bytes"
	"regexp"
)

// What the app sends from Auctionator's saved file: its price database and vendor price cache.
// Its settings, shopping lists, posting history and recent searches stay on your computer.
var auctionatorKeep = map[string]bool{
	"AUCTIONATOR_PRICE_DATABASE":     true,
	"AUCTIONATOR_VENDOR_PRICE_CACHE": true,
}

var topLevel = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]* = `)

// keepTopLevel returns only the named top-level variables of a WoW SavedVariables file. WoW writes
// each one as "NAME = value" at the start of a line and escapes newlines inside strings with a
// backslash, so a statement starts where a line begins (not after a backslash) with "IDENT = ".
func keepTopLevel(data []byte, keep map[string]bool) []byte {
	type stmt struct {
		at   int
		name string
	}
	var starts []stmt
	for i := 0; i < len(data); i++ {
		if i != 0 && !(data[i-1] == '\n' && (i < 2 || data[i-2] != '\\')) {
			continue
		}
		end := i + 80
		if end > len(data) {
			end = len(data)
		}
		if m := topLevel.Find(data[i:end]); m != nil {
			starts = append(starts, stmt{i, string(m[:len(m)-3])})
		}
	}
	var out bytes.Buffer
	for k, s := range starts {
		if !keep[s.name] {
			continue
		}
		end := len(data)
		if k+1 < len(starts) {
			end = starts[k+1].at
		}
		out.Write(data[s.at:end])
	}
	return out.Bytes()
}
