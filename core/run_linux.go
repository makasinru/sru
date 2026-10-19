//go:build linux

package main

// Режим run (Android): TUN-дескриптор приходит по unix-сокету (SCM_RIGHTS).

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

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"github.com/xtls/xray-core/core"
	"golang.org/x/sys/unix"
)

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
	inst, err := startEngine(configPath, fd)
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

// startEngine запускает Xray (JSON-конфиг) или AmneziaWG (.conf) на TUN.
func startEngine(configPath string, tunFd int) (interface{ Close() error }, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}
	if isAwgConf(data) {
		return startAwgOnFd(data, tunFd)
	}
	return startXray(configPath, tunFd)
}

type awgInstance struct{ close func() }

func (a awgInstance) Close() error {
	a.close()
	return nil
}

func startAwgOnFd(conf []byte, tunFd int) (interface{ Close() error }, error) {
	cfg, err := parseAwgConf(string(conf), defaultResolve)
	if err != nil {
		return nil, err
	}
	tunDev, _, err := tun.CreateUnmonitoredTUNFromFD(tunFd)
	if err != nil {
		return nil, fmt.Errorf("TUN: %w", err)
	}
	dev, err := startAwgDevice(tunDev, conn.NewDefaultBind(), cfg)
	if err != nil {
		return nil, err
	}
	if err := waitHandshake(dev, 12*time.Second); err != nil {
		dev.Close()
		return nil, err
	}
	return awgInstance{close: dev.Close}, nil
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
