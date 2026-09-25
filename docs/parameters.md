# 参数

Docker 的环境变量和脚本目录里的 `config` 使用同名变量。容器启动时会把环境变量写进 `config`，再按同一套规则运行。留空的变量使用下面的默认值。

`proxy_mode` 不写时是 Fake TLS。写成 `web` 才进入 WEB 代理。

## Fake TLS

| 变量 | 默认 | 说明 |
|---|---|---|
| `secret` | 随机 32 位十六进制 | 客户端密钥。Docker 不写时自动生成，到日志里看 |
| `port` | `8443` | 容器内 MTProxy 的端口。入口程序把通过检查的连接转到 `127.0.0.1:8443`。发布端口用 `-p 宿主机:443`，客户端填宿主机那个端口 |
| `domain` | `cloudflare.com` | FakeTLS 伪装域名，也是 `https_fallback=upstream` 时的转发目标 |
| `adtag` | 空 | 32 位推广 TAG。只有需要 [MTProxybot](https://t.me/MTProxybot) 推广时才填 |
| `provider` | `1` | `1` 官方 MTProxy，只走中间服务器，不需要 adtag 时不必选。`2` mtg。`3` mtprotoproxy。后两个支持多平台和 adtag |
| `statport` | `8888` | 统计端口，只在本机 |
| `ip_white_list` | `IPSEG` | `OFF` 关闭。`IP` 访问登记地址后记下这个 IP。`IPSEG` 记下 IPv4 的 /24，IPv6 只记单个地址。`AUTO` 认出 FakeTLS 就放行并记下该 IP。WEB 模式不使用 |
| `whitelist_path` | `/add.php` | `IP` 和 `IPSEG` 的登记路径。只有 80 端口上这个路径会写名单 |
| `https_fallback` | `local` | 443 上未通过检查的连接。`local` 交给本机私有证书网站，内容和 80 端口相同。`upstream` 原样交给 `domain` 的真实站点 |

80 端口始终是本机网站。登记路径之外的请求不写名单。

## WEB 代理

实验功能。外层已经是 HTTPS，里面的 MTProxy 不再做 FakeTLS。

| 变量 | 默认 | 说明 |
|---|---|---|
| `proxy_mode` | `tls` | 写成 `web` |
| `secret` | 随机 32 位十六进制 | 32 位十六进制，或前面再加 `dd`。官方 MTProxy 不接受 `dd` |
| `provider` | `2` | 同上。WEB 默认是 mtg |
| `adtag` | 空 | 可空 |
| `statport` | `8888` | 只在本机 |
| `web_hostname` | 无，必填 | 小写公网域名，至少包含一个点 |
| `web_email` | 无 | `web_front=caddy` 时必填，用来申请证书 |
| `web_front` | `caddy` | `caddy` 占用容器内 80 和 443。`external` 不启动 Caddy，由外面的网站反代 |
| `web_listen` | `127.0.0.1:8080` | 见下文 |
| `web_fallback` | 无，必填 | 伪装站。见下文 |
| `web_backend` | `127.0.0.1:2398` | MTProxy 地址，必须是数字回环 |
| `web_carrier` | `https` | `https`、`https-lanes`、`websocket`、`websocket-lanes` |
| `web_tproxy_listen` | `127.0.0.1:8080` | `web_listen` 不是回环时，tproxy 实际听这里 |
| `web_admin_listen` | `127.0.0.1:8081` | 管理端口，必须是数字回环 |
| `web_upstream_listen` | `http://127.0.0.1:30000` | 伪装站需要转发时，tproxy 连接这个本机地址 |
| `web_token_key` | `token.key` | 相对路径相对于 `runtime/`。绝对路径照写。文件不存在时生成 32 字节；已存在则必须正好 32 字节 |
| `web_static_routes` | `exact` | 伪装站是本地目录时使用。另一个值是 `legacy` |

`domain` 和 `port` 在 WEB 模式不使用。

### web_listen

- `127.0.0.1:8080` 或 `[::1]:端口`：tproxy 直接听这个地址。内置 Caddy 用这个。
- `0.0.0.0:18080` 这类非回环地址：tproxy 改听 `web_tproxy_listen`，再由中转程序把 `web_listen` 上的字节转到那里。别的容器或宿主机上的网站反代到这个地址。

### web_fallback

- `public` 这种相对路径：相对于脚本目录。容器里就是 `/home/mtproxy/public`，该目录要有 `index.html`。
- `/某个目录`：绝对路径，同样要有 `index.html`。
- `http://127.0.0.1:端口`：原样交给 tproxy，不再转发。
- 其它 `http://主机[:端口]` 或 `https://主机[:端口]`：由中转程序转发。不能带账号、路径、查询或 `#`。末尾不要加 `/`。

### 外面已经有网站时

反代目标是 tproxy 实际监听的地址，并保留原始 Host。

- 同一台机器上的 Nginx 或 Caddy：转到 `127.0.0.1:8080`。
- 别的容器：转到 `web_listen`，例如 `0.0.0.0:18080`。

经过 Cloudflare 时，反代必须设置：

```nginx
proxy_set_header X-Forwarded-For $http_cf_connecting_ip;
```

这个值只能有一个 IP。建议关闭 `/?bridge=` 缓存、Rocket Loader、Auto Minify、Email Obfuscation、Bot Fight Mode、I'm Under Attack 和托管质询。

## 运行中生成的文件

手改的是根目录的 `config`。下面这些在 `runtime/`，删掉后下次启动会重新生成。`token.key` 重新生成后，已有的 WEB 会话标记失效。

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

`bin/` 只放程序。Caddy 的证书在 `runtime/caddy/`。
