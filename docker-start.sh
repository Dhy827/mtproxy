#!/bin/bash
set -e

mode="${proxy_mode:-}"
if [[ -z "$mode" && -f /home/mtproxy/config ]]; then
    mode=$(sed -n 's/^proxy_mode="\(.*\)"/\1/p' /home/mtproxy/config | head -n 1)
fi

if [[ "$mode" == "web" ]]; then
    bash /home/mtproxy/entrypoint.sh prepare
    exec bash /home/mtproxy/mtproxy.sh daemon
fi

exec /docker-entrypoint.sh "$@"
