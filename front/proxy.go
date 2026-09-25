package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"time"
)

type config struct {
	httpListen    string
	httpsListen   string
	mtp           string
	nginxHTTP     string
	nginxTLS      string
	fallback      string
	domain        string
	whitelistPath string
	whitelistFile string
	whitelistMode string
	secret        []byte
}

func (c config) validate() error {
	switch c.fallback {
	case "local", "upstream":
	default:
		return errors.New("https_fallback 只能是 local 或 upstream")
	}
	if c.fallback == "upstream" && c.domain == "" {
		return errors.New("upstream 需要 domain")
	}
	if c.whitelistPath == "" || !strings.HasPrefix(c.whitelistPath, "/") || strings.Contains(c.whitelistPath, "?") {
		return errors.New("whitelist_path 必须是以 / 开头的路径")
	}
	if len(c.secret) != 16 {
		return errors.New("secret 必须是 16 字节")
	}
	for _, address := range []string{c.httpListen, c.httpsListen, c.mtp, c.nginxHTTP, c.nginxTLS} {
		if _, _, err := net.SplitHostPort(address); err != nil {
			return fmt.Errorf("地址无效 %s", address)
		}
	}
	return nil
}

var lookupIP = net.LookupIP

func serve(ctx context.Context, cfg config, list *whitelist) error {
	if err := cfg.validate(); err != nil {
		return err
	}
	if cfg.fallback == "upstream" {
		if err := checkDomain(cfg.domain); err != nil {
			return err
		}
	}
	httpLn, err := net.Listen("tcp", cfg.httpListen)
	if err != nil {
		return err
	}
	httpsLn, err := net.Listen("tcp", cfg.httpsListen)
	if err != nil {
		httpLn.Close()
		return err
	}
	log.Printf("入口已监听 http=%s https=%s fallback=%s", cfg.httpListen, cfg.httpsListen, cfg.fallback)
	return serveListeners(ctx, cfg, list, httpLn, httpsLn)
}

func serveListeners(ctx context.Context, cfg config, list *whitelist, httpLn, httpsLn net.Listener) error {
	go func() {
		<-ctx.Done()
		_ = httpLn.Close()
		_ = httpsLn.Close()
	}()
	errCh := make(chan error, 2)
	go func() { errCh <- acceptLoop(ctx, httpLn, func(conn net.Conn) { handleHTTP(conn, cfg, list) }) }()
	go func() { errCh <- acceptLoop(ctx, httpsLn, func(conn net.Conn) { handleHTTPS(conn, cfg, list) }) }()
	select {
	case <-ctx.Done():
		return nil
	case err := <-errCh:
		_ = httpLn.Close()
		_ = httpsLn.Close()
		return err
	}
}

func acceptLoop(ctx context.Context, ln net.Listener, handle func(net.Conn)) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go handle(conn)
	}
}

func handleHTTP(client net.Conn, cfg config, list *whitelist) {
	head, path := readHead(client)
	if path == cfg.whitelistPath && (list.mode == "IP" || list.mode == "IPSEG") {
		if ip := clientIP(client); ip != nil {
			if key, added, err := list.add(ip); err != nil {
				log.Printf("写入白名单失败: %v", err)
			} else if added {
				log.Printf("已登记白名单 %s", key)
			}
		}
	}
	bridge(client, cfg.nginxHTTP, head)
}

func handleHTTPS(client net.Conn, cfg config, list *whitelist) {
	if list.mode == "AUTO" {
		hello := readClientHello(client)
		if fakeTLSMatches(hello, cfg.secret) {
			noteWhitelist(list, clientIP(client))
			bridge(client, cfg.mtp, hello)
			return
		}
		routeFallback(client, cfg, hello)
		return
	}
	if !list.allows(clientIP(client)) {
		routeFallback(client, cfg, nil)
		return
	}
	hello := readClientHello(client)
	if fakeTLSMatches(hello, cfg.secret) {
		bridge(client, cfg.mtp, hello)
		return
	}
	routeFallback(client, cfg, hello)
}

func noteWhitelist(list *whitelist, ip net.IP) {
	if ip == nil {
		return
	}
	key, added, err := list.add(ip)
	if err != nil {
		log.Printf("写入白名单失败: %v", err)
		return
	}
	if added {
		log.Printf("已登记白名单 %s", key)
	}
}

func routeFallback(client net.Conn, cfg config, preface []byte) {
	if cfg.fallback == "local" {
		bridge(client, cfg.nginxTLS, preface)
		return
	}
	bridgeUpstream(client, cfg.domain, preface)
}

func readHead(conn net.Conn) ([]byte, string) {
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	defer conn.SetReadDeadline(time.Time{})
	buf := make([]byte, 0, 512)
	tmp := make([]byte, 1024)
	for len(buf) < 65536 {
		n, err := conn.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
			if bytes.Contains(buf, []byte("\r\n\r\n")) {
				return buf, requestPath(buf)
			}
		}
		if err != nil {
			break
		}
	}
	return buf, ""
}

func requestPath(head []byte) string {
	line, _, _ := bytes.Cut(head, []byte("\r\n"))
	parts := bytes.Fields(line)
	if len(parts) < 2 {
		return ""
	}
	raw := string(parts[1])
	if i := strings.IndexByte(raw, '?'); i >= 0 {
		raw = raw[:i]
	}
	if raw == "" || raw[0] != '/' {
		return ""
	}
	return raw
}

func bridge(client net.Conn, target string, preface []byte) {
	defer client.Close()
	upstream, err := (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).Dial("tcp", target)
	if err != nil {
		log.Printf("连接 %s 失败: %v", target, err)
		return
	}
	defer upstream.Close()
	if len(preface) > 0 {
		if _, err := upstream.Write(preface); err != nil {
			return
		}
	}
	copyBoth(client, upstream)
}

func bridgeUpstream(client net.Conn, domain string, preface []byte) {
	defer client.Close()
	upstream, err := dialUpstream(domain)
	if err != nil {
		log.Printf("转发 %s 失败: %v", domain, err)
		return
	}
	defer upstream.Close()
	if len(preface) > 0 {
		if _, err := upstream.Write(preface); err != nil {
			return
		}
	}
	copyBoth(client, upstream)
}

func copyBoth(left, right net.Conn) {
	enableKeepAlive(left)
	enableKeepAlive(right)
	done := make(chan struct{}, 2)
	copyOne := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		if closer, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyOne(right, left)
	go copyOne(left, right)
	<-done
}

func enableKeepAlive(conn net.Conn) {
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcp.SetKeepAlive(true)
	_ = tcp.SetKeepAlivePeriod(30 * time.Second)
}

func clientIP(conn net.Conn) net.IP {
	host, _, err := net.SplitHostPort(conn.RemoteAddr().String())
	if err != nil {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return nil
	}
	return unmap(ip)
}

func checkDomain(domain string) error {
	ips, err := lookupIP(domain)
	if err != nil {
		return fmt.Errorf("解析 %s 失败: %w", domain, err)
	}
	if len(filterPublic(ips, localIPSet())) == 0 {
		return fmt.Errorf("%s 没有可用的公网地址", domain)
	}
	return nil
}

func dialUpstream(domain string) (net.Conn, error) {
	ips, err := lookupIP(domain)
	if err != nil {
		return nil, err
	}
	public := filterPublic(ips, localIPSet())
	if len(public) == 0 {
		return nil, errors.New("没有可用的公网地址")
	}
	var last error
	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	for _, ip := range public {
		conn, err := dialer.Dial("tcp", net.JoinHostPort(ip.String(), "443"))
		if err == nil {
			return conn, nil
		}
		last = err
	}
	return nil, last
}

func filterPublic(ips []net.IP, local map[string]struct{}) []net.IP {
	var out []net.IP
	for _, ip := range ips {
		if ip == nil {
			continue
		}
		ip = unmap(ip)
		if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast() {
			continue
		}
		if _, ok := local[ip.String()]; ok {
			continue
		}
		out = append(out, ip)
	}
	return out
}

func localIPSet() map[string]struct{} {
	set := map[string]struct{}{}
	ifaces, err := net.Interfaces()
	if err != nil {
		return set
	}
	for _, iface := range ifaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			switch value := addr.(type) {
			case *net.IPNet:
				set[unmap(value.IP).String()] = struct{}{}
			case *net.IPAddr:
				set[unmap(value.IP).String()] = struct{}{}
			}
		}
	}
	return set
}
