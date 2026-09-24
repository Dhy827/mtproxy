package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	mode := flag.String("mode", "", "tcp or http")
	listen := flag.String("listen", "", "address to listen on, host:port")
	target := flag.String("target", "", "tcp host:port, or http(s)://host[:port]")
	flag.Parse()

	if err := validate(*mode, *listen, *target); err != nil {
		log.Fatalf("argument error: %v", err)
	}
	log.Printf("event=started mode=%s listen=%s target=%s", *mode, *listen, *target)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch *mode {
	case "tcp":
		err = serveTCP(ctx, *listen, *target)
	default:
		err = serveHTTP(ctx, *listen, *target)
	}
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("event=stopped error=%v", err)
	}
	log.Printf("event=stopped")
}

func validate(mode, listen, target string) error {
	switch mode {
	case "tcp":
		if _, _, err := splitHostPort(listen); err != nil {
			return fmt.Errorf("listen: %w", err)
		}
		if _, _, err := splitHostPort(target); err != nil {
			return fmt.Errorf("target: %w", err)
		}
		return nil
	case "http":
		if err := requireLoopback(listen); err != nil {
			return fmt.Errorf("listen: %w", err)
		}
		if _, err := parseHTTPTarget(target); err != nil {
			return fmt.Errorf("target: %w", err)
		}
		return nil
	default:
		return errors.New("mode must be tcp or http")
	}
}

func splitHostPort(address string) (string, string, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return "", "", err
	}
	if host == "" {
		return "", "", errors.New("missing host")
	}
	if _, err := net.LookupPort("tcp", port); err != nil {
		return "", "", errors.New("invalid port")
	}
	return host, port, nil
}

func requireLoopback(address string) error {
	host, _, err := splitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("must be a numeric loopback address")
	}
	return nil
}

func parseHTTPTarget(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("scheme must be http or https")
	}
	if parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("must be scheme://host[:port] without user, query, or fragment")
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return nil, errors.New("must not contain a path")
	}
	if host, port, err := net.SplitHostPort(parsed.Host); err == nil {
		if host == "" {
			return nil, errors.New("missing host")
		}
		if _, err := net.LookupPort("tcp", port); err != nil {
			return nil, errors.New("invalid port")
		}
	}
	parsed.Path = ""
	parsed.RawPath = ""
	return parsed, nil
}

func serveTCP(ctx context.Context, listen, target string) error {
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go bridgeTCP(connection, target)
	}
}

func bridgeTCP(client net.Conn, target string) {
	defer client.Close()
	enableKeepAlive(client)
	upstream, err := (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).Dial("tcp", target)
	if err != nil {
		log.Printf("event=dial_failed target=%s", target)
		return
	}
	defer upstream.Close()
	enableKeepAlive(upstream)
	done := make(chan struct{}, 2)
	copyOne := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		if closer, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyOne(upstream, client)
	go copyOne(client, upstream)
	<-done
}

func enableKeepAlive(connection net.Conn) {
	tcp, ok := connection.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcp.SetKeepAlive(true)
	_ = tcp.SetKeepAlivePeriod(30 * time.Second)
}

func serveHTTP(ctx context.Context, listen, target string) error {
	parsed, err := parseHTTPTarget(target)
	if err != nil {
		return err
	}
	server := &http.Server{
		Addr:              listen,
		Handler:           newHTTPProxy(parsed),
		ReadHeaderTimeout: 30 * time.Second,
	}
	errors := make(chan error, 1)
	go func() {
		errors <- server.ListenAndServe()
	}()
	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
		return nil
	case err := <-errors:
		if errorsIsClosed(err) {
			return nil
		}
		return err
	}
}

func errorsIsClosed(err error) bool {
	return err == nil || errors.Is(err, http.ErrServerClosed)
}

func newHTTPProxy(target *url.URL) http.Handler {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DisableCompression = true
	transport.Proxy = nil
	return &httputil.ReverseProxy{
		Transport:     transport,
		FlushInterval: -1,
		Rewrite: func(request *httputil.ProxyRequest) {
			query := request.In.URL.RawQuery
			request.SetURL(target)
			request.Out.Host = target.Host
			request.Out.URL.RawQuery = query
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, http.StatusText(http.StatusBadGateway), http.StatusBadGateway)
		},
	}
}
