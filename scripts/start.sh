#!/bin/bash
# Container entrypoint (root). Aligns the in-container user with the Unraid
# nobody:users ids, prepares the writable state directory, then drops to that
# user to bring up the display stack.

echo "---Ensuring UID: ${UID} matches user---"
usermod -u "${UID}" "${USER}"
echo "---Ensuring GID: ${GID} matches user---"
groupmod -g "${GID}" "${USER}" > /dev/null 2>&1 ||:
usermod -g "${GID}" "${USER}"

echo "---Setting umask to ${UMASK}---"
umask "${UMASK}"

echo "---Checking for optional scripts---"
cp -f /opt/custom/user.sh /opt/scripts/start-user.sh > /dev/null 2>&1 ||:
cp -f /opt/scripts/user.sh /opt/scripts/start-user.sh > /dev/null 2>&1 ||:

if [ -f /opt/scripts/start-user.sh ]; then
    echo "---Found optional script, executing---"
    chmod -f +x /opt/scripts/start-user.sh ||:
    /opt/scripts/start-user.sh || echo "---Optional Script has thrown an Error---"
else
    echo "---No optional script found, continuing---"
fi

echo "---Checking configuration for noVNC---"
novnccheck

echo "---Taking ownership of data...---"
chown -R root:"${GID}" /opt/scripts
chmod -R 750 /opt/scripts
chown -R "${UID}":"${GID}" "${DATA_DIR}"

# The app relocates its writable state here because /opt/ant-browser is read-only.
# On first run it seeds config.yaml and chrome/ from the install root itself.
echo "---Ensuring state dir exists: ${ANT_STATE_DIR}---"
mkdir -p "${ANT_STATE_DIR}/data" "${ANT_STATE_DIR}/chrome" "${ANT_STATE_DIR}/logs"
chown -R "${UID}":"${GID}" "${XDG_DATA_HOME}"

if [ ! -f "${APP_BIN}" ]; then
    echo "---ERROR: app binary missing at ${APP_BIN}, image is broken---"
    exit 1
fi
echo "---Ant Browser binary: $(ls -la "${APP_BIN}" | awk '{print $5" bytes"}')---"

# Fail loudly here rather than letting the GUI silently never appear.
missing_libs="$(ldd "${APP_BIN}" 2>/dev/null | grep 'not found' || true)"
if [ -n "$missing_libs" ]; then
    echo "---ERROR: unresolved shared libraries---"
    echo "$missing_libs"
    exit 1
fi

echo "---Starting...---"
term_handler() {
	echo "---Received SIGTERM, shutting down...---"
	su "${USER}" -c "/opt/scripts/antctl stop" > /dev/null 2>&1 ||:
	kill -SIGTERM "$killpid" 2>/dev/null
	wait "$killpid" 2>/dev/null
	exit 143;
}

trap 'term_handler' SIGTERM
su "${USER}" -c "/opt/scripts/start-server.sh" &
killpid="$!"
while true
do
	sleep 10
done
