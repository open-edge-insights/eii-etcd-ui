# Copyright (c) 2020 Intel Corporation.

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

ARG EII_VERSION
ARG UBUNTU_IMAGE_VERSION
FROM ia_eiibase:$EII_VERSION as base
FROM ia_common:$EII_VERSION as common

FROM base as builder
LABEL description="EtcdUI image"

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl \
                                               procps && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ARG ETCD_VERSION
RUN mkdir -p etcd && \
    curl -L https://github.com/coreos/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz -o etcd-${ETCD_VERSION}-linux-amd64.tar.gz && \
    tar -xvf etcd-${ETCD_VERSION}-linux-amd64.tar.gz -C etcd --strip 1 && \
    rm -f etcd-${ETCD_VERSION}-linux-amd64.tar.gz etcd/etcd && \
    mv etcd/etcdctl . && \
    rm -rf etcd/etcdctl

COPY etcdkeeper ./etcdkeeper/
ENV GOPROXY "https://proxy.golang.org"
RUN cd ./etcdkeeper/src/etcdkeeper \
    && go build -o etcdkeeper main.go \
    && mv etcdkeeper ../../

ARG CMAKE_INSTALL_PREFIX

# Install cjson
RUN rm -rf deps && \
    mkdir -p deps && \
    cd deps && \
    wget -q --show-progress https://github.com/DaveGamble/cJSON/archive/v1.7.12.tar.gz -O cjson.tar.gz && \
    tar xf cjson.tar.gz && \
    cd cJSON-1.7.12 && \
    mkdir build && cd build && \
    cmake -DCMAKE_INSTALL_INCLUDEDIR=${CMAKE_INSTALL_PREFIX}/include -DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX} .. && \
    make install

COPY --from=common ${CMAKE_INSTALL_PREFIX}/lib ${CMAKE_INSTALL_PREFIX}/lib
COPY --from=common ${CMAKE_INSTALL_PREFIX}/include ${CMAKE_INSTALL_PREFIX}/include

FROM ubuntu:$UBUNTU_IMAGE_VERSION as runtime
WORKDIR /app

# Setting python dev env
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3-distutils python3-minimal && \
    rm -rf /var/lib/apt/lists/*

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt install -y --no-install-recommends wget build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev libgd-dev libxml2 libxml2-dev uuid-dev && \
    wget http://nginx.org/download/nginx-1.18.0.tar.gz && \
    tar -zxvf nginx-1.18.0.tar.gz && \
    cd nginx-1.18.0 && \
    ./configure --prefix=/var/cache/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf --http-log-path=/var/log/nginx/access.log --error-log-path=/var/log/nginx/error.log --with-pcre --lock-path=/var/lock/nginx.lock --pid-path=/var/run/nginx.pid --with-http_ssl_module --with-http_image_filter_module=dynamic --modules-path=/etc/nginx/modules --with-http_v2_module --with-stream=dynamic --with-http_addition_module --with-http_mp4_module --http-client-body-temp-path=client_body_temp --http-proxy-temp-path=proxy_temp --http-fastcgi-temp-path=fastcgi_temp && \
    make && \
    make install && \
    apt -y remove --purge wget build-essential libpcre3-dev zlib1g-dev libssl-dev libgd-dev libxml2-dev uuid-dev && \
    rm -rf /var/lib/apt/lists/*

ARG EII_UID
ARG EII_USER_NAME
RUN groupadd $EII_USER_NAME -g $EII_UID && \
    useradd -r -u $EII_UID -g $EII_USER_NAME $EII_USER_NAME

RUN chown -R ${EII_UID}:${EII_UID} /var/log/nginx/ && \
    mkdir -p /var/lib/nginx && \ 
    mkdir -p /var/cache/nginx/client_body_temp /var/cache/nginx/proxy_temp /var/cache/nginx/fastcgi_temp /var/cache/nginx/uwsgi_temp /var/cache/nginx/scgi_temp && \
    chown -R ${EII_UID}:${EII_UID} /var/cache/nginx && \
    chown -R ${EII_UID}:${EII_UID} /var/lib/nginx/

ARG ARTIFACTS
ARG CMAKE_INSTALL_PREFIX
ENV LD_LIBRARY_PATH $LD_LIBRARY_PATH:${CMAKE_INSTALL_PREFIX}/lib
ENV PYTHONPATH $PYTHONPATH:/app/.local/lib/python3.8/site-packages:/app
COPY --from=builder ${CMAKE_INSTALL_PREFIX}/lib ${CMAKE_INSTALL_PREFIX}/lib
COPY --from=builder ${CMAKE_INSTALL_PREFIX}/include ${CMAKE_INSTALL_PREFIX}/include
COPY --from=common /eii/common/util util
COPY --from=common /root/.local/lib .local/lib
COPY --from=builder /app .

RUN chown -R ${EII_UID} .local/lib/python3.8

COPY nginx.conf /etc/nginx/nginx.conf
COPY start_etcdkeeper.py ./
COPY eii_nginx_prod.conf ./
COPY eii_nginx_dev.conf ./

RUN touch /run/nginx.pid

ARG EII_UID
RUN chown -R ${EII_UID}:${EII_UID} /run/nginx.pid && \
    ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log && \
    mkdir -p /opt/nginx && \
    chown -R ${EII_UID}:${EII_UID} /opt/nginx && \
    rm -rf /var/lib/nginx && ln -sf /opt/nginx /var/lib/nginx && \
    rm -f /etc/nginx/sites-enabled/default

RUN apt-get remove --purge -y patch

USER $EII_USER_NAME
HEALTHCHECK NONE
ENTRYPOINT ["python3", "start_etcdkeeper.py"]
