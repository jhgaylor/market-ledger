//go:build !darwin && !windows

package main

func maybeSelfInstall() bool        { return false }
func setStartAtLogin(on bool) error { return nil }
