//go:build windows

package main

import (
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"os/signal"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

// runDesktopAwg — AmneziaWG на Windows: адаптер wintun (нужны права
// администратора и wintun.dll рядом с ядром), адреса, маршруты и DNS через
// winipcfg. Свой UDP-сокет amneziawg-go привязывается к физическому интерфейсу
// с маршрутом по умолчанию, иначе пакеты к серверу ушли бы в сам туннель.
func runDesktopAwg(conf []byte, stdin io.Reader, stdout io.Writer) error {
	cfg, err := parseAwgConf(string(conf), defaultResolve)
	if err != nil {
		return err
	}
	tunDev, err := tun.CreateTUN("SruNaZapret", cfg.MTU)
	if err != nil {
		return fmt.Errorf("адаптер wintun (нужны права администратора): %w", err)
	}
	luid := winipcfg.LUID(tunDev.(*tun.NativeTun).LUID())

	bind := conn.NewDefaultBind()
	dev, err := startAwgDevice(tunDev, bind, cfg)
	if err != nil {
		return err
	}
	defer dev.Close()

	if err := bindToDefaultInterface(bind, luid); err != nil {
		return err
	}
	if err := luid.SetIPAddresses(cfg.Addresses); err != nil {
		return fmt.Errorf("адрес адаптера: %w", err)
	}
	var routes []*winipcfg.RouteData
	for _, r := range cfg.Routes {
		next := netip.IPv4Unspecified()
		if r.Addr().Is6() {
			next = netip.IPv6Unspecified()
		}
		routes = append(routes, &winipcfg.RouteData{Destination: r.Masked(), NextHop: next, Metric: 0})
	}
	if err := luid.SetRoutes(routes); err != nil {
		return fmt.Errorf("маршруты: %w", err)
	}
	var dns4, dns6 []netip.Addr
	for _, d := range cfg.DNS {
		if d.Is4() {
			dns4 = append(dns4, d)
		} else {
			dns6 = append(dns6, d)
		}
	}
	if len(dns4) > 0 {
		_ = luid.SetDNS(windows.AF_INET, dns4, nil)
	}
	if len(dns6) > 0 {
		_ = luid.SetDNS(windows.AF_INET6, dns6, nil)
	}

	if err := waitHandshake(dev, 12*time.Second); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "started")

	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, stdin)
		close(done)
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	select {
	case <-done:
	case <-sig:
	}
	return nil
}

// bindToDefaultInterface находит интерфейс с маршрутом по умолчанию (кроме
// нашего адаптера) и привязывает к нему сокет amneziawg-go.
func bindToDefaultInterface(bind conn.Bind, own winipcfg.LUID) error {
	b, ok := bind.(conn.BindSocketToInterface)
	if !ok {
		return errors.New("привязка сокета к интерфейсу не поддерживается")
	}
	for _, family := range []winipcfg.AddressFamily{windows.AF_INET, windows.AF_INET6} {
		rows, err := winipcfg.GetIPForwardTable2(family)
		if err != nil {
			continue
		}
		best, bestMetric := uint32(0), uint32(^uint32(0))
		for i := range rows {
			r := &rows[i]
			if r.DestinationPrefix.PrefixLength != 0 || r.InterfaceLUID == own {
				continue
			}
			iface, err := r.InterfaceLUID.Interface()
			if err != nil || iface.OperStatus != winipcfg.IfOperStatusUp {
				continue
			}
			ipif, err := r.InterfaceLUID.IPInterface(family)
			if err != nil {
				continue
			}
			if m := r.Metric + ipif.Metric; m < bestMetric {
				best, bestMetric = r.InterfaceIndex, m
			}
		}
		if best == 0 {
			continue
		}
		var err2 error
		if family == windows.AF_INET {
			err2 = b.BindSocketToInterface4(best, false)
		} else {
			err2 = b.BindSocketToInterface6(best, false)
		}
		if err2 != nil {
			return fmt.Errorf("привязка сокета к интерфейсу: %w", err2)
		}
	}
	return nil
}
