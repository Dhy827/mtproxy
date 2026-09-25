FROM --platform=$TARGETPLATFORM nginx:latest AS build
#FROM  nginx:1.23.2 AS build


COPY . /home/mtproxy

ENV WORKDIR=/home/mtproxy

WORKDIR /home/mtproxy 

# setup config
RUN set -ex \
    && cd $WORKDIR \
    && rm -rf .git \
    && cp entrypoint.sh /docker-entrypoint.d/40-mtproxy-start.sh \
    && chmod +x /docker-entrypoint.d/40-mtproxy-start.sh /home/mtproxy/docker-start.sh \
    && cp -f nginx/default.conf /etc/nginx/conf.d/default.conf \
    && cp -f nginx/nginx.conf /etc/nginx/nginx.conf

# build mtproxy
RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends git wget curl build-essential libssl-dev zlib1g-dev iproute2 vim-common net-tools procps python3 python3-cryptography unzip \
    && { apt-get install -y --no-install-recommends ntpsec-ntpdate || apt-get install -y --no-install-recommends ntpdate || true; } \
    && bash mtproxy.sh build \
    && rm -rf $WORKDIR/MTProxy \
    && rm -rf ~/go \
    && mkdir -p $WORKDIR/pid \
    && apt-get purge -y git build-essential libssl-dev zlib1g-dev \
    && apt-get clean \
    && apt-get autoremove --purge -y \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 80 443
ENTRYPOINT ["/home/mtproxy/docker-start.sh"]
CMD ["nginx", "-g", "daemon off;"]
