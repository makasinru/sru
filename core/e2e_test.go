//go:build linux

package main

import (
	"bufio"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// TestE2ETrafficThroughTun повторяет путь пакетов на Android: TUN (как от
// VpnService.Builder) → дескриптор по сокету → Xray tun-inbound → прокси → сайт.
// Запуск (нужны root, iproute2, setpriv и рабочий сервер из конфига):
//
//	SRU_E2E_CONFIG=client.json SRU_E2E_URL=https://example.com SRU_E2E_ROUTE=0.0.0.0/0 \
//	  SRU_E2E_ASSETS=../app/src/main/assets/geo go test -ldflags=-checklinkname=0 -run E2E -v
//
// SRU_E2E_CACERT — доп. корневой сертификат для curl (песочницы с TLS-перехватом),
// SRU_E2E_DEBUG=1 — вывести адреса и маршруты перед запросом.
//
// В конфиге tun-inbound должен называться sru0 (так его называет XrayConfigBuilder).
func TestE2ETrafficThroughTun(t *testing.T) {
	cfg, url, route := os.Getenv("SRU_E2E_CONFIG"), os.Getenv("SRU_E2E_URL"), os.Getenv("SRU_E2E_ROUTE")
	if cfg == "" || url == "" || route == "" {
		t.Skip("нет SRU_E2E_CONFIG / SRU_E2E_URL / SRU_E2E_ROUTE")
	}
	tunFd := openTun(t, "sru0")
	defer unix.Close(tunFd)
	for _, args := range [][]string{
		{"addr", "add", "172.19.0.1/30", "dev", "sru0"},
		{"link", "set", "sru0", "mtu", "1500", "up"},
		// Маршрутизация по UID, как в Android: в TUN идёт только трафик
		// пользователя nobody (65534), от его имени запускается curl. Соединения
		// ядра и сервера (если он на этой же машине) идут мимо VPN — на Android
		// ту же роль играет addDisallowedApplication.
		{"rule", "add", "uidrange", "65534-65534", "lookup", "1919"},
		{"route", "add", route, "dev", "sru0", "table", "1919"},
	} {
		if out, err := exec.Command("ip", args...).CombinedOutput(); err != nil {
			t.Fatalf("ip %v: %v %s", args, err, out)
		}
	}

	defer exec.Command("ip", "rule", "del", "uidrange", "65534-65534", "lookup", "1919").Run()

	dir := t.TempDir()
	sock := filepath.Join(dir, "core.sock")
	errc := make(chan error, 1)
	go func() { errc <- serve(sock, cfg, os.Getenv("SRU_E2E_ASSETS"), nil) }()
	var conn *net.UnixConn
	for i := 0; i < 100 && conn == nil; i++ {
		conn, _ = net.DialUnix("unix", nil, &net.UnixAddr{Name: sock, Net: "unix"})
		time.Sleep(50 * time.Millisecond)
	}
	if conn == nil {
		t.Fatal("ядро не открыло сокет")
	}
	defer conn.Close()
	if _, _, err := conn.WriteMsgUnix([]byte("start\n"), unix.UnixRights(tunFd), nil); err != nil {
		t.Fatal(err)
	}
	line, _ := bufio.NewReader(conn).ReadString('\n')
	if strings.TrimSpace(line) != "ok" {
		t.Fatalf("ответ ядра: %q", line)
	}

	if os.Getenv("SRU_E2E_DEBUG") != "" {
		dbg, _ := exec.Command("sh", "-c", "ip addr show sru0; ip rule; ip route show table all | grep sru0").CombinedOutput()
		t.Logf("сеть:\n%s", dbg)
	}
	args := []string{"--reuid=65534", "--regid=65534", "--clear-groups",
		"curl", "--noproxy", "*", "-sS", "-m", "20", "-o", "/dev/null", "-w", "%{http_code} %{remote_ip}"}
	if ca := os.Getenv("SRU_E2E_CACERT"); ca != "" { // доп. корневой сертификат (песочницы с TLS-перехватом)
		args = append(args, "--cacert", ca)
	}
	cmd := exec.Command("setpriv", append(args, url)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH")}
	out, err := cmd.CombinedOutput()
	t.Logf("curl через TUN: %s", out)
	if err != nil || !strings.HasPrefix(string(out), "200") {
		t.Fatalf("трафик через TUN не прошёл: %v %s", err, out)
	}
}
