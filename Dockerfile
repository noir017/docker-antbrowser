# Ant Browser in a container, reachable over noVNC.
#
# Ant Browser is a Wails desktop app (GTK3 + WebKit2GTK), not a web service, so it
# needs a real X display. The ich777 noVNC base image already ships TurboVNC,
# fluxbox, websockify and noVNC, which is exactly the setup docker-brave uses.
FROM ich777/novnc-baseimage

LABEL org.opencontainers.image.title="Ant Browser"
LABEL org.opencontainers.image.description="Ant Browser (multi-profile browser launcher) over noVNC"
LABEL org.opencontainers.image.source="https://github.com/noir017/docker-antbrowser"
LABEL org.opencontainers.image.licenses="NOASSERTION"

# Runtime libraries. The first three are what `ldd ant-chrome` reports as missing on
# the bare base image; libsoup3 and javascriptcoregtk arrive as webkit2gtk deps.
# socat backs the Launch API relay, dbus-x11 gives the app a session bus.
# curl, iproute2 (ss) and x11-utils (xdpyinfo) are absent from the base image and
# are all used by antctl.
#
# libnss3 is for the *browser core*, not the Wails app: Chromium links
# libnss3/libnssutil3/libsmime3 (and libnspr4/libplc4/libplds4 via libnspr4) for
# certificate and crypto handling, and none of them are in the base image or in
# webkit2gtk's dependency closure. Without it a core exits immediately at launch
# with a bare loader error, which surfaces only as "the instance won't start".
RUN apt-get update \
 && apt-get -y install --no-install-recommends \
      libwebkit2gtk-4.1-0 \
      libgtk-3-0 \
      libayatana-appindicator3-1 \
      libnss3 \
      fonts-noto-cjk \
      fonts-noto-color-emoji \
      socat \
      dbus-x11 \
      ca-certificates \
      curl \
      jq \
      xz-utils \
      nano \
      iputils-ping \
      iproute2 \
      x11-utils \
      procps \
      psmisc \
 && rm -rf /var/lib/apt/lists/*

# Timezone + locales. zh_CN is generated so the app's Chinese UI renders with the
# Noto CJK fonts installed above instead of tofu boxes.
RUN ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
 && echo "Asia/Shanghai" > /etc/timezone \
 && echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen \
 && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
 && locale-gen

RUN sed -i '/    document.title =/c\    document.title = "Ant Browser - noVNC";' /usr/share/novnc/app/ui.js \
 && rm -f /usr/share/novnc/app/images/icons/*

# The app tarball is built by CI (see .github/workflows/build.yml) from
# noir017/Ant-Browser via the project's own publish/linux/publish-linux.sh,
# once per architecture. TARGETARCH (amd64 / arm64) is set by BuildKit.
#
# /opt/ant-browser stays root-owned and read-only on purpose: the app detects an
# unwritable install root and relocates all writable state to
# $XDG_DATA_HOME/ant-browser, which is the single directory we bind-mount.
# See backend/internal/apppath/apppath.go in the app repo.
ARG TARGETARCH
COPY dist/AntBrowser-linux-${TARGETARCH}.tar.gz /tmp/antbrowser.tar.gz
RUN mkdir -p /opt/ant-browser \
 && tar -xzf /tmp/antbrowser.tar.gz -C /opt/ant-browser \
 && rm -f /tmp/antbrowser.tar.gz \
 && chmod 0755 /opt/ant-browser/ant-chrome /opt/ant-browser/bin/xray /opt/ant-browser/bin/sing-box \
 && chmod -R a-w /opt/ant-browser

ENV DATA_DIR=/user
ENV APP_DIR=/opt/ant-browser
ENV APP_BIN=/opt/ant-browser/ant-chrome

# State root. XDG_DATA_HOME is what the app reads; ANT_STATE_DIR is the resolved
# path our scripts use. Keep the two consistent if you change either.
ENV XDG_DATA_HOME=/user/.local/share
ENV ANT_STATE_DIR=/user/.local/share/ant-browser

# Launch API. The app binds 127.0.0.1:ANT_API_PORT and rejects non-localhost
# callers, so a relay on a *different* port forwards from the LAN.
ENV ANT_API_PORT=19876
ENV ANT_API_RELAY_PORT=19877
ENV ANT_API_RELAY=1
ENV ANT_AUTOSTART=1

# 1600x900@24 — the app's window config asks for 1750x1000 with a 1200x700 floor,
# so the base image's 1024x768@16 default would crush the layout.
ENV CUSTOM_RES_W=1600
ENV CUSTOM_RES_H=900
ENV CUSTOM_DEPTH=24
ENV NOVNC_PORT=8080
ENV RFB_PORT=5900
ENV TURBOVNC_PARAMS="-securitytypes none"

ENV UMASK=000
ENV UID=99
ENV GID=100
ENV DATA_PERM=770
ENV USER="user"
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV PATH="/opt/scripts:${PATH}"

RUN mkdir -p "$DATA_DIR" \
 && useradd -d "$DATA_DIR" -s /bin/bash "$USER" \
 && chown -R "$USER" "$DATA_DIR"

ADD scripts/ /opt/scripts/
COPY icons/ /usr/share/novnc/app/images/icons/
COPY conf/ /etc/.fluxbox/

RUN chmod -R 0755 /opt/scripts/

# 8080 noVNC, 19877 Launch API relay.
EXPOSE 8080 19877

ENTRYPOINT ["/opt/scripts/start.sh"]
