//go:build linux

package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"golang.org/x/crypto/curve25519"
)

func keypair(t *testing.T) (priv, pub []byte) {
	priv = make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		t.Fatal(err)
	}
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return priv, pub
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// Такой .conf отдаёт 3x-ui (internal/sub/service.go, amneziaWGConfigText).
const sampleConf = `[Interface]
PrivateKey = %s
Address = 10.8.1.2/32, fd00::2/128
DNS = 8.8.8.8, 8.8.4.4
MTU = 1376
Jc = 4
Jmin = 10
Jmax = 50
S1 = 30
S2 = 45
S3 = 10
S4 = 5
H1 = 123456
H2 = 234567
H3 = 345678
H4 = 456789
RandomTrailers = on
HeaderProtectionKey = Gi1HbW0gDaW9i9vo3xpflK6+O/Ie7LATKpJwOsKpQqc=
ContentPaddingAddition = 22-36
I1 = <r 251>

# Мой сервер
[Peer]
PublicKey = %s
PresharedKey = %s
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = %s
PersistentKeepalive = 25`

func TestParseAwgConf(t *testing.T) {
	priv, _ := keypair(t)
	_, pub := keypair(t)
	psk, _ := keypair(t)
	cfg, err := parseAwgConf(fmt.Sprintf(sampleConf, b64(priv), b64(pub), b64(psk), "vpn.example:51820"),
		func(host string) (netip.Addr, error) { return netip.MustParseAddr("203.0.113.5"), nil })
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"jc=4\n", "jmin=10\n", "s3=10\n", "s4=5\n", "h1=123456\n", "random_trailers=true\n",
		"replace_peers=true\n", "endpoint=203.0.113.5:51820\n", "allowed_ip=0.0.0.0/0\n", "allowed_ip=::/0\n",
		"persistent_keepalive_interval=25\n", "content_padding_addition=22-36\n", "i1=<r 251>\n",
		"header_protection_key=1a2d476d6d200da5bd8bdbe8df1a5f94aebe3bf21eecb0132a92703ac2a942a7\n",
	} {
		if !strings.Contains(cfg.UAPI, want) {
			t.Errorf("в UAPI нет %q:\n%s", want, cfg.UAPI)
		}
	}
	if strings.Index(cfg.UAPI, "jc=") > strings.Index(cfg.UAPI, "public_key=") {
		t.Error("параметры интерфейса должны идти до пира")
	}
	if cfg.MTU != 1376 || len(cfg.Addresses) != 2 || len(cfg.DNS) != 2 || len(cfg.Routes) != 2 {
		t.Errorf("интерфейс разобран неверно: %+v", cfg)
	}
	noKeepalive := strings.Replace(fmt.Sprintf(sampleConf, b64(priv), b64(pub), b64(psk), "1.2.3.4:1"), "PersistentKeepalive = 25", "", 1)
	cfg2, err := parseAwgConf(noKeepalive, nil)
	if err != nil || !strings.Contains(cfg2.UAPI, "persistent_keepalive_interval=25\n") {
		t.Errorf("без PersistentKeepalive должен ставиться 25 с (иначе нет рукопожатия до первого пакета): %v", err)
	}
	if _, err := parseAwgConf("[Interface]\nAddress = 10.0.0.2/32\n", nil); err == nil {
		t.Error("конфиг без ключа должен отклоняться")
	}
}

// TestAwgTrafficThroughTun: сервер AmneziaWG (gVisor) с HTTP внутри туннеля,
// клиент — тем же путём, что на Android: TUN-дескриптор → startAwgOnFd.
func TestAwgTrafficThroughTun(t *testing.T) {
	if _, err := exec.LookPath("ip"); err != nil {
		t.Skip("нет iproute2")
	}
	sPriv, sPub := keypair(t)
	cPriv, cPub := keypair(t)

	// Сервер.
	sTun, sNet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.8.1.1")}, nil, 1376)
	if err != nil {
		t.Fatal(err)
	}
	server, err := startAwgDevice(sTun, conn.NewDefaultBind(), &awgConfig{UAPI: fmt.Sprintf(
		"private_key=%x\nlisten_port=51999\njc=4\njmin=10\njmax=50\ns1=30\ns2=45\ns3=10\ns4=5\n"+
			"h1=123456\nh2=234567\nh3=345678\nh4=456789\nrandom_trailers=true\n"+
			"replace_peers=true\npublic_key=%x\nallowed_ip=10.8.1.2/32\n", sPriv, cPub)})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	ln, err := sNet.ListenTCP(&net.TCPAddr{IP: net.ParseIP("10.8.1.1"), Port: 80})
	if err != nil {
		t.Fatal(err)
	}
	go http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, "через AmneziaWG") }))

	// Клиент.
	fd := openTun(t, "awgtest0")
	for _, args := range [][]string{
		{"addr", "add", "10.8.1.2/32", "dev", "awgtest0"},
		{"link", "set", "awgtest0", "mtu", "1376", "up"},
		{"route", "add", "10.8.1.1/32", "dev", "awgtest0"},
	} {
		if out, err := exec.Command("ip", args...).CombinedOutput(); err != nil {
			t.Fatalf("ip %v: %v %s", args, err, out)
		}
	}
	conf := fmt.Sprintf(sampleConf, b64(cPriv), b64(sPub), b64(make([]byte, 32)), "127.0.0.1:51999")
	conf = strings.Replace(conf, "PresharedKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n", "", 1)
	conf = strings.Replace(conf, "AllowedIPs = 0.0.0.0/0, ::/0", "AllowedIPs = 10.8.1.1/32", 1)
	start := time.Now()
	client, err := startAwgOnFd([]byte(conf), fd)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	t.Logf("рукопожатие за %v", time.Since(start).Round(time.Millisecond))

	out, err := exec.Command("curl", "--noproxy", "*", "-sS", "-m", "10", "http://10.8.1.1/").CombinedOutput()
	if err != nil || string(out) != "через AmneziaWG" {
		t.Fatalf("HTTP через туннель: %v %q", err, out)
	}
}

func TestAwgWrongServerKeyFailsHandshake(t *testing.T) {
	if _, err := exec.LookPath("ip"); err != nil {
		t.Skip("нет iproute2")
	}
	cPriv, _ := keypair(t)
	_, wrong := keypair(t)
	fd := openTun(t, "awgtest1")
	conf := fmt.Sprintf(sampleConf, b64(cPriv), b64(wrong), b64(wrong), "127.0.0.1:51998")
	if _, err := startAwgOnFd([]byte(conf), fd); err == nil || !strings.Contains(err.Error(), "рукопожатия") {
		t.Fatalf("ожидалась ошибка рукопожатия, получено %v", err)
	}
}

// TestAwgLive: настоящий сервер AmneziaWG (например, inbound 3x-ui) по ключу vpn://
// или .conf из файла SRU_AWG_CONF. Весь трафик пользователя nobody идёт в туннель
// (маршрутизация по UID, как на Android), включая DNS.
func TestAwgLive(t *testing.T) {
	path, url := os.Getenv("SRU_AWG_CONF"), os.Getenv("SRU_E2E_URL")
	if path == "" || url == "" {
		t.Skip("нет SRU_AWG_CONF / SRU_E2E_URL")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	conf := strings.TrimSpace(string(raw))
	if b, ok := strings.CutPrefix(conf, "vpn://"); ok {
		dec, err := base64.RawURLEncoding.DecodeString(b)
		if err != nil {
			t.Fatal(err)
		}
		conf = string(dec)
	}
	fd := openTun(t, "awglive0")
	cfg, err := parseAwgConf(conf, defaultResolve)
	if err != nil {
		t.Fatal(err)
	}
	cmds := [][]string{{"link", "set", "awglive0", "mtu", fmt.Sprint(cfg.MTU), "up"}}
	for _, a := range cfg.Addresses {
		if a.Addr().Is4() {
			cmds = append(cmds, []string{"addr", "add", a.String(), "dev", "awglive0"})
		}
	}
	cmds = append(cmds,
		[]string{"rule", "add", "uidrange", "65534-65534", "lookup", "1920"},
		[]string{"route", "add", "0.0.0.0/0", "dev", "awglive0", "table", "1920"})
	for _, args := range cmds {
		if out, err := exec.Command("ip", args...).CombinedOutput(); err != nil {
			t.Fatalf("ip %v: %v %s", args, err, out)
		}
	}
	defer exec.Command("ip", "rule", "del", "uidrange", "65534-65534", "lookup", "1920").Run()

	start := time.Now()
	client, err := startAwgOnFd([]byte(conf), fd)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	t.Logf("рукопожатие с сервером за %v", time.Since(start).Round(time.Millisecond))

	args := []string{"--reuid=65534", "--regid=65534", "--clear-groups", "curl", "--noproxy", "*", "-sS", "-m", "20",
		"-o", "/dev/null", "-w", "%{http_code} %{remote_ip}"}
	if ca := os.Getenv("SRU_E2E_CACERT"); ca != "" {
		args = append(args, "--cacert", ca)
	}
	cmd := exec.Command("setpriv", append(args, url)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH")}
	out, err := cmd.CombinedOutput()
	t.Logf("curl через AmneziaWG: %s", out)
	if err != nil || !strings.HasPrefix(string(out), "200") {
		t.Fatalf("трафик через AmneziaWG не прошёл: %v %s", err, out)
	}
}
