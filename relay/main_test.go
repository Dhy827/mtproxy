package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestValidate(t *testing.T) {
	if err := validate("tcp", "0.0.0.0:18080", "127.0.0.1:8080"); err != nil {
		t.Fatal(err)
	}
	if err := validate("http", "127.0.0.1:30000", "https://example.com"); err != nil {
		t.Fatal(err)
	}
	if err := validate("http", "0.0.0.0:30000", "https://example.com"); err == nil {
		t.Fatal("http listen must stay on loopback")
	}
	if err := validate("http", "127.0.0.1:30000", "https://example.com/blog"); err == nil {
		t.Fatal("target path must be rejected")
	}
	if err := validate("tcp", "127.0.0.1:1", "https://example.com"); err == nil {
		t.Fatal("tcp target must be host:port")
	}
}

func TestHTTPForwardsAndRewritesHost(t *testing.T) {
	var seenHost string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seenHost = r.Host
		if r.URL.Path != "/index.html" || r.URL.RawQuery != "q=1" || string(body) != "hi" {
			t.Errorf("path=%s query=%s body=%s", r.URL.Path, r.URL.RawQuery, body)
		}
		w.Header().Set("Location", "https://example.com/away")
		w.WriteHeader(http.StatusFound)
	}))
	defer upstream.Close()

	target, err := parseHTTPTarget(upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	relay := httptest.NewServer(newHTTPProxy(target))
	defer relay.Close()

	request, err := http.NewRequest(http.MethodPost, relay.URL+"/index.html?q=1", strings.NewReader("hi"))
	if err != nil {
		t.Fatal(err)
	}
	request.Host = "proxy.example.com"
	client := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Timeout: 5 * time.Second,
	}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusFound {
		t.Fatalf("status %d", response.StatusCode)
	}
	if response.Header.Get("Location") != "https://example.com/away" {
		t.Fatalf("location %s", response.Header.Get("Location"))
	}
	if seenHost != strings.TrimPrefix(upstream.URL, "http://") {
		t.Fatalf("upstream host %s", seenHost)
	}
}

func TestTCPCopiesBytes(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		connection, err := echo.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		_, _ = io.Copy(connection, connection)
	}()

	relay, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	go func() {
		for {
			connection, err := relay.Accept()
			if err != nil {
				return
			}
			go bridgeTCP(connection, echo.Addr().String())
		}
	}()

	client, err := net.Dial("tcp", relay.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := client.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	buffer := make([]byte, 4)
	if _, err := io.ReadFull(client, buffer); err != nil {
		t.Fatal(err)
	}
	if string(buffer) != "ping" {
		t.Fatalf("got %q", buffer)
	}
}
