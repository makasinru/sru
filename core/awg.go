package main

// AmneziaWG: клиентский .conf (формат wg-quick с полями AmneziaWG 1.x/2.0)
// → UAPI amneziawg-go. Адреса, DNS и MTU интерфейса настраивает тот, кто
// создаёт TUN (VpnService на Android, winipcfg на Windows).

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
)

type awgConfig struct {
	UAPI      string
	Addresses []netip.Prefix
	DNS       []netip.Addr
	MTU       int
	Routes    []netip.Prefix // AllowedIPs всех пиров
	Endpoints []netip.AddrPort
}

func isAwgConf(data []byte) bool {
	return strings.Contains(string(data), "[Interface]")
}

// Ключи [Interface], которые amneziawg-go принимает как есть (после snake_case).
var awgInterfaceKeys = map[string]bool{
	"listen_port": true, "jc": true, "jmin": true, "jmax": true,
	"s1": true, "s2": true, "s3": true, "s4": true,
	"h1": true, "h2": true, "h3": true, "h4": true,
	"i1": true, "i2": true, "i3": true, "i4": true, "i5": true,
	"header_protection_key": true, "content_padding_addition": true,
	"rekey_after_time": true, "rekey_timeout": true, "reject_after_time": true,
	"keepalive_timeout": true, "max_handshake_attempts": true,
	"random_trailers": true, "disable_cookies": true,
}

// snake превращает "HeaderProtectionKey" в "header_protection_key", "Jmin" в "jmin".
func snake(s string) string {
	var b strings.Builder
	for i, r := range s {
		if unicode.IsUpper(r) && i > 0 && !unicode.IsUpper(rune(s[i-1])) {
			b.WriteByte('_')
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return b.String()
}

func keyHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(raw) != 32 {
		return "", fmt.Errorf("некорректный ключ %q", b64)
	}
	return hex.EncodeToString(raw), nil
}

// parseAwgConf разбирает .conf. resolve нужен для Endpoint с доменом:
// UAPI принимает только IP:порт.
func parseAwgConf(text string, resolve func(host string) (netip.Addr, error)) (*awgConfig, error) {
	cfg := &awgConfig{MTU: 1420}
	var iface, peers strings.Builder
	section := ""
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.Trim(line, "[]"))
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key, val := snake(strings.TrimSpace(k)), strings.TrimSpace(v)
		switch section {
		case "interface":
			switch key {
			case "private_key":
				h, err := keyHex(val)
				if err != nil {
					return nil, fmt.Errorf("PrivateKey: %w", err)
				}
				fmt.Fprintf(&iface, "private_key=%s\n", h)
			case "address":
				for _, a := range splitList(val) {
					p, err := netip.ParsePrefix(a)
					if err != nil {
						addr, err2 := netip.ParseAddr(a)
						if err2 != nil {
							return nil, fmt.Errorf("Address %q: %w", a, err)
						}
						p = netip.PrefixFrom(addr, addr.BitLen())
					}
					cfg.Addresses = append(cfg.Addresses, p)
				}
			case "dns":
				for _, d := range splitList(val) {
					if a, err := netip.ParseAddr(d); err == nil {
						cfg.DNS = append(cfg.DNS, a)
					}
				}
			case "mtu":
				if n, err := strconv.Atoi(val); err == nil && n > 0 {
					cfg.MTU = n
				}
			case "header_protection_key":
				// В .conf ключ в base64, UAPI amneziawg-go ждёт hex.
				if _, err := hex.DecodeString(val); err != nil {
					raw, err := base64.StdEncoding.DecodeString(val)
					if err != nil {
						return nil, fmt.Errorf("HeaderProtectionKey: %w", err)
					}
					val = hex.EncodeToString(raw)
				}
				fmt.Fprintf(&iface, "header_protection_key=%s\n", val)
			case "random_trailers", "disable_cookies":
				on := strings.EqualFold(val, "on") || strings.EqualFold(val, "true") || val == "1"
				fmt.Fprintf(&iface, "%s=%t\n", key, on)
			default:
				if awgInterfaceKeys[key] {
					fmt.Fprintf(&iface, "%s=%s\n", key, val)
				}
			}
		case "peer":
			switch key {
			case "public_key":
				h, err := keyHex(val)
				if err != nil {
					return nil, fmt.Errorf("PublicKey: %w", err)
				}
				fmt.Fprintf(&peers, "public_key=%s\n", h)
			case "preshared_key":
				h, err := keyHex(val)
				if err != nil {
					return nil, fmt.Errorf("PresharedKey: %w", err)
				}
				fmt.Fprintf(&peers, "preshared_key=%s\n", h)
			case "endpoint":
				host, portStr, err := net.SplitHostPort(val)
				if err != nil {
					return nil, fmt.Errorf("Endpoint %q: %w", val, err)
				}
				port, err := strconv.ParseUint(portStr, 10, 16)
				if err != nil {
					return nil, fmt.Errorf("Endpoint %q: порт", val)
				}
				addr, err := netip.ParseAddr(host)
				if err != nil {
					if addr, err = resolve(host); err != nil {
						return nil, fmt.Errorf("не удалось найти адрес сервера %s: %w", host, err)
					}
				}
				ep := netip.AddrPortFrom(addr.Unmap(), uint16(port))
				cfg.Endpoints = append(cfg.Endpoints, ep)
				fmt.Fprintf(&peers, "endpoint=%s\n", ep)
			case "allowed_i_ps", "allowed_ips":
				for _, a := range splitList(val) {
					p, err := netip.ParsePrefix(a)
					if err != nil {
						return nil, fmt.Errorf("AllowedIPs %q: %w", a, err)
					}
					cfg.Routes = append(cfg.Routes, p)
					fmt.Fprintf(&peers, "allowed_ip=%s\n", p)
				}
			case "persistent_keepalive":
				fmt.Fprintf(&peers, "persistent_keepalive_interval=%s\n", val)
			}
		}
	}
	if iface.Len() == 0 || !strings.Contains(iface.String(), "private_key=") {
		return nil, errors.New("в конфиге нет PrivateKey")
	}
	if peers.Len() == 0 {
		return nil, errors.New("в конфиге нет [Peer]")
	}
	if len(cfg.Addresses) == 0 {
		return nil, errors.New("в конфиге нет Address")
	}
	// Без keepalive WireGuard начинает рукопожатие только с первым пакетом, а NAT
	// мобильных сетей забывает соединение за минуты. Amnezia по умолчанию ставит 25 с.
	if !strings.Contains(peers.String(), "persistent_keepalive_interval=") {
		peers.WriteString("persistent_keepalive_interval=25\n")
	}
	cfg.UAPI = iface.String() + "replace_peers=true\n" + peers.String()
	return cfg, nil
}

// defaultResolve использует системный резолвер (на Android — DNS сети, см. useResolvers).
func defaultResolve(host string) (netip.Addr, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return netip.Addr{}, err
	}
	for _, a := range addrs {
		if a.Is4() {
			return a, nil
		}
	}
	if len(addrs) == 0 {
		return netip.Addr{}, errors.New("нет адресов")
	}
	return addrs[0], nil
}

func startAwgDevice(tunDev tun.Device, bind conn.Bind, cfg *awgConfig) (*device.Device, error) {
	level := device.LogLevelError
	if os.Getenv("SRU_AWG_VERBOSE") != "" {
		level = device.LogLevelVerbose
	}
	dev := device.NewDevice(tunDev, bind, device.NewLogger(level, "awg: "))
	if err := dev.IpcSet(cfg.UAPI); err != nil {
		dev.Close()
		return nil, fmt.Errorf("конфиг AmneziaWG: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, err
	}
	return dev, nil
}

// waitHandshake ждёт первого рукопожатия: значит, сервер доступен, ключи и
// параметры обфускации совпали. Без него «подключено» было бы неправдой.
func waitHandshake(dev *device.Device, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		state, err := dev.IpcGet()
		if err == nil {
			for _, line := range strings.Split(state, "\n") {
				if v, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok && v != "0" {
					return nil
				}
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("нет рукопожатия с сервером AmneziaWG (сервер недоступен или параметры не совпадают)")
}
