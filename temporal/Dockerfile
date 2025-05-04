# syntax=docker/dockerfile-upstream:master-labs
# to enable the --parents arg on COPY

### Build
# Base image with OpenJDK 17 and Maven installed
FROM maven:3.9.6-eclipse-temurin-17 AS build-base

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        && rm -rf /var/lib/apt/lists/*

FROM build-base AS build-deps

WORKDIR /src
COPY --parents pom.xml **/pom.xml /src/

# This addresses an issue with the circe package build on x86_64.
RUN arch=$(uname -m) && \
    if [ "$arch" = "x86_64" ]; then \
        ln -s /lib/x86_64-linux-gnu/librt.so.1 /usr/lib/x86_64-linux-gnu/librt.so ; \
    fi

RUN mvn dependency:go-offline

FROM build-deps AS build
WORKDIR /src
COPY . /src
RUN mvn -T 1C package -DskipTests

### Deployment Image

FROM ubuntu:22.04 AS deploy-base

ARG TARGETARCH
ARG UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu/
ARG UBUNTU_SECURITY_MIRROR=http://security.ubuntu.com/ubuntu/
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-$TARGETARCH
RUN set -x \
    && sed -i -e "s|http://archive\.ubuntu\.com/ubuntu/|${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu/}|g" \
     -e "s|http://security\.ubuntu\.com/ubuntu/|${UBUNTU_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu/}|g" /etc/apt/sources.list \
    && echo 'Acquire::http::Timeout "30";\nAcquire::http::ConnectionAttemptDelayMsec "2000";\nAcquire::https::Timeout "30";\nAcquire::https::ConnectionAttemptDelayMsec "2000";\nAcquire::ftp::Timeout "30";\nAcquire::ftp::ConnectionAttemptDelayMsec "2000";\nAcquire::Retries "15";' > /etc/apt/apt.conf.d/99timeout_and_retries \
    && apt-get update \
    && apt-get install -y ca-certificates apt-transport-https \
    && apt-get install -y --no-install-recommends openjdk-17-jdk \
    && apt-get install -y --no-install-recommends python3 pip \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && apt-get install -y --no-install-recommends gpg gpg-agent wget sudo iproute2 socat \
    && apt-get -y --purge autoremove \
    && apt-get autoclean \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && pip install zk-shell

FROM deploy-base AS bookkeeper-wal

ARG BK_VERSION=4.16.1
ARG DISTRO_SOURCE=/src/bookkeeper-dist/all/target/bookkeeper-all-${BK_VERSION}-bin.tar.gz
ARG DISTRO_DEST=/bookkeeper-all-${BK_VERSION}-bin.tar.gz

COPY --from=build $DISTRO_SOURCE $DISTRO_DEST

ENV BOOKIE_PORT=3181
ENV BOOKIE_HTTP_PORT=8080
EXPOSE $BOOKIE_PORT $BOOKIE_HTTP_PORT
ENV BK_USER=bookkeeper
ENV BK_HOME=/opt/bookkeeper

RUN set -x \
    && adduser "${BK_USER}" \
    && tar -xzf "$DISTRO_DEST" \
    && mkdir -pv /opt \
    && mv bookkeeper-all-${BK_VERSION}/ /opt/bookkeeper/ \
    && cd /opt \
    && rm -rf "$DISTRO_DEST" \
    && JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java)))) \
    && echo networkaddress.cache.ttl=1 >> $JAVA_HOME/conf/security/java.security \
    && echo networkaddress.cache.negative.ttl=1 >> $JAVA_HOME/conf/security/java.security

COPY --from=build /src/docker/scripts /opt/bookkeeper/scripts
COPY temporal/entrypoint.sh /opt/bookkeeper/scripts/entrypoint.sh
WORKDIR /opt/bookkeeper
ENTRYPOINT [ "/bin/bash", "/opt/bookkeeper/scripts/entrypoint.sh" ]
CMD ["bookie"]
HEALTHCHECK --interval=10s --timeout=60s CMD /bin/bash /opt/bookkeeper/scripts/healthcheck.sh

FROM bookkeeper-wal