package main

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDesktopModeStopsWhenStdinCloses(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.json")
	os.WriteFile(cfg, []byte(`{
	  "inbounds": [{"listen": "127.0.0.1", "port": 0, "protocol": "socks", "settings": {"udp": true}}],
	  "outbounds": [{"protocol": "freedom"}]
	}`), 0o600)
	stdinR, stdinW := io.Pipe()
	outR, outW := io.Pipe()
	errc := make(chan error, 1)
	go func() { errc <- runDesktop(cfg, dir, stdinR, outW) }()
	line, err := bufio.NewReader(outR).ReadString('\n')
	if err != nil || strings.TrimSpace(line) != "started" {
		t.Fatalf("ожидалось started, получено %q (%v)", line, err)
	}
	stdinW.Close() // приложение закрылось
	select {
	case err := <-errc:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("ядро не завершилось после закрытия stdin")
	}
}
