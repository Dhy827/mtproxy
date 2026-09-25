<div align="right">
  <a title="简体中文" href="README.md"><img src="https://img.shields.io/badge/-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-545759?style=for-the-badge" alt="简体中文" /></a>
  <a title="English" href="README_EN.md"><img src="https://img.shields.io/badge/-English-A31F34?style=for-the-badge" alt="English"></a>
</div>

# mtproxy

A one-click installer for an MTProxy that Telegram clients can connect to. Fake TLS and an AdTag are supported by default.

It can also put Nginx in front of MTProxy so the traffic looks like a normal site. An IP whitelist on that front door allows only approved addresses through.

> A Docker image is provided for this setup.

## Community

Telegram group: [https://t.me/EllerHK](https://t.me/EllerHK)

## Installation

Two ways:

- Script (Debian/Ubuntu is the better host)
  This installs or builds on the machine and may pull in system packages.

- Docker (any system that runs Docker)
  **Docker is the easier choice.** It does not install those packages on the host. Changing a config file takes a little Docker knowledge.

### Script

> If the script keeps failing, use Debian 9 or newer, or switch to Docker.

```bash
rm -rf /home/mtproxy && mkdir /home/mtproxy && cd /home/mtproxy
curl -fsSL -o mtproxy.sh https://github.com/ellermister/mtproxy/raw/master/mtproxy.sh
bash mtproxy.sh
```

 ![mtproxy.sh](https://raw.githubusercontent.com/ellermister/mtproxy/master/preview.jpg)

### Docker

Use either the image or the script, not both. The commands below are ready to copy. The full parameter list is in [docs/parameters.en.md](docs/parameters.en.md).

**If Docker is not installed:**

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
```

**Fake TLS with the default IP-segment whitelist (recommended)**

```bash
docker run -d \
--name mtproxy \
--restart=always \
-e domain="cloudflare.com" \
-p 8080:80 \
-p 8443:443 \
ellermister/mtproxy
```

Add `-e ip_white_list="OFF"` to disable the whitelist. Clients connect to the published port `8443`.

**WEB proxy (experimental)**

The server can bind ports 80 and 443. Caddy inside the container requests a certificate and serves HTTPS. Point the domain at this machine first. `web_listen` stays on loopback; Caddy reaches it inside the container, so do not publish `18080`.

```bash
docker run -d \
--name mtproxy \
--restart=always \
-e secret="548593a9c0688f4f7d9d57377897d964" \
-e proxy_mode="web" \
-e web_hostname="your-domain-replace.it" \
-e web_email="you@example.com" \
-e web_fallback="public" \
-e web_front="caddy" \
-e web_listen="127.0.0.1:8080" \
-p 80:80 \
-p 443:443 \
ellermister/mtproxy
```

No permission for ports 80 and 443, or a web server is already in front. Reverse-proxy that site to `18080` on the host or on this container, and keep the original Host header.

```bash
docker run -d \
--name mtproxy \
--restart=always \
-e secret="548593a9c0688f4f7d9d57377897d964" \
-e proxy_mode="web" \
-e web_hostname="your-domain-replace.it" \
-e web_fallback="public" \
-e web_front="external" \
-e web_listen="0.0.0.0:18080" \
-p 18080:18080 \
ellermister/mtproxy
```

`web_fallback="public"` is a path relative to the script directory. In the image that is `/home/mtproxy/public`, which already contains `index.html`. You can instead use `https://host` with no trailing slash.

**Read the link from the logs:**

```bash
docker logs -f mtproxy
```

**Common parameters**

`provider`:

- **1** Official MTProxy. Poor compatibility, and it only connects through Telegram's middle servers. Skip it when you do not need an adtag
- **2** mtg, the Go build. More architectures, and it supports an adtag. This is the WEB default
- **3** mtprotoproxy, the Python build. More architectures, and it supports an adtag

`ip_white_list` applies only to Fake TLS:

- **OFF** disables the whitelist
- **IP** records the visitor of the registration URL
- **IPSEG** records the IPv4 /24. This is the default
- **AUTO** accepts a valid FakeTLS handshake and records that IP

`secret` is 32 hexadecimal characters. Leave it empty and the container generates one; read it from the logs.

Everything else, including camouflage sites and reverse-proxy notes, is in [docs/parameters.en.md](docs/parameters.en.md).

## Usage

Settings live in `config`. Keep the assignment format if you edit it by hand.

Start

```bash
bash mtproxy.sh start
```

Debug

```bash
bash mtproxy.sh debug
```

Stop

```bash
bash mtproxy.sh stop
```

Restart

```bash
bash mtproxy.sh restart
```

Reinstall or reconfigure

```bash
bash mtproxy.sh reinstall
```

## Uninstall

Delete the directory.

```bash
rm -rf /home/mtproxy
```

## Start on boot

> The script is not installed as a system service. Add it to your boot script.

If `/etc/rc.local` is missing, check how this system runs boot scripts. Add:

```bash
cd /home/mtproxy && bash mtproxy.sh start > /dev/null 2>&1 &
```

## Crontab

The official mtproxy binary mishandles a PID above 65535 and can exit. A crontab entry keeps it up. Run `crontab -e` and add:

```bash
* * * * * cd /home/mtproxy && bash mtproxy.sh start > /dev/null 2>&1 &
```

## MTProxy Admin Bot

[https://t.me/MTProxybot](https://t.me/MTProxybot)

> Sorry, an error has occurred during your request. Please try again later.(Code xxxxxx)

Telegram does not document this error. Reports usually come from accounts younger than two or three years.  
**Use an account older than three years that has not been banned.**

## References

- [https://github.com/TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy)
- [https://github.com/9seconds/mtg](https://github.com/9seconds/mtg)
- [https://github.com/alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy)
- [https://github.com/telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server)
