//go:build !windows

package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Создаёт TUN-интерфейс так же, как VpnService.Builder.establish() (IFF_TUN|IFF_NO_PI).
func openTun(t *testing.T, name string) int {
	fd, err := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		t.Skip("нет /dev/net/tun:", err)
	}
	ifr, _ := unix.NewIfreq(name)
	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(fd, unix.TUNSETIFF, ifr); err != nil {
		unix.Close(fd)
		t.Skip("нет прав на создание TUN:", err)
	}
	return fd
}

func TestStartWithPassedTunFd(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "core.sock")
	cfg := filepath.Join(dir, "config.json")
	os.WriteFile(cfg, []byte(`{
	  "log": {"loglevel": "warning"},
	  "inbounds": [{"tag": "tun", "port": 0, "protocol": "tun", "settings": {"name": "srutest0", "MTU": 1500}}],
	  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
	}`), 0o600)
	tunFd := openTun(t, "srutest0")
	defer unix.Close(tunFd)

	errc := make(chan error, 1)
	go func() { errc <- serve(sock, cfg, dir, []string{"8.8.8.8"}) }()

	var conn *net.UnixConn
	for i := 0; i < 50; i++ {
		c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: sock, Net: "unix"})
		if err == nil {
			conn = c
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if conn == nil {
		t.Fatal("ядро не открыло сокет")
	}
	if _, _, err := conn.WriteMsgUnix([]byte("start\n"), unix.UnixRights(tunFd), nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil || strings.TrimSpace(line) != "ok" {
		t.Fatalf("ответ ядра: %q, %v", line, err)
	}
	conn.Close() // приложение отключилось → ядро останавливается
	select {
	case err := <-errc:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("ядро не остановилось после закрытия сокета")
	}
}

func TestRejectsMissingFd(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "core.sock")
	errc := make(chan error, 1)
	go func() { errc <- serve(sock, filepath.Join(dir, "none.json"), dir, nil) }()
	var conn net.Conn
	for i := 0; i < 50 && conn == nil; i++ {
		conn, _ = net.Dial("unix", sock)
		time.Sleep(50 * time.Millisecond)
	}
	if conn == nil {
		t.Fatal("ядро не открыло сокет")
	}
	conn.Write([]byte("start\n"))
	line, _ := bufio.NewReader(conn).ReadString('\n')
	if !strings.HasPrefix(line, "error:") {
		t.Fatalf("ожидалась ошибка, получено %q", line)
	}
	if <-errc == nil {
		t.Fatal("serve должен вернуть ошибку")
	}
}
