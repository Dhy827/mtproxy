package main

import (
	"context"
	"encoding/hex"
	"errors"
	"flag"
	"log"
	"net/http"
	"os/signal"
	"syscall"
)

func main() {
	initCert := flag.Bool("init-cert", false, "write a self-signed certificate if it does not exist")
	certPath := flag.String("cert", "/home/mtproxy/runtime/fallback.crt", "certificate file")
	keyPath := flag.String("key", "/home/mtproxy/runtime/fallback.key", "private key file")
	httpListen := flag.String("http", ":80", "public HTTP listen address")
	httpsListen := flag.String("https", ":443", "public HTTPS listen address")
	mtp := flag.String("mtp", "127.0.0.1:8443", "local MTProxy address")
	nginxHTTP := flag.String("nginx-http", "127.0.0.1:8080", "local nginx HTTP address")
	nginxTLS := flag.String("nginx-tls", "127.0.0.1:8444", "local nginx TLS address")
	fallback := flag.String("fallback", "local", "local or upstream")
	domain := flag.String("domain", "", "camouflage domain used when fallback is upstream")
	whitelistFile := flag.String("whitelist", "/home/mtproxy/runtime/ip_white.conf", "whitelist file")
	whitelistMode := flag.String("whitelist-mode", "IPSEG", "OFF, IP, or IPSEG")
	whitelistPath := flag.String("whitelist-path", "/add.php", "HTTP path that records the client IP")
	secretHex := flag.String("secret", "", "16-byte proxy secret as 32 hex characters")
	flag.Parse()

	if *initCert {
		if err := writeCert(*certPath, *keyPath); err != nil {
			log.Fatalf("生成证书失败: %v", err)
		}
		return
	}

	secret, err := hex.DecodeString(*secretHex)
	if err != nil || len(secret) != 16 {
		log.Fatal("secret 必须是 32 位十六进制")
	}
	cfg := config{
		httpListen:    *httpListen,
		httpsListen:   *httpsListen,
		mtp:           *mtp,
		nginxHTTP:     *nginxHTTP,
		nginxTLS:      *nginxTLS,
		fallback:      *fallback,
		domain:        *domain,
		whitelistPath: *whitelistPath,
		whitelistFile: *whitelistFile,
		whitelistMode: *whitelistMode,
		secret:        secret,
	}
	list, err := loadWhitelist(cfg.whitelistFile, cfg.whitelistMode)
	if err != nil {
		log.Fatalf("读取白名单失败: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	err = serve(ctx, cfg, list)
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("入口停止: %v", err)
	}
}
