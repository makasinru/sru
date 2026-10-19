// sru-core — ядро SruNaZapret: Xray-core в отдельном процессе.
//
// Собирается чистым Go (CGO_ENABLED=0), поэтому для Android не нужен NDK.
//
// Десктоп (Windows/Linux, lib/core/vpn/vpn_engine.dart):
//
//	sru-core desktop <config.json> <assetDir>
//
// Печатает "started" после запуска Xray и работает, пока открыт stdin:
// когда приложение закрывается (даже аварийно), пайп закрывается и ядро
// выходит само — на Windows дочерние процессы иначе остаются висеть.
//
// Android: кладётся в jniLibs как libsrucore.so — система распаковывает его
// в nativeLibraryDir, откуда разрешено запускать исполняемые файлы.
// Протокол с приложением (SruVpnService.kt):
//
//	libsrucore.so run <socket> <config.json> <assetDir> [dns1,dns2]
//
// Ядро слушает unix-сокет <socket>. Приложение подключается и шлёт строку
// "start\n" вместе с TUN-дескриптором (SCM_RIGHTS). Ядро отвечает "ok\n" или
// "error:<текст>\n". Закрытие соединения = остановка ядра и выход процесса.
// Дескриптор нельзя унаследовать при запуске процесса из Java (ProcessBuilder
// закрывает все fd, кроме 0–2), поэтому он передаётся через сокет.
package main

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "version" {
		fmt.Println("Xray " + core.Version())
		return
	}
	if len(os.Args) == 4 && os.Args[1] == "desktop" {
		if err := runDesktop(os.Args[2], os.Args[3], os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "sru-core:", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) < 5 || os.Args[1] != "run" {
		fmt.Fprintln(os.Stderr, "usage: sru-core run <socket> <config.json> <assetDir> [dns1,dns2]")
		fmt.Fprintln(os.Stderr, "       sru-core desktop <config.json> <assetDir>")
		os.Exit(2)
	}
	var dns []string
	if len(os.Args) > 5 {
		dns = splitList(os.Args[5])
	}
	if err := serve(os.Args[2], os.Args[3], os.Args[4], dns); err != nil {
		fmt.Fprintln(os.Stderr, "sru-core:", err)
		os.Exit(1)
	}
}

func splitList(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// runDesktop запускает Xray и ждёт закрытия stdin (выход приложения) или сигнала.
func runDesktop(configPath, assetDir string, stdin io.Reader, stdout io.Writer) error {
	os.Setenv("XRAY_LOCATION_ASSET", assetDir)
	data, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	inst, err := core.StartInstance("json", data)
	if err != nil {
		return fmt.Errorf("xray: %w", err)
	}
	defer inst.Close()
	fmt.Fprintln(stdout, "started")

	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, stdin)
		close(done)
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	select {
	case <-done:
	case <-sig:
	}
	return nil
}
