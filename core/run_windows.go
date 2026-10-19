//go:build windows

package main

import "errors"

// Режим run (передача TUN-дескриптора) нужен только Android.
func serve(socketPath, configPath, assetDir string, dns []string) error {
	return errors.New("режим run не поддерживается в Windows, используйте desktop")
}
