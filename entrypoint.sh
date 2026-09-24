#!/bin/bash
set -e

config_default_path="/home/mtproxy/config.example"
config_path="/home/mtproxy/config"

gen_rand_hex() {
    local result
    result=$(dd if=/dev/urandom bs=1 count=500 status=none | od -An -tx1 | tr -d ' \n')
    echo "${result:0:$1}"
}

_env_proxy_mode=${proxy_mode-}
_env_secret=${secret-}
_env_adtag=${adtag-}
_env_domain=${domain-}
_env_provider=${provider-}
_env_web_hostname=${web_hostname-}
_env_web_listen=${web_listen-}
_env_web_front=${web_front-}
_env_web_email=${web_email-}
_env_web_backend=${web_backend-}
_env_web_carrier=${web_carrier-}
_env_web_fallback=${web_fallback-}
_env_web_tproxy_listen=${web_tproxy_listen-}
_env_web_admin_listen=${web_admin_listen-}
_env_web_upstream_listen=${web_upstream_listen-}
_env_web_token_key=${web_token_key-}
_env_web_static_routes=${web_static_routes-}
_env_statport=${statport-}

if [[ -f "$config_path" ]]; then
    # shellcheck disable=SC1090
    source "$config_path"
fi

[[ -n "$_env_proxy_mode" ]] && proxy_mode=$_env_proxy_mode
[[ -n "$_env_secret" ]] && secret=$_env_secret
[[ -n "$_env_adtag" ]] && adtag=$_env_adtag
[[ -n "$_env_domain" ]] && domain=$_env_domain
[[ -n "$_env_provider" ]] && provider=$_env_provider
[[ -n "$_env_web_hostname" ]] && web_hostname=$_env_web_hostname
[[ -n "$_env_web_listen" ]] && web_listen=$_env_web_listen
[[ -n "$_env_web_front" ]] && web_front=$_env_web_front
[[ -n "$_env_web_email" ]] && web_email=$_env_web_email
[[ -n "$_env_web_backend" ]] && web_backend=$_env_web_backend
[[ -n "$_env_web_carrier" ]] && web_carrier=$_env_web_carrier
[[ -n "$_env_web_fallback" ]] && web_fallback=$_env_web_fallback
[[ -n "$_env_web_tproxy_listen" ]] && web_tproxy_listen=$_env_web_tproxy_listen
[[ -n "$_env_web_admin_listen" ]] && web_admin_listen=$_env_web_admin_listen
[[ -n "$_env_web_upstream_listen" ]] && web_upstream_listen=$_env_web_upstream_listen
[[ -n "$_env_web_token_key" ]] && web_token_key=$_env_web_token_key
[[ -n "$_env_web_static_routes" ]] && web_static_routes=$_env_web_static_routes
[[ -n "$_env_statport" ]] && statport=$_env_statport

write_web_config() {
    web_listen=${web_listen:-127.0.0.1:8080}
    web_front=${web_front:-caddy}
    web_backend=${web_backend:-127.0.0.1:2398}
    web_carrier=${web_carrier:-https}
    web_tproxy_listen=${web_tproxy_listen:-127.0.0.1:8080}
    web_admin_listen=${web_admin_listen:-127.0.0.1:8081}
    web_upstream_listen=${web_upstream_listen:-http://127.0.0.1:30000}
    web_token_key=${web_token_key:-token.key}
    web_static_routes=${web_static_routes:-exact}
    provider=${provider:-2}
    statport=${statport:-8888}
    adtag=${adtag:-}
    web_email=${web_email:-}
    if [[ -z "$secret" ]]; then
        secret=$(gen_rand_hex 32)
    fi
    if [[ -z "$web_hostname" || -z "$web_fallback" ]]; then
        echo "WEB 模式需要环境变量 web_hostname 和 web_fallback" >&2
        exit 1
    fi
    cat > "$config_path" <<EOF
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
}

if [[ "${proxy_mode:-}" == "web" ]]; then
    write_web_config
    exit 0
fi

set_config() {
    if [ "$secret" ] && [[ "$secret" =~ ^[A-Za-z0-9]{32}$ ]]; then
        sed -i 's/secret="[0-9A-Za-z]*"/secret="'"$secret"'"/' "$config_path"
    fi
    if [ "$adtag" ] && [[ "$adtag" =~ ^[A-Za-z0-9]{32}$ ]]; then
        sed -i 's/adtag="[0-9A-Za-z]*"/adtag="'"$adtag"'"/' "$config_path"
    fi
    if [ "$domain" ]; then
        sed -i 's/domain="[0-9A-Za-z\.\-]*"/domain="'"$domain"'"/' "$config_path"
    fi
    if [ "$provider" ] && [[ "$provider" =~ ^[1-3]$ ]]; then
        sed -i 's/provider=[0-9]\+/provider='"$provider"'/' "$config_path"
    fi
}

if [[ ! -f $config_path ]]; then
    cp "${config_default_path}" "$config_path"
    if [[ -z "$secret" ]]; then
        secret=$(gen_rand_hex 32)
    fi
    if [[ -z "${ip_white_list:-}" ]]; then
        ip_white_list='IPSEG'
    fi
    if [[ "$ip_white_list" == "OFF" ]]; then
        echo "0.0.0.0/0 1;" >> /etc/nginx/ip_white.conf
    fi
    echo "$ip_white_list" > /var/ip_white_list
fi

set_config
echo "=================================================="
echo -e "Default port is \033[31m443\033[0m by docker started mtproxy!!!"
echo "=================================================="

if [[ "${1:-}" == "prepare" ]]; then
    exit 0
fi

/usr/sbin/php-fpm* -R
chmod 777 /etc/nginx/ip_white.conf
chmod 777 /run/php/php-fpm.sock
cd /home/mtproxy
{
    bash /home/mtproxy/mtproxy.sh daemon
} &
