<div align="right">
  <a title="简体中文" href="README.md"><img src="https://img.shields.io/badge/-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-A31F34?style=for-the-badge" alt="简体中文" /></a>
  <a title="English" href="README_EN.md"><img src="https://img.shields.io/badge/-English-545759?style=for-the-badge" alt="English"></a>
</div>

# mtproxy

这是一个一键安装 MTProxy 代理的自动化脚本, 用于 Telegram 客户端进行连接。脚本默认支持 Fake TLS 和 AdTag 配置。

在此基础上，提供了 Nginx 作为前端转发，MTProxy 作为后端代理的方式以实现安全的伪装。并且在 Nginx 转发层进行配置了 IP 白名单，只有通过白名单认证过的 IP 才可以进行访问。

> 此功能提供了 Docker 镜像以便开箱即用。

## 交流群组

Telegram 群组：[https://t.me/EllerHK](https://t.me/EllerHK)

## 安装方式

提供了两种安装方式可供选择：

- 使用脚本 (建议 Debian/Ubuntu)
  选择该方式一般是你在宿主机中进行直接安装或者编译，会或多或少需要安装一些系统基础依赖库。
- 使用 Docker (任意支持docker的系统均可)
  **小白建议使用 Docker!** 不会对宿主机造成污染，如果你需要修改一些配置文件，需要你稍微学习一些基础 Docker 使用技术。



### 使用脚本

> 如果你反复遇到错误或者其他未知问题, 建议更换为 Debian 9+ 以上的系统或采用 Docker 方式运行。

执行如下代码进行安装

```bash
rm -rf /home/mtproxy && mkdir /home/mtproxy && cd /home/mtproxy
curl -fsSL -o mtproxy.sh https://github.com/ellermister/mtproxy/raw/master/mtproxy.sh
bash mtproxy.sh
```

 ![mtproxy.sh](https://raw.githubusercontent.com/ellermister/mtproxy/master/preview.jpg)

### 使用 Docker

镜像和脚本二选一。下面是可以直接复制的启动命令。参数的完整说明见 [docs/parameters.md](docs/parameters.md)。

**如果没有安装 Docker**：

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
```

**Fake TLS，默认 IP 段白名单（推荐）**

```bash
docker run -d \
--name mtproxy \
--restart=always \
-e domain="cloudflare.com" \
-p 8080:80 \
-p 8443:443 \
ellermister/mtproxy
```

不需要白名单时加上 `-e ip_white_list="OFF"`。连接端口用映射出来的 `8443`。

**WEB 代理（实验）**

有 80、443 权限，由容器里的 Caddy 申请证书并托管 HTTPS。域名要先解析到这台机器。`web_listen` 用回环地址，Caddy 在容器内访问它，不必映射 `18080`。

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

没有 80、443 权限，或前面已经有 Nginx、Caddy、其它容器。把那个网站反代到宿主机或该容器的 `18080`，并保留原始 Host。

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

`web_fallback="public"` 是相对路径，对应容器里的 `/home/mtproxy/public`，里面已有 `index.html`。也可以改成 `https://主机`，末尾不要加 `/`。

**在日志中查看链接**：

```bash
docker logs -f mtproxy
```

**常用参数**

`provider`：

- **1** 官方 MTProxy C 程序。兼容差，只支持中间服务器。不需要 adtag 时不必选它
- **2** mtg，Golang 版本。支持多平台，支持 adtag。WEB 模式默认就是这个
- **3** mtprotoproxy，Python 版本。支持多平台，支持 adtag

`ip_white_list` 只用于 Fake TLS：

- **OFF** 关闭白名单
- **IP** 访问登记地址后写入这个 IP
- **IPSEG** 访问登记地址后写入 IPv4 的 /24。默认是这个
- **AUTO** 认出 FakeTLS 就放行，并记下该 IP

`secret` 是 32 位十六进制。留空则容器自己生成，到日志里看。

其余参数、伪装站写法和反代注意项见 [docs/parameters.md](docs/parameters.md)。

## 使用方式

配置文件 `config`，如果你想手动修改密钥或者参数请注意格式。

运行服务

```bash
bash mtproxy.sh start
```

调试运行

```bash
bash mtproxy.sh debug
```

停止服务

```bash
bash mtproxy.sh stop
```

重启服务

```bash
bash mtproxy.sh restart
```

重新安装/重新配置

```bash
bash mtproxy.sh reinstall
```



## 卸载安装

因为是绿色版卸载极其简单，直接删除所在目录即可。

```bash
rm -rf /home/mtproxy
```



## 开机启动

> 该脚本没有配置为系统服务的方式，你可以将其添加到开机启动脚本中。

开机启动脚本，如果你的 rc.local 文件不存在请检查开机自启服务。

通过编辑文件`/etc/rc.local`将如下代码加入到开机自启脚本中：

```bash
cd /home/mtproxy && bash mtproxy.sh start > /dev/null 2>&1 &
```



## 计划任务守护

由于默认官方的 mtproxy 程序存在BUG，在 pid 大于 65535 时进程处理存在问题，进程容易坏死和异常退出。

因此建议通过计划任务去守护进程 `crontab -e` ：

每分钟检测进程并启动

```bash
* * * * * cd /home/mtproxy && bash mtproxy.sh start > /dev/null 2>&1 &
```



## MTProxy Admin Bot

[https://t.me/MTProxybot](https://t.me/MTProxybot)

> Sorry, an error has occurred during your request. Please try again later.(Code xxxxxx)

如果你在申请绑定代理推广时遇到了此类错误，官方没有给出明确的原因。根据网友反馈，此类问题多出现于账号注册不足与 2~3 年。  
**建议使用 3 年以上的账号以及未被 banned 的账号。**

## 引用项目

- [https://github.com/TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy)
- [https://github.com/9seconds/mtg](https://github.com/9seconds/mtg)
- [https://github.com/alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy)
- [https://github.com/telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server)

