#!/bin/bash

TPROXY_JSON_PATH=$RUNTIME_DIR/tproxy.json
PROFILES_JSON_PATH=$RUNTIME_DIR/profiles.json
CADDYFILE_PATH=$RUNTIME_DIR/Caddyfile
LOG_DIR=$RUNTIME_DIR/log
BINARY_TPROXY_SERVER_PATH=$WORKDIR/bin/tproxy-server
BINARY_TPROXY_RELAY_PATH=$WORKDIR/bin/tproxy-relay
BINARY_CADDY_PATH=$WORKDIR/bin/caddy
CADDY_VERSION=2.10.2

is_web_mode() {
    [[ -f "$CONFIG_PATH" ]] || return 1
    grep -q '^proxy_mode="web"$' "$CONFIG_PATH"
}

json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/}
    value=${value//$'\r'/}
    printf '%s' "$value"
}

split_host_port() {
    local address=$1
    if [[ "$address" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        SPLIT_HOST=${BASH_REMATCH[1]}
        SPLIT_PORT=${BASH_REMATCH[2]}
    elif [[ "$address" =~ ^([^:]+):([0-9]+)$ ]]; then
        SPLIT_HOST=${BASH_REMATCH[1]}
        SPLIT_PORT=${BASH_REMATCH[2]}
    else
        return 1
    fi
    [[ "$SPLIT_PORT" -ge 1 && "$SPLIT_PORT" -le 65535 ]]
}

is_loopback_host() {
    local host=$1
    if [[ "$host" == "::1" ]]; then
        return 0
    fi
    if [[ "$host" =~ ^127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        [[ ${BASH_REMATCH[1]} -le 255 && ${BASH_REMATCH[2]} -le 255 && ${BASH_REMATCH[3]} -le 255 ]]
        return
    fi
    return 1
}

web_apply_defaults() {
    web_listen=${web_listen:-127.0.0.1:8080}
    web_front=${web_front:-caddy}
    web_backend=${web_backend:-127.0.0.1:2398}
    web_carrier=${web_carrier:-https}
    web_tproxy_listen=${web_tproxy_listen:-127.0.0.1:8080}
    web_admin_listen=${web_admin_listen:-127.0.0.1:8081}
    web_upstream_listen=${web_upstream_listen:-http://127.0.0.1:30000}
    web_token_key=${web_token_key:-token.key}
    web_static_routes=${web_static_routes:-exact}
    web_email=${web_email:-}
    statport=${statport:-8888}
    adtag=${adtag:-}
    provider=${provider:-2}
}

web_reject_quote() {
    local name=$1
    local value=$2
    if [[ "$value" == *\"* || "$value" == *$'\n'* ]]; then
        print_error_exit "$name 不能包含引号或换行"
    fi
}

web_classify_listen() {
    split_host_port "$web_listen" || print_error_exit "web_listen 必须写成 地址:端口"
    if is_loopback_host "$SPLIT_HOST"; then
        WEB_JSON_LISTEN=$web_listen
        WEB_TCP_RELAY=0
        return
    fi
    WEB_TCP_LISTEN=$web_listen
    split_host_port "$web_tproxy_listen" || print_error_exit "web_tproxy_listen 必须写成 地址:端口"
    is_loopback_host "$SPLIT_HOST" || print_error_exit "web_tproxy_listen 必须是数字回环地址"
    WEB_JSON_LISTEN=$web_tproxy_listen
    WEB_TCP_TARGET=$web_tproxy_listen
    WEB_TCP_RELAY=1
}

web_hostport_is_loopback() {
    split_host_port "$1" || return 1
    is_loopback_host "$SPLIT_HOST"
}

web_fallback_dir() {
    local path=${web_fallback%/}
    if [[ "$path" != /* ]]; then
        path="$WORKDIR/$path"
    fi
    printf '%s' "$path"
}

web_classify_fallback() {
    WEB_HTTP_RELAY=0
    WEB_ERROR=""
    WEB_FALLBACK_DIR=""
    if [[ "$web_fallback" =~ ^https?:// ]]; then
        local rest=${web_fallback#*://}
        if [[ "$rest" == *@* || "$rest" == *\?* || "$rest" == *#* || "$rest" == */* ]]; then
            WEB_ERROR="web_fallback 只能是 http(s)://主机[:端口]，不能带账号、路径、查询或片段"
            return 1
        fi
        if [[ "$web_fallback" =~ ^http://(.+)$ ]]; then
            local hostport=${BASH_REMATCH[1]}
            if web_hostport_is_loopback "$hostport"; then
                WEB_PUBLIC_KIND=direct
                return 0
            fi
        fi
        WEB_PUBLIC_KIND=relay
        WEB_HTTP_RELAY=1
        return 0
    fi
    WEB_FALLBACK_DIR=$(web_fallback_dir)
    if [[ ! -f "$WEB_FALLBACK_DIR/index.html" ]]; then
        WEB_ERROR="web_fallback 目录里必须有 index.html: $WEB_FALLBACK_DIR"
        return 1
    fi
    WEB_PUBLIC_KIND=dir
    return 0
}

web_classify_upstream() {
    if [[ ! "$web_upstream_listen" =~ ^http://([^/]+)$ ]]; then
        print_error_exit "web_upstream_listen 必须是 http://回环地址:端口"
    fi
    local hostport=${BASH_REMATCH[1]}
    web_hostport_is_loopback "$hostport" || print_error_exit "web_upstream_listen 必须指向数字回环地址"
    WEB_HTTP_BIND=$hostport
}

web_add_port() {
    local port=$1
    local why=$2
    local item existing_port existing_why
    for item in "${WEB_BIND_PORTS[@]}"; do
        existing_port=${item%%:*}
        existing_why=${item#*:}
        if [[ "$existing_port" == "$port" ]]; then
            print_error_exit "端口 $port 同时用于${existing_why}和${why}"
        fi
    done
    WEB_BIND_PORTS+=("$port:$why")
}

web_check_ports() {
    WEB_BIND_PORTS=()
    split_host_port "$WEB_JSON_LISTEN" || print_error_exit "tproxy 监听地址无效"
    web_add_port "$SPLIT_PORT" "tproxy"
    split_host_port "$web_admin_listen" || print_error_exit "web_admin_listen 必须写成 地址:端口"
    is_loopback_host "$SPLIT_HOST" || print_error_exit "web_admin_listen 必须是数字回环地址"
    WEB_ADMIN_LISTEN=$web_admin_listen
    web_add_port "$SPLIT_PORT" "管理端口"
    split_host_port "$web_backend" || print_error_exit "web_backend 必须写成 地址:端口"
    is_loopback_host "$SPLIT_HOST" || print_error_exit "web_backend 必须是数字回环地址"
    web_add_port "$SPLIT_PORT" "MTProxy"
    [[ "$statport" =~ ^[0-9]+$ ]] || print_error_exit "statport 必须是端口"
    web_add_port "$statport" "统计端口"
    if [[ "$WEB_TCP_RELAY" == 1 ]]; then
        split_host_port "$WEB_TCP_LISTEN" || print_error_exit "web_listen 无效"
        web_add_port "$SPLIT_PORT" "TCP 中转"
    fi
    if [[ "$WEB_HTTP_RELAY" == 1 ]]; then
        web_classify_upstream
        split_host_port "$WEB_HTTP_BIND" || print_error_exit "web_upstream_listen 无效"
        web_add_port "$SPLIT_PORT" "HTTP 中转"
    fi
    if [[ "$web_front" == "caddy" ]]; then
        web_add_port 80 "Caddy"
        web_add_port 443 "Caddy"
    fi
}

web_validate_config() {
    web_apply_defaults
    [[ "$provider" =~ ^[1-3]$ ]] || print_error_exit "provider 只能是 1、2 或 3"
    local arch
    arch=$(get_architecture)
    if [[ "$arch" != "amd64" && "$provider" == "1" ]]; then
        print_warning "当前架构不支持官方 MTProxy，改用 mtg"
        provider=2
    fi
    [[ "$secret" =~ ^([0-9a-fA-F]{32}|[Dd][Dd][0-9a-fA-F]{32})$ ]] || print_error_exit "web 模式的 secret 必须是 32 位十六进制，或 dd 加 32 位"
    if [[ "$provider" == "1" && "$secret" =~ ^[Dd][Dd] ]]; then
        print_error_exit "官方 MTProxy 不支持 dd 密钥。请填写 32 位密钥，或把 provider 改为 2 或 3"
    fi
    [[ -n "$web_hostname" ]] || print_error_exit "web_hostname 不能为空"
    [[ "$web_hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || print_error_exit "web_hostname 必须是小写域名"
    [[ "$web_front" == "caddy" || "$web_front" == "external" ]] || print_error_exit "web_front 只能是 caddy 或 external"
    if [[ "$web_front" == "caddy" ]]; then
        [[ "$web_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || print_error_exit "web_front=caddy 时必须填写 web_email"
    fi
    case "$web_carrier" in
        https|https-lanes|websocket|websocket-lanes) ;;
        *) print_error_exit "web_carrier 只能是 https、https-lanes、websocket、websocket-lanes" ;;
    esac
    [[ "$web_static_routes" == "exact" || "$web_static_routes" == "legacy" ]] || print_error_exit "web_static_routes 只能是 exact 或 legacy"
    web_reject_quote web_hostname "$web_hostname"
    web_reject_quote web_fallback "$web_fallback"
    web_reject_quote web_email "$web_email"
    web_classify_listen
    web_classify_fallback || print_error_exit "$WEB_ERROR"
    web_check_ports
    if [[ "$web_token_key" == /* ]]; then
        WEB_TOKEN_PATH=$web_token_key
    else
        WEB_TOKEN_PATH=$RUNTIME_DIR/$web_token_key
    fi
}

web_ensure_token() {
    if [[ -f "$WEB_TOKEN_PATH" ]]; then
        local size
        size=$(wc -c < "$WEB_TOKEN_PATH" | tr -d ' ')
        if [[ "$size" != "32" ]]; then
            print_error_exit "token.key 必须是既有的 32 字节文件。确认不再需要旧会话标记后，再删除它并重新启动"
        fi
        chmod 0400 "$WEB_TOKEN_PATH"
        return
    fi
    mkdir -p "$(dirname "$WEB_TOKEN_PATH")"
    (umask 077; dd if=/dev/urandom of="$WEB_TOKEN_PATH" bs=32 count=1 status=none)
    chmod 0400 "$WEB_TOKEN_PATH"
}

web_write_profiles() {
    (
        umask 077
        cat > "$PROFILES_JSON_PATH" <<EOF
{
  "profiles": [
    {
      "name": "default",
      "secret": "$(json_escape "$secret")",
      "backend": "$web_backend",
      "carrier_mode": "$web_carrier"
    }
  ]
}
EOF
    )
    chmod 0400 "$PROFILES_JSON_PATH"
}

web_write_tproxy_json() {
    local public_fields
    if [[ "$WEB_PUBLIC_KIND" == "dir" ]]; then
        public_fields=$(cat <<EOF
  "public_dir": "$(json_escape "$WEB_FALLBACK_DIR")",
  "static_routes": "$web_static_routes",
EOF
)
    elif [[ "$WEB_PUBLIC_KIND" == "direct" ]]; then
        public_fields=$(cat <<EOF
  "public_upstream": "$(json_escape "$web_fallback")",
EOF
)
    else
        public_fields=$(cat <<EOF
  "public_upstream": "$(json_escape "$web_upstream_listen")",
EOF
)
    fi
    cat > "$TPROXY_JSON_PATH" <<EOF
{
  "public_hostname": "$(json_escape "$web_hostname")",
  "listen": "$WEB_JSON_LISTEN",
  "admin_listen": "$WEB_ADMIN_LISTEN",
$public_fields
  "token_key_file": "$(json_escape "$WEB_TOKEN_PATH")",
  "profiles_file": "$(json_escape "$PROFILES_JSON_PATH")"
}
EOF
}

web_write_caddyfile() {
    cat > "$CADDYFILE_PATH" <<EOF
{
	email $web_email
	admin off
	servers {
		protocols h1 h2
		timeouts {
			read_header 10s
			read_body 60s
		}
	}
}

$web_hostname {
	encode zstd gzip
	header {
		-Via
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
	}
	reverse_proxy $WEB_JSON_LISTEN {
		transport http {
			response_header_timeout 40s
		}
	}
	handle_errors {
		header {
			Cache-Control "no-store"
			Strict-Transport-Security "max-age=31536000; includeSubDomains"
		}
		respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
	}
}
EOF
}

web_write_python_config() {
    local py_secret=$secret
    local classic=True
    local secure=False
    if [[ "$secret" =~ ^[Dd][Dd]([0-9a-fA-F]{32})$ ]]; then
        py_secret=${BASH_REMATCH[1]}
        classic=False
        secure=True
    fi
    split_host_port "$web_backend"
    mkdir -p "$RUNTIME_DIR"
    cat > "$RUNTIME_DIR/config.py" <<EOF
PORT = ${SPLIT_PORT}
LISTEN_ADDR_IPV4 = "${SPLIT_HOST}"
LISTEN_ADDR_IPV6 = ""
USERS = {
    "tg": "${py_secret}",
}
MODES = {
    "classic": ${classic},
    "secure": ${secure},
    "tls": False,
}
TLS_DOMAIN = ""
AD_TAG = "${adtag}"
EOF
}

web_prepare_mtp_command() {
    local provider_name
    provider_name=$(get_mtg_provider)
    if [[ "$provider_name" == "mtg" ]]; then
        [[ -x "$BINARY_MTG_PATH" ]] || print_error_exit "缺少 mtg，请先安装"
        [[ -n "$PUBLIC_IP" ]] || print_error_exit "没有公网 IP，mtg 无法启动"
        split_host_port "$web_backend"
        CMD_mtp=("$BINARY_MTG_PATH" run "$secret")
        if [[ -n "$adtag" ]]; then
            CMD_mtp+=("$adtag")
        fi
        CMD_mtp+=(-b "$web_backend" --multiplex-per-connection 500 --prefer-ip=ipv4 -t "127.0.0.1:$statport" -4 "${PUBLIC_IP}:${SPLIT_PORT}")
    elif [[ "$provider_name" == "python-mtprotoproxy" ]]; then
        [[ -f "$BINARY_PY_MTPROTOPROXY_PATH" ]] || print_error_exit "缺少 mtprotoproxy，请先执行 bash $0 install"
        web_write_python_config
        CMD_mtp=("$SYSTEM_PYTHON" "$BINARY_PY_MTPROTOPROXY_PATH" "$RUNTIME_DIR/config.py")
    elif [[ "$provider_name" == "official-MTProxy" ]]; then
        [[ -x "$BINARY_MTPROTO_PROXY_PATH" ]] || print_error_exit "缺少官方 MTProxy，请先执行 bash $0 install"
        mkdir -p "$RUNTIME_DIR"
        curl -fsSL --connect-timeout 10 --max-time 30 https://core.telegram.org/getProxyConfig -o "$RUNTIME_DIR/proxy-multi.conf" || print_error_exit "下载 proxy-multi.conf 失败"
        curl -fsSL --connect-timeout 10 --max-time 30 https://core.telegram.org/getProxySecret -o "$RUNTIME_DIR/proxy-secret" || print_error_exit "下载 proxy-secret 失败"
        local workers
        workers=$(get_cpu_core)
        split_host_port "$web_backend"
        CMD_mtp=("$BINARY_MTPROTO_PROXY_PATH" -u nobody -p "$statport" -H "$SPLIT_PORT" -S "$secret" --aes-pwd "$RUNTIME_DIR/proxy-secret" "$RUNTIME_DIR/proxy-multi.conf" -M "$workers")
        if [[ -n "$adtag" ]]; then
            CMD_mtp+=(-P "$adtag")
        fi
        CMD_mtp+=(--ipv6)
    else
        print_error_exit "未知的 MTProxy 程序"
    fi
}

web_prepare_commands() {
    CMD_tproxy=("$BINARY_TPROXY_SERVER_PATH" -config "$TPROXY_JSON_PATH")
    if [[ "$WEB_TCP_RELAY" == 1 ]]; then
        CMD_relay_tcp=("$BINARY_TPROXY_RELAY_PATH" -mode tcp -listen "$WEB_TCP_LISTEN" -target "$WEB_TCP_TARGET")
    fi
    if [[ "$WEB_HTTP_RELAY" == 1 ]]; then
        CMD_relay_http=("$BINARY_TPROXY_RELAY_PATH" -mode http -listen "$WEB_HTTP_BIND" -target "$web_fallback")
    fi
    if [[ "$web_front" == "caddy" ]]; then
        CMD_caddy=("$BINARY_CADDY_PATH" run --config "$CADDYFILE_PATH" --adapter caddyfile)
    fi
    web_prepare_mtp_command
}

ensure_go() {
    if command -v go >/dev/null 2>&1; then
        local version major
        version=$(go env GOVERSION 2>/dev/null || true)
        if [[ "$version" =~ ^go1\.([0-9]+) ]]; then
            major=${BASH_REMATCH[1]}
            if [[ "$major" -ge 22 ]]; then
                return 0
            fi
        fi
    fi
    local goarch
    goarch=$(get_architecture)
    mkdir -p "$WORKDIR/build"
    print_info "下载 Go 1.25.0 ($goarch)"
    wget -q "https://go.dev/dl/go1.25.0.linux-${goarch}.tar.gz" -O "$WORKDIR/build/go.tgz" || print_error_exit "下载 Go 失败"
    rm -rf "$WORKDIR/build/go"
    tar -C "$WORKDIR/build" -xzf "$WORKDIR/build/go.tgz"
    export PATH="$WORKDIR/build/go/bin:$PATH"
}

download_caddy() {
    local caddy_arch
    caddy_arch=$(get_architecture)
    case "$caddy_arch" in
        amd64|arm64|386) ;;
        armv6l) caddy_arch=armv6 ;;
        *) print_error_exit "没有对应架构的 Caddy: $caddy_arch" ;;
    esac
    local tmp
    tmp=$(mktemp -d)
    print_info "下载 Caddy ${CADDY_VERSION}"
    wget -q "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz" -O "$tmp/caddy.tgz" || print_error_exit "下载 Caddy 失败"
    tar -C "$tmp" -xzf "$tmp/caddy.tgz"
    mkdir -p "$WORKDIR/bin"
    mv "$tmp/caddy" "$BINARY_CADDY_PATH"
    chmod +x "$BINARY_CADDY_PATH"
    rm -rf "$tmp"
    print_info "已下载 caddy"
}

build_go_bins() {
    mkdir -p "$WORKDIR/bin"
    ensure_go
    [[ -f "$WORKDIR/relay/main.go" ]] || print_error_exit "缺少 relay 源码"
    print_info "编译 tproxy-relay"
    (cd "$WORKDIR/relay" && CGO_ENABLED=0 go build -trimpath -o "$BINARY_TPROXY_RELAY_PATH" .) || print_error_exit "编译 tproxy-relay 失败"
    chmod +x "$BINARY_TPROXY_RELAY_PATH"

    local src=""
    if [[ -f "$WORKDIR/../tproxy-server/go.mod" ]]; then
        src=$(readlink -f "$WORKDIR/../tproxy-server")
    else
        src=$WORKDIR/build/tproxy-server
        rm -rf "$src"
        print_info "获取 tproxy-server 源码"
        git clone --depth 1 https://github.com/telegramdesktop/tproxy-server.git "$src" || print_error_exit "克隆 tproxy-server 失败"
    fi
    print_info "编译 tproxy-server"
    (cd "$src" && CGO_ENABLED=0 go build -trimpath -o "$BINARY_TPROXY_SERVER_PATH" ./cmd/tproxy-server) || print_error_exit "编译 tproxy-server 失败"
    chmod +x "$BINARY_TPROXY_SERVER_PATH"
    rm -rf "$WORKDIR/build/tproxy-server"

    [[ -f "$WORKDIR/front/main.go" ]] || print_error_exit "缺少 front 源码"
    print_info "编译 front"
    (cd "$WORKDIR/front" && CGO_ENABLED=0 go build -trimpath -o "$WORKDIR/bin/front" .) || print_error_exit "编译 front 失败"
    chmod +x "$WORKDIR/bin/front"
    rm -rf "$WORKDIR/build/go" "$WORKDIR/build/go.tgz"
    print_info "已编译 tproxy-relay、tproxy-server 和 front"
}

web_require_bins() {
    local missing=()
    [[ -x "$BINARY_TPROXY_SERVER_PATH" ]] || missing+=("tproxy-server")
    [[ -x "$BINARY_TPROXY_RELAY_PATH" ]] || missing+=("tproxy-relay")
    if [[ "$web_front" == "caddy" && ! -x "$BINARY_CADDY_PATH" ]]; then
        missing+=("caddy")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error_exit "缺少 ${missing[*]}，请先执行 bash $0 install"
    fi
}

web_prepare() {
    cd "$WORKDIR"
    [[ -f "$CONFIG_PATH" ]] || print_error_exit "配置文件不存在"
    # shellcheck disable=SC1090
    source "$CONFIG_PATH"
    web_validate_config
    mkdir -p "$LOG_DIR" "$RUNTIME_DIR/pid" "$(dirname "$WEB_TOKEN_PATH")"
    web_require_bins
    web_ensure_token
    web_write_profiles
    web_write_tproxy_json
    if [[ "$web_front" == "caddy" ]]; then
        web_write_caddyfile
        mkdir -p "$RUNTIME_DIR/caddy"
    fi
    "$BINARY_TPROXY_SERVER_PATH" -config "$TPROXY_JSON_PATH" -check || print_error_exit "tproxy 配置校验失败"
    web_prepare_commands
}

web_spawn() {
    local name=$1
    shift
    mkdir -p "$LOG_DIR" "$RUNTIME_DIR/pid"
    {
        printf '\n==== %s start %s ====\n' "$(date '+%F %T')" "$name"
        printf 'command:'
        printf ' %q' "$@"
        printf '\n'
    } >> "$LOG_DIR/$name.log"
    "$@" >>"$LOG_DIR/$name.log" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$RUNTIME_DIR/pid/child-$name.pid"
}

web_ensure() {
    local restart=$1
    local name=$2
    shift 2
    local pidfile="$RUNTIME_DIR/pid/child-$name.pid"
    local pid=""
    if [[ -f "$pidfile" ]]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
    fi
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    if [[ "$WEB_STOPPING" == 1 ]]; then
        return 0
    fi
    if [[ "$restart" == 1 ]]; then
        print_warning "$name 已退出，正在重启"
    fi
    web_spawn "$name" "$@"
}

web_watch_children() {
    local restart=$1
    web_ensure "$restart" mtp "${CMD_mtp[@]}"
    web_ensure "$restart" tproxy "${CMD_tproxy[@]}"
    if [[ "$WEB_TCP_RELAY" == 1 ]]; then
        web_ensure "$restart" relay-tcp "${CMD_relay_tcp[@]}"
    fi
    if [[ "$WEB_HTTP_RELAY" == 1 ]]; then
        web_ensure "$restart" relay-http "${CMD_relay_http[@]}"
    fi
    if [[ "$web_front" == "caddy" ]]; then
        web_ensure "$restart" caddy "${CMD_caddy[@]}"
    fi
}

web_kill_recorded_children() {
    local file pid
    local found=0
    for file in "$RUNTIME_DIR"/pid/child-*.pid; do
        [[ -e "$file" ]] || continue
        found=1
        pid=$(cat "$file" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    [[ "$found" == 1 ]] || return 0
    sleep 1
    for file in "$RUNTIME_DIR"/pid/child-*.pid; do
        [[ -e "$file" ]] || continue
        pid=$(cat "$file" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$file"
    done
}

web_shutdown() {
    WEB_STOPPING=1
    trap - INT TERM
    web_kill_recorded_children
    rm -f "$PID_FILE"
    exit 0
}

web_supervise() {
    WEB_STOPPING=0
    cd "$WORKDIR"
    web_kill_recorded_children
    web_prepare
    echo $$ > "$PID_FILE"
    export XDG_DATA_HOME=$RUNTIME_DIR/caddy
    export XDG_CONFIG_HOME=$RUNTIME_DIR/caddy
    set -m
    trap web_shutdown INT TERM
    web_watch_children 0
    info_web ingore
    while [[ "$WEB_STOPPING" != 1 ]]; do
        sleep 2
        web_watch_children 1
    done
}

web_report_startup() {
    local name pidfile pid command_line
    if [[ -f "$LOG_DIR/mtp.log" ]]; then
        command_line=$(grep '^command:' "$LOG_DIR/mtp.log" | tail -n 1)
        if [[ -n "$command_line" ]]; then
            print_info "MTProxy ${command_line}"
        fi
    fi
    for name in mtp tproxy relay-tcp relay-http caddy; do
        pidfile="$RUNTIME_DIR/pid/child-$name.pid"
        [[ -f "$pidfile" ]] || continue
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        print_warning "$name 启动后退出了，最近日志："
        tail -n 20 "$LOG_DIR/$name.log" 2>/dev/null || true
    done
}

info_web() {
    # shellcheck disable=SC1090
    source "$CONFIG_PATH"
    web_apply_defaults
    if [[ "$1" == "ingore" ]] || is_running_mtp; then
        web_classify_listen
        web_classify_fallback
        echo -e "WEB 代理: \033[32m运行中\033[0m"
        echo -e "域名：\033[31m$web_hostname\033[0m"
        echo -e "Secret:  \033[31m$secret\033[0m"
        echo -e "TG 链接: https://t.me/webproxy?server=${web_hostname}&secret=${secret}"
        echo -e "TG 链接: tg://webproxy?server=${web_hostname}&secret=${secret}"
        echo -e "传输模式：\033[31m$web_carrier\033[0m"
        if [[ "$WEB_TCP_RELAY" == 1 ]]; then
            echo -e "给其它容器的入口：\033[31m$web_listen\033[0m"
        fi
        if [[ "$WEB_HTTP_RELAY" == 1 ]]; then
            echo -e "伪装站中转目标：\033[31m$web_fallback\033[0m"
        fi
        if [[ "$web_front" == "external" ]]; then
            echo "本机反代请指向 ${WEB_JSON_LISTEN}，并保留原始 Host。"
            if [[ "$WEB_TCP_RELAY" == 1 ]]; then
                echo "其它容器反代请指向 ${web_listen}。"
            fi
            echo "Cloudflare 必须设置：proxy_set_header X-Forwarded-For \$http_cf_connecting_ip;"
            echo "这个值只能有一个 IP。建议关闭 /?bridge= 缓存、Rocket Loader、Auto Minify、Email Obfuscation、Bot Fight Mode、I'm Under Attack 和托管质询。"
        else
            echo "Caddy 反代到 ${WEB_JSON_LISTEN}，证书目录在 runtime/caddy/"
        fi
        echo "日志目录: $LOG_DIR"
        echo "停止服务会一起结束 MTProxy、tproxy、中转和 Caddy。"
    else
        echo -e "WEB 代理: \033[33m已停止\033[0m"
    fi
}

do_config_web() {
    local input_hostname input_secret input_listen input_front input_email input_backend input_carrier input_fallback input_provider input_stat input_tag
    while true; do
        print_subject "请输入 WEB 代理的公网域名"
        read -r -p "(例如 proxy.example.com):" input_hostname
        if [[ "$input_hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
            break
        fi
        print_warning "域名必须是小写，并且至少包含一个点"
    done

    while true; do
        print_subject "请输入 MTP 密钥"
        echo "32 位十六进制。需要 dd 混淆时再在前面加上 dd。直接回车则随机生成 32 位密钥。"
        read -r -p "(留空则随机):" input_secret
        if [[ -z "$input_secret" ]]; then
            input_secret=$(gen_rand_hex 32)
        fi
        if [[ "$input_secret" =~ ^([0-9a-fA-F]{32}|[Dd][Dd][0-9a-fA-F]{32})$ ]]; then
            break
        fi
        print_warning "密钥格式不正确"
    done

    while true; do
        print_subject "请输入 tproxy 入口"
        echo "本机反代填写 127.0.0.1:8080。其它容器来访问时填写 0.0.0.0:18080，脚本会自动加一层 TCP 中转。"
        read -r -p "(默认 127.0.0.1:8080):" input_listen
        [[ -z "$input_listen" ]] && input_listen=127.0.0.1:8080
        if split_host_port "$input_listen"; then
            break
        fi
        print_warning "请写成 地址:端口"
    done

    while true; do
        print_subject "请选择 443 由谁接管"
        echo "  1. 本程序内置 Caddy，自动签发证书"
        echo "  2. 已有 Nginx/Caddy/其它容器反代"
        read -r -p "(默认 1):" input_front
        [[ -z "$input_front" ]] && input_front=1
        if [[ "$input_front" == "1" ]]; then
            input_front=caddy
            break
        elif [[ "$input_front" == "2" ]]; then
            input_front=external
            break
        fi
        print_warning "请输入 1 或 2"
    done

    input_email=""
    if [[ "$input_front" == "caddy" ]]; then
        while true; do
            print_subject "请输入 ACME 邮箱"
            read -r -p "(用于申请证书):" input_email
            if [[ "$input_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
                break
            fi
            print_warning "邮箱格式不正确"
        done
    fi

    while true; do
        print_subject "请输入 MTProxy 监听地址"
        echo "必须是本机回环地址。"
        read -r -p "(默认 127.0.0.1:2398):" input_backend
        [[ -z "$input_backend" ]] && input_backend=127.0.0.1:2398
        if split_host_port "$input_backend" && is_loopback_host "$SPLIT_HOST"; then
            break
        fi
        print_warning "必须写成 127.0.0.1:端口 或 [::1]:端口"
    done

    while true; do
        print_subject "请选择 carrier_mode"
        echo "  1. https"
        echo "  2. https-lanes"
        echo "  3. websocket"
        echo "  4. websocket-lanes"
        read -r -p "(默认 1):" input_carrier
        [[ -z "$input_carrier" ]] && input_carrier=1
        case "$input_carrier" in
            1) input_carrier=https; break ;;
            2) input_carrier=https-lanes; break ;;
            3) input_carrier=websocket; break ;;
            4) input_carrier=websocket-lanes; break ;;
        esac
        print_warning "请输入 1 到 4"
    done

    while true; do
        print_subject "请输入伪装站"
        echo "本地目录可写相对路径（相对于脚本目录，须含 index.html），或绝对路径，或 http://127.0.0.1:端口，或 http(s)://其它主机[:端口]。"
        echo "后一种会由中转程序转发，tproxy 仍只连接本机回环。"
        read -r -p ":" input_fallback
        web_fallback=$input_fallback
        if web_classify_fallback; then
            break
        fi
        print_warning "$WEB_ERROR"
    done

    while true; do
        local default_provider=1
        [[ "$SYSTEM_ARCH" != "x86_64" ]] && default_provider=2
        print_subject "请输入要安装的程序版本"
        echo "  1. 官方 MTProxy（仅 x86_64，不支持 dd）"
        echo "  2. mtg"
        echo "  3. mtprotoproxy"
        read -r -p "(默认版本: ${default_provider}):" input_provider
        [[ -z "$input_provider" ]] && input_provider=$default_provider
        if [[ "$input_provider" =~ ^[1-3]$ ]]; then
            if [[ "$SYSTEM_ARCH" != "x86_64" && "$input_provider" == "1" ]]; then
                print_warning "当前架构不支持官方 MTProxy"
                continue
            fi
            if [[ "$input_provider" == "1" && "$input_secret" =~ ^[Dd][Dd] ]]; then
                print_warning "官方 MTProxy 不支持 dd 密钥"
                continue
            fi
            break
        fi
        print_warning "请输入 1 到 3"
    done

    while true; do
        print_subject "请输入统计端口"
        echo "只监听本机。"
        read -r -p "(默认 8888):" input_stat
        [[ -z "$input_stat" ]] && input_stat=8888
        if [[ "$input_stat" =~ ^[0-9]+$ && "$input_stat" -ge 1 && "$input_stat" -le 65535 ]]; then
            break
        fi
        print_warning "端口无效"
    done

    while true; do
        print_subject "请输入推广 TAG"
        read -r -p "(留空则跳过):" input_tag
        if [[ -z "$input_tag" || "$input_tag" =~ ^[A-Za-z0-9]{32}$ ]]; then
            break
        fi
        print_warning "TAG 必须是 32 位字母或数字"
    done

    secret=$input_secret
    adtag=$input_tag
    provider=$input_provider
    statport=$input_stat
    web_hostname=$input_hostname
    web_listen=$input_listen
    web_front=$input_front
    web_email=$input_email
    web_backend=$input_backend
    web_carrier=$input_carrier
    web_fallback=$input_fallback
    web_tproxy_listen=127.0.0.1:8080
    web_admin_listen=127.0.0.1:8081
    web_upstream_listen=http://127.0.0.1:30000
    web_token_key=token.key
    web_static_routes=exact
    web_validate_config

    cat > "$CONFIG_PATH" <<EOF
#!/bin/bash
proxy_mode="web"
secret="${secret}"
adtag="${adtag}"
provider=${provider}
statport=${statport}
web_hostname="${web_hostname}"
web_listen="${web_listen}"
web_front="${web_front}"
web_email="${web_email}"
web_backend="${web_backend}"
web_carrier="${web_carrier}"
web_fallback="${web_fallback}"
web_tproxy_listen="${web_tproxy_listen}"
web_admin_listen="${web_admin_listen}"
web_upstream_listen="${web_upstream_listen}"
web_token_key="${web_token_key}"
web_static_routes="${web_static_routes}"
EOF
    print_info "配置已经生成完毕"
}
