package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/x509"
	"encoding/binary"
	"encoding/pem"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRequestPath(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"GET /add.php HTTP/1.1\r\nHost: a\r\n\r\n", "/add.php"},
		{"GET /add.php?x=1 HTTP/1.1\r\n\r\n", "/add.php"},
		{"GET / HTTP/1.1\r\n\r\n", "/"},
		{"GET /add.php/ HTTP/1.1\r\n\r\n", "/add.php/"},
		{"not a request", ""},
	}
	for _, item := range cases {
		if got := requestPath([]byte(item.in)); got != item.want {
			t.Fatalf("requestPath(%q) = %q, want %q", item.in, got, item.want)
		}
	}
}

func TestWhitelistIPSEG(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "ip_white.conf")
	list, err := loadWhitelist(path, "IPSEG")
	if err != nil {
		t.Fatal(err)
	}
	key, added, err := list.add(net.ParseIP("203.0.113.8"))
	if err != nil || !added || key != "203.0.113.0/24" {
		t.Fatalf("add = %s %v %v", key, added, err)
	}
	if _, added, _ = list.add(net.ParseIP("203.0.113.9")); added {
		t.Fatal("same /24 was recorded twice")
	}
	if !list.allows(net.ParseIP("203.0.113.200")) {
		t.Fatal("address inside the segment was rejected")
	}
	if list.allows(net.ParseIP("203.0.114.1")) {
		t.Fatal("address outside the segment was allowed")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "203.0.113.0/24 1;\n" {
		t.Fatalf("file = %q", raw)
	}
	again, err := loadWhitelist(path, "IP")
	if err != nil {
		t.Fatal(err)
	}
	if !again.allows(net.ParseIP("203.0.113.20")) {
		t.Fatal("reloaded segment did not match")
	}
}

func TestWhitelistOFF(t *testing.T) {
	list, err := loadWhitelist(filepath.Join(t.TempDir(), "missing.conf"), "OFF")
	if err != nil {
		t.Fatal(err)
	}
	if !list.allows(net.ParseIP("198.51.100.1")) {
		t.Fatal("OFF should allow any address")
	}
	if _, added, _ := list.add(net.ParseIP("198.51.100.1")); added {
		t.Fatal("OFF should not record an address")
	}
}

func TestFilterPublic(t *testing.T) {
	local := map[string]struct{}{"198.51.100.9": {}}
	ips := []net.IP{
		net.ParseIP("10.1.2.3"),
		net.ParseIP("127.0.0.1"),
		net.ParseIP("192.168.1.1"),
		net.ParseIP("198.51.100.9"),
		net.ParseIP("8.8.8.8"),
	}
	got := filterPublic(ips, local)
	if len(got) != 1 || !got[0].Equal(net.ParseIP("8.8.8.8")) {
		t.Fatalf("filterPublic = %v", got)
	}
}

func TestDialUpstreamRejectsPrivate(t *testing.T) {
	orig := lookupIP
	lookupIP = func(string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("10.1.2.3"), net.ParseIP("127.0.0.1")}, nil
	}
	t.Cleanup(func() { lookupIP = orig })
	if _, err := dialUpstream("cloudflare.com"); err == nil {
		t.Fatal("private addresses were dialed")
	}
}

func TestHTTPRecordsAndReplays(t *testing.T) {
	seen := make(chan string, 1)
	nginx := listenOnce(t, func(conn net.Conn) {
		buf := make([]byte, 4096)
		n, _ := conn.Read(buf)
		seen <- string(buf[:n])
		_, _ = conn.Write([]byte("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
	})
	dir := t.TempDir()
	list, err := loadWhitelist(filepath.Join(dir, "ip_white.conf"), "IP")
	if err != nil {
		t.Fatal(err)
	}
	cfg := testConfig(nginx, "127.0.0.1:1", "127.0.0.1:1")
	cfg.whitelistPath = "/add.php"
	httpAddr, _ := startFront(t, cfg, list)

	conn, err := net.Dial("tcp", httpAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, _ = conn.Write([]byte("GET /add.php?from=test HTTP/1.1\r\nHost: example\r\n\r\n"))
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 128)
	n, err := conn.Read(buf)
	if err != nil || !strings.Contains(string(buf[:n]), "404") {
		t.Fatalf("response %q %v", buf[:n], err)
	}
	if !list.allows(net.ParseIP("127.0.0.1")) {
		t.Fatal("client address was not recorded")
	}
	select {
	case got := <-seen:
		if !strings.Contains(got, "GET /add.php?from=test HTTP/1.1") {
			t.Fatalf("nginx saw %q", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("nginx did not receive the request")
	}
}

func TestHTTPOtherPathDoesNotRecord(t *testing.T) {
	nginx := listenOnce(t, func(conn net.Conn) {
		buf := make([]byte, 128)
		_, _ = conn.Read(buf)
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
	})
	list, err := loadWhitelist(filepath.Join(t.TempDir(), "ip_white.conf"), "IP")
	if err != nil {
		t.Fatal(err)
	}
	cfg := testConfig(nginx, "127.0.0.1:1", "127.0.0.1:1")
	httpAddr, _ := startFront(t, cfg, list)
	conn, err := net.Dial("tcp", httpAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, _ = conn.Write([]byte("GET / HTTP/1.1\r\nHost: example\r\n\r\n"))
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 64)
	_, _ = conn.Read(buf)
	if list.allows(net.ParseIP("127.0.0.1")) {
		t.Fatal("visiting / recorded the client")
	}
}

func TestFakeTLSMatches(t *testing.T) {
	secret := bytes.Repeat([]byte{0x11}, 16)
	packet := fakeTLSPacket(secret)
	if !fakeTLSMatches(packet, secret) {
		t.Fatal("valid client hello was rejected")
	}
	other := bytes.Repeat([]byte{0x22}, 16)
	if fakeTLSMatches(packet, other) {
		t.Fatal("hello matched a different secret")
	}
	packet[11] ^= 0xff
	if fakeTLSMatches(packet, secret) {
		t.Fatal("tampered digest was accepted")
	}
	plain := []byte("GET / HTTP/1.1\r\n\r\n")
	if fakeTLSMatches(plain, secret) {
		t.Fatal("plain HTTP was treated as FakeTLS")
	}
}

func TestAUTOAcceptsFakeTLSWithoutPriorVisit(t *testing.T) {
	secret := bytes.Repeat([]byte{0x11}, 16)
	hello := fakeTLSPacket(secret)
	mtpSeen := make(chan string, 1)
	siteSeen := make(chan string, 1)
	mtp := listenOnce(t, func(conn net.Conn) {
		buf := make([]byte, len(hello)+8)
		n, _ := conn.Read(buf)
		mtpSeen <- string(buf[:n])
	})
	fallback := listenOnce(t, func(conn net.Conn) {
		buf := make([]byte, 16)
		n, _ := conn.Read(buf)
		siteSeen <- string(buf[:n])
	})
	list, err := loadWhitelist(filepath.Join(t.TempDir(), "ip_white.conf"), "AUTO")
	if err != nil {
		t.Fatal(err)
	}
	cfg := testConfig("127.0.0.1:1", mtp, fallback)
	cfg.secret = secret
	_, httpsAddr := startFront(t, cfg, list)

	conn, err := net.Dial("tcp", httpsAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write(hello); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-mtpSeen:
		if got != string(hello) {
			t.Fatal("AUTO did not forward the original client hello")
		}
	case <-siteSeen:
		t.Fatal("valid FakeTLS was sent to fallback")
	case <-time.After(2 * time.Second):
		t.Fatal("AUTO did not forward FakeTLS")
	}
	if !list.allows(net.ParseIP("127.0.0.1")) {
		t.Fatal("AUTO did not record the client address")
	}
}

func TestHTTPSRoutesByWhitelistAndSecret(t *testing.T) {
	secret := bytes.Repeat([]byte{0x11}, 16)
	hello := fakeTLSPacket(secret)
	mtpSeen := make(chan string, 1)
	siteSeen := make(chan string, 2)
	mtp := listenOnce(t, func(conn net.Conn) {
		buf := make([]byte, len(hello)+8)
		n, _ := conn.Read(buf)
		mtpSeen <- string(buf[:n])
	})
	fallback := listenOnce(t, func(conn net.Conn) {
		buf := make([]byte, len(hello)+8)
		n, _ := conn.Read(buf)
		siteSeen <- string(buf[:n])
	})
	list, err := loadWhitelist(filepath.Join(t.TempDir(), "ip_white.conf"), "IP")
	if err != nil {
		t.Fatal(err)
	}
	cfg := testConfig("127.0.0.1:1", mtp, fallback)
	cfg.secret = secret
	_, httpsAddr := startFront(t, cfg, list)

	send := func(payload []byte) {
		t.Helper()
		conn, err := net.Dial("tcp", httpsAddr)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		if _, err := conn.Write(payload); err != nil {
			t.Fatal(err)
		}
	}
	send(hello)
	select {
	case got := <-siteSeen:
		if got != string(hello) {
			t.Fatal("unlisted FakeTLS was not sent to fallback unchanged")
		}
	case <-mtpSeen:
		t.Fatal("unlisted address was sent to MTProxy")
	case <-time.After(2 * time.Second):
		t.Fatal("fallback did not receive the connection")
	}

	if _, added, err := list.add(net.ParseIP("127.0.0.1")); err != nil || !added {
		t.Fatal(err)
	}
	fallback2 := listenOnce(t, func(conn net.Conn) {
		buf := make([]byte, 16)
		n, _ := conn.Read(buf)
		siteSeen <- string(buf[:n])
	})
	cfg2 := testConfig("127.0.0.1:1", mtp, fallback2)
	cfg2.secret = secret
	_, httpsAddr = startFront(t, cfg2, list)
	send = func(payload []byte) {
		t.Helper()
		conn, err := net.Dial("tcp", httpsAddr)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		if _, err := conn.Write(payload); err != nil {
			t.Fatal(err)
		}
	}
	send([]byte("browser"))
	select {
	case got := <-siteSeen:
		if got != "browser" {
			t.Fatalf("whitelisted plain traffic saw %q", got)
		}
	case <-mtpSeen:
		t.Fatal("plain traffic was sent to MTProxy")
	case <-time.After(2 * time.Second):
		t.Fatal("fallback did not receive plain traffic")
	}
	send(hello)
	select {
	case got := <-mtpSeen:
		if got != string(hello) {
			t.Fatal("MTProxy did not receive the original client hello")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("whitelisted FakeTLS was not sent to MTProxy")
	}
}

func fakeTLSPacket(secret []byte) []byte {
	bodyLen := 80
	packet := bytes.Repeat([]byte{0xab}, 5+bodyLen)
	packet[0], packet[1], packet[2] = 0x16, 0x03, 0x01
	binary.BigEndian.PutUint16(packet[3:5], uint16(bodyLen))
	msg := bytes.Clone(packet)
	copy(msg[11:43], make([]byte, 32))
	mac := hmac.New(sha256.New, secret)
	mac.Write(msg)
	sum := mac.Sum(nil)
	copy(packet[11:39], sum[:28])
	return packet
}

func TestWriteCertKeepsExisting(t *testing.T) {
	dir := t.TempDir()
	certPath := filepath.Join(dir, "fallback.crt")
	keyPath := filepath.Join(dir, "fallback.key")
	if err := writeCert(certPath, keyPath); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(certPath)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(first)
	if block == nil {
		t.Fatal("certificate pem is empty")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		t.Fatal(err)
	}
	if err := writeCert(certPath, keyPath); err != nil {
		t.Fatal(err)
	}
	second, err := os.ReadFile(certPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(first) != string(second) {
		t.Fatal("existing certificate was replaced")
	}
}

func testConfig(nginxHTTP, mtp, nginxTLS string) config {
	return config{
		fallback:      "local",
		whitelistPath: "/add.php",
		nginxHTTP:     nginxHTTP,
		mtp:           mtp,
		nginxTLS:      nginxTLS,
		httpListen:    "127.0.0.1:0",
		httpsListen:   "127.0.0.1:0",
	}
}

func startFront(t *testing.T, cfg config, list *whitelist) (string, string) {
	t.Helper()
	httpLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	httpsLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		cancel()
		_ = httpLn.Close()
		_ = httpsLn.Close()
	})
	go serveListeners(ctx, cfg, list, httpLn, httpsLn)
	return httpLn.Addr().String(), httpsLn.Addr().String()
}

func listenOnce(t *testing.T, handle func(net.Conn)) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		handle(conn)
	}()
	return ln.Addr().String()
}
