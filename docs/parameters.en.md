# Parameters

Docker environment variables use the same names as the `config` file in the script directory. On startup the container writes those variables into `config` and follows the same rules. Empty values use the defaults below.

`proxy_mode` defaults to Fake TLS. Set it to `web` for WEB proxy mode.

## Fake TLS

| Variable | Default | Meaning |
|---|---|---|
| `secret` | random 32 hex characters | Client secret. Docker generates one when it is empty; read it from the logs |
| `port` | `8443` | MTProxy port inside the container. The front door forwards accepted connections to `127.0.0.1:8443`. Publish with `-p HOST:443`. Clients use the host port |
| `domain` | `cloudflare.com` | FakeTLS disguise domain, and the forward target when `https_fallback=upstream` |
| `adtag` | empty | 32-character promotion tag. Set it only when using [MTProxybot](https://t.me/MTProxybot) |
| `provider` | `1` | `1` official MTProxy. It only reaches Telegram through middle servers, so skip it when you do not need an adtag. `2` mtg. `3` mtprotoproxy. The latter two run on more than one architecture and support an adtag |
| `statport` | `8888` | Statistics port, loopback only |
| `ip_white_list` | `IPSEG` | `OFF` disables it. `IP` records the visitor of the registration path. `IPSEG` records the IPv4 /24; an IPv6 address is stored as itself. `AUTO` accepts a valid FakeTLS handshake and records that IP. Unused in WEB mode |
| `whitelist_path` | `/add.php` | Registration path for `IP` and `IPSEG`. Only this path on port 80 writes the list |
| `https_fallback` | `local` | Connections on 443 that do not pass. `local` serves the same site as port 80 with a private certificate. `upstream` splices the bytes to the real `domain` |

Port 80 is always the local site. Requests to other paths do not change the list.

## WEB proxy

Experimental. The outer layer is already HTTPS, so the inner MTProxy does not use FakeTLS.

| Variable | Default | Meaning |
|---|---|---|
| `proxy_mode` | `tls` | Set to `web` |
| `secret` | random 32 hex characters | 32 hex characters, optionally prefixed with `dd`. Official MTProxy rejects `dd` |
| `provider` | `2` | Same choices as above. WEB mode defaults to mtg |
| `adtag` | empty | Optional |
| `statport` | `8888` | Loopback only |
| `web_hostname` | required | Lowercase public domain with at least one dot |
| `web_email` | none | Required when `web_front=caddy`. Used to request a certificate |
| `web_front` | `caddy` | `caddy` binds ports 80 and 443 inside the container. `external` does not start Caddy; an existing site reverse-proxies to this container |
| `web_listen` | `127.0.0.1:8080` | See below |
| `web_fallback` | required | Camouflage site. See below |
| `web_backend` | `127.0.0.1:2398` | MTProxy address. Must be a numeric loopback address |
| `web_carrier` | `https` | `https`, `https-lanes`, `websocket`, or `websocket-lanes` |
| `web_tproxy_listen` | `127.0.0.1:8080` | Where tproxy actually listens when `web_listen` is not loopback |
| `web_admin_listen` | `127.0.0.1:8081` | Admin port. Must be numeric loopback |
| `web_upstream_listen` | `http://127.0.0.1:30000` | Local address tproxy dials when the camouflage site is forwarded |
| `web_token_key` | `token.key` | A relative path is inside `runtime/`. An absolute path is used as written. A missing file is created as 32 bytes. An existing file must already be exactly 32 bytes |
| `web_static_routes` | `exact` | Used when the camouflage site is a local directory. The other value is `legacy` |

`domain` and `port` are not used in WEB mode.

### web_listen

- `127.0.0.1:8080` or `[::1]:port`: tproxy listens there directly. Use this with the built-in Caddy.
- A non-loopback address such as `0.0.0.0:18080`: tproxy listens on `web_tproxy_listen`, and a relay copies bytes from `web_listen` to it. Point another container or a reverse proxy on the host at this address.

### web_fallback

- A relative path such as `public` is resolved from the script directory. In the image that is `/home/mtproxy/public`, which already contains `index.html`.
- An absolute path must also contain `index.html`.
- `http://127.0.0.1:port` is passed to tproxy as-is.
- Any other `http://host[:port]` or `https://host[:port]` is forwarded by the relay. No userinfo, path, query, or fragment. Do not add a trailing `/`.

### An existing web server

Proxy to the address tproxy actually listens on, and keep the original Host header.

- Nginx or Caddy on the same machine: `127.0.0.1:8080`.
- Another container: `web_listen`, for example `0.0.0.0:18080`.

Behind Cloudflare, the proxy must set:

```nginx
proxy_set_header X-Forwarded-For $http_cf_connecting_ip;
```

That value must be a single IP. Prefer to disable caching of `/?bridge=`, Rocket Loader, Auto Minify, Email Obfuscation, Bot Fight Mode, I'm Under Attack, and managed challenges.

## Files created at runtime

Edit `config` in the project root. The files below live in `runtime/` and are recreated on the next start. A new `token.key` invalidates existing WEB session tokens.

```text
runtime/tproxy.json
runtime/profiles.json
runtime/token.key
runtime/Caddyfile
runtime/proxy-multi.conf
runtime/proxy-secret
runtime/config.py
runtime/ip_white.conf
runtime/ip_white_mode
runtime/fallback.crt
runtime/fallback.key
runtime/pid/
runtime/log/
runtime/caddy/
```

`bin/` contains programs only. Caddy certificates are in `runtime/caddy/`.
