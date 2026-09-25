package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
)

type whitelist struct {
	path    string
	mode    string
	mu      sync.Mutex
	entries []string
}

func loadWhitelist(path, mode string) (*whitelist, error) {
	switch mode {
	case "OFF", "IP", "IPSEG", "AUTO":
	default:
		return nil, fmt.Errorf("ip_white_list 只能是 OFF、IP、IPSEG 或 AUTO")
	}
	list := &whitelist{path: path, mode: mode}
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return list, nil
		}
		return nil, err
	}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		token := fields[0]
		if net.ParseIP(token) == nil && netAllowed(token) == nil {
			continue
		}
		list.entries = append(list.entries, token)
	}
	return list, nil
}

func (l *whitelist) allows(ip net.IP) bool {
	if l.mode == "OFF" {
		return true
	}
	if ip == nil {
		return false
	}
	ip = unmap(ip)
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, entry := range l.entries {
		if entryContains(entry, ip) {
			return true
		}
	}
	return false
}

func (l *whitelist) add(ip net.IP) (string, bool, error) {
	if l.mode == "OFF" || ip == nil {
		return "", false, nil
	}
	key := whitelistKey(l.mode, ip)
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, entry := range l.entries {
		if entry == key {
			return key, false, nil
		}
	}
	l.entries = append(l.entries, key)
	if err := l.save(); err != nil {
		l.entries = l.entries[:len(l.entries)-1]
		return key, false, err
	}
	return key, true, nil
}

func (l *whitelist) save() error {
	var builder strings.Builder
	for _, entry := range l.entries {
		fmt.Fprintf(&builder, "%s 1;\n", entry)
	}
	temp := l.path + ".tmp"
	if err := os.WriteFile(temp, []byte(builder.String()), 0644); err != nil {
		return err
	}
	return os.Rename(temp, l.path)
}

func unmap(ip net.IP) net.IP {
	if ip == nil {
		return nil
	}
	if v4 := ip.To4(); v4 != nil {
		return v4
	}
	return ip
}

func whitelistKey(mode string, ip net.IP) string {
	ip = unmap(ip)
	if mode == "IPSEG" {
		if v4 := ip.To4(); v4 != nil {
			return fmt.Sprintf("%d.%d.%d.0/24", v4[0], v4[1], v4[2])
		}
	}
	return ip.String()
}

func entryContains(entry string, ip net.IP) bool {
	if network := netAllowed(entry); network != nil {
		return network.Contains(ip)
	}
	other := net.ParseIP(entry)
	return other != nil && unmap(other).Equal(ip)
}

func netAllowed(entry string) *net.IPNet {
	if !strings.Contains(entry, "/") {
		return nil
	}
	_, network, err := net.ParseCIDR(entry)
	if err != nil {
		return nil
	}
	return network
}
