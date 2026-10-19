//go:build !windows

package main

import (
	"errors"
	"io"
)

// На Linux-десктопе AmneziaWG не поддерживается (на Android — режим run).
func runDesktopAwg(conf []byte, stdin io.Reader, stdout io.Writer) error {
	return errors.New("AmneziaWG на этой платформе поддерживается только в Android и Windows")
}
