// sru-core — ядро VPN для Android: Xray-core в отдельном процессе.
//
// Собирается чистым Go (CGO_ENABLED=0), поэтому не нужен Android NDK.
// Кладётся в jniLibs как libsrucore.so — Android распаковывает его в
// nativeLibraryDir, откуда разрешено запускать исполняемые файлы.
//
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
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
	"golang.org/x/sys/unix"
)

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "version" {
		fmt.Println("Xray " + core.Version())
		return
	}
	if len(os.Args) < 5 || os.Args[1] != "run" {
		fmt.Fprintln(os.Stderr, "usage: sru-core run <socket> <config.json> <assetDir> [dns1,dns2]")
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

// useResolvers направляет системный резолвер Go на DNS-серверы сети.
// В Android нет /etc/resolv.conf, и без этого чистый Go ходит в 127.0.0.1:53.
func useResolvers(servers []string) {
	if len(servers) == 0 {
		servers = []string{"1.1.1.1", "8.8.8.8"}
	}
	var d net.Dialer
	i := 0
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var lastErr error
			for range servers {
				s := servers[i%len(servers)]
				i++
				conn, err := d.DialContext(ctx, network, net.JoinHostPort(s, "53"))
				if err == nil {
					return conn, nil
				}
				lastErr = err
			}
			return nil, lastErr
		},
	}
}

func serve(socketPath, configPath, assetDir string, dns []string) error {
	os.Setenv("XRAY_LOCATION_ASSET", assetDir)
	useResolvers(dns)

	_ = os.Remove(socketPath)
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		return err
	}
	defer os.Remove(socketPath)
	defer ln.Close()

	_ = ln.SetDeadline(time.Now().Add(30 * time.Second))
	conn, err := ln.AcceptUnix()
	if err != nil {
		return fmt.Errorf("приложение не подключилось: %w", err)
	}
	defer conn.Close()

	fd, err := receiveStart(conn)
	if err != nil {
		reply(conn, "error:"+err.Error())
		return err
	}
	inst, err := startXray(configPath, fd)
	if err != nil {
		reply(conn, "error:"+err.Error())
		return err
	}
	defer inst.Close()
	reply(conn, "ok")

	// Ждём закрытия соединения со стороны приложения или сигнала.
	done := make(chan struct{})
	go func() {
		_, _ = bufio.NewReader(conn).ReadString('\n')
		close(done)
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	select {
	case <-done:
	case <-sig:
	}
	return nil
}

func reply(conn *net.UnixConn, msg string) {
	_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, _ = conn.Write([]byte(msg + "\n"))
}

// receiveStart читает "start\n" и TUN-дескриптор из SCM_RIGHTS.
func receiveStart(conn *net.UnixConn) (int, error) {
	_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	defer conn.SetReadDeadline(time.Time{})
	buf := make([]byte, 64)
	oob := make([]byte, unix.CmsgSpace(4*4))
	n, oobn, _, _, err := conn.ReadMsgUnix(buf, oob)
	if err != nil {
		return -1, err
	}
	if strings.TrimSpace(string(buf[:n])) != "start" {
		return -1, fmt.Errorf("неожиданная команда %q", buf[:n])
	}
	msgs, err := unix.ParseSocketControlMessage(oob[:oobn])
	if err != nil {
		return -1, err
	}
	for _, m := range msgs {
		fds, err := unix.ParseUnixRights(&m)
		if err == nil && len(fds) > 0 {
			for _, extra := range fds[1:] {
				unix.Close(extra)
			}
			return fds[0], nil
		}
	}
	return -1, errors.New("не получен TUN-дескриптор")
}

func startXray(configPath string, tunFd int) (*core.Instance, error) {
	// proxy/tun на Android берёт дескриптор из переменной xray.tun.fd.
	os.Setenv("xray.tun.fd", strconv.Itoa(tunFd))
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}
	inst, err := core.StartInstance("json", data)
	if err != nil {
		return nil, fmt.Errorf("xray: %w", err)
	}
	return inst, nil
}
