//go:build !linux

package main

import "errors"

// Режим run (передача TUN-дескриптора) нужен только Android (GOOS=android — это linux).
func serve(socketPath, configPath, assetDir string, dns []string) error {
	return errors.New("режим run поддерживается только на Android/Linux, используйте desktop")
}
