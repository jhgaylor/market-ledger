package main

import (
	"bytes"
	"os"
	"testing"
)

func TestKeepTopLevel(t *testing.T) {
	in := []byte("A = {\n[\"x\"] = \"line\\\nB = not a statement\",\n}\nB = 2\nC = {\n}\n")
	got := keepTopLevel(in, map[string]bool{"A": true, "C": true})
	want := []byte("A = {\n[\"x\"] = \"line\\\nB = not a statement\",\n}\nC = {\n}\n")
	if !bytes.Equal(got, want) {
		t.Fatalf("got %q\nwant %q", got, want)
	}
}

// With a real file: MARKETLEDGER_TEST_AUCTIONATOR=/path/to/Auctionator.lua go test
func TestRealAuctionator(t *testing.T) {
	p := os.Getenv("MARKETLEDGER_TEST_AUCTIONATOR")
	if p == "" {
		t.Skip("no file")
	}
	data, _ := os.ReadFile(p)
	out := keepTopLevel(data, auctionatorKeep)
	for _, gone := range []string{"AUCTIONATOR_POSTING_HISTORY", "AUCTIONATOR_SHOPPING_LISTS", "AUCTIONATOR_CONFIG"} {
		if bytes.Contains(out, []byte("\n"+gone+" = ")) || bytes.HasPrefix(out, []byte(gone)) {
			t.Errorf("%s still present", gone)
		}
	}
	if !bytes.Contains(out, []byte("AUCTIONATOR_PRICE_DATABASE = ")) {
		t.Error("price database missing")
	}
	t.Logf("%d -> %d bytes", len(data), len(out))
}
