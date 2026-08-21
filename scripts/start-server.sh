#!/bin/bash
# Display stack + app bring-up, runs as ${USER}.
# TurboVNC on :99 -> fluxbox -> websockify/noVNC -> Ant Browser -> Launch API relay.

export DISPLAY=:99
export XAUTHORITY=${DATA_DIR}/.Xauthority

echo "---Resolution check---"
if [ -z "${CUSTOM_RES_W}" ]; then
	CUSTOM_RES_W=1600
fi
if [ -z "${CUSTOM_RES_H}" ]; then
	CUSTOM_RES_H=900
fi

# The app's window config asks for 1750x1000 and refuses to go below 1200x700,
# so anything under 1280x800 makes the UI unusable.
if [ "${CUSTOM_RES_W}" -le 1279 ]; then
	echo "---Width too low for the Ant Browser window (min 1200 wide), correcting to 1280...---"
	CUSTOM_RES_W=1280
fi
if [ "${CUSTOM_RES_H}" -le 799 ]; then
	echo "---Height too low for the Ant Browser window (min 700 tall), correcting to 800...---"
	CUSTOM_RES_H=800
fi
export CUSTOM_RES_W CUSTOM_RES_H

echo "---Checking for old logfiles---"
find "$DATA_DIR" -name "XvfbLog.*" -exec rm -f {} \;
find "$DATA_DIR" -name "x11vncLog.*" -exec rm -f {} \;

echo "---Checking for old display lock files---"
rm -rf /tmp/.X99*
rm -rf /tmp/.X11*
rm -rf "${DATA_DIR}"/.vnc/*.log "${DATA_DIR}"/.vnc/*.pid
chmod -R "${DATA_PERM}" "${DATA_DIR}" 2>/dev/null ||:
if [ -f "${DATA_DIR}/.vnc/passwd" ]; then
	chmod 600 "${DATA_DIR}/.vnc/passwd"
fi
screen -wipe 2&>/dev/null

# A stale single-instance lock from a hard kill makes the app exit on startup
# thinking another copy already owns the display.
echo "---Clearing stale app locks---"
/opt/scripts/antctl unlock --quiet ||:

echo "---Starting TurboVNC server---"
vncserver -geometry "${CUSTOM_RES_W}x${CUSTOM_RES_H}" -depth "${CUSTOM_DEPTH}" :99 \
	-rfbport "${RFB_PORT}" -noxstartup -noserverkeymap ${TURBOVNC_PARAMS} 2>/dev/null
sleep 2

echo "---Starting Fluxbox---"
screen -d -m env HOME=/etc /usr/bin/fluxbox
sleep 2

echo "---Starting noVNC server---"
websockify -D --web=/usr/share/novnc/ --cert=/etc/ssl/novnc.pem \
	"${NOVNC_PORT}" "localhost:${RFB_PORT}"
sleep 2

if [ "${ANT_AUTOSTART}" = "1" ]; then
	echo "---Starting Ant Browser---"
	/opt/scripts/antctl start
else
	echo "---ANT_AUTOSTART is not 1, skipping app start (use 'antctl start')---"
fi

# The Launch API binds 127.0.0.1 and rejects any non-localhost RemoteAddr, so
# LAN callers need a relay: socat re-originates the connection from 127.0.0.1.
# Runs on a separate port because the app already owns ANT_API_PORT.
if [ "${ANT_API_RELAY}" = "1" ]; then
	echo "---Starting Launch API relay: 0.0.0.0:${ANT_API_RELAY_PORT} -> 127.0.0.1:${ANT_API_PORT}---"
	socat "TCP-LISTEN:${ANT_API_RELAY_PORT},fork,reuseaddr" \
		"TCP:127.0.0.1:${ANT_API_PORT}" > /dev/null 2>&1 &
	echo "$!" > /tmp/ant-api-relay.pid
else
	echo "---ANT_API_RELAY is not 1, Launch API stays container-local---"
fi

echo "---Ready---"
echo "    noVNC      : http://<container-ip>:${NOVNC_PORT}"
echo "    VNC        : <container-ip>:${RFB_PORT}"
if [ "${ANT_API_RELAY}" = "1" ]; then
	echo "    Launch API : http://<container-ip>:${ANT_API_RELAY_PORT}/api/health"
fi
echo "    State dir  : ${ANT_STATE_DIR}"
echo "    Manage with: docker exec <container> antctl status"

# Keep this shell alive so start.sh's child does not exit and take the trap with it.
while true
do
	sleep 30
done
