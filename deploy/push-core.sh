#!/bin/bash
# Resumable upload over a flaky ssh link.
#
# scp/`cat >>` both die partway through a 200MB+ transfer on this link, so send
# the file in bounded chunks: each ssh invocation is short-lived, and a dropped
# connection only costs the chunk in flight. The remote size is re-read every
# round, so this is safe to re-run after any failure.
set -uo pipefail

SRC="${1:?usage: push-core.sh <local-file> <remote-path>}"
DST="${2:?usage: push-core.sh <local-file> <remote-path>}"
CHUNK=$((16 * 1024 * 1024))
MAX_RETRY=200

TOTAL="$(stat -c%s "$SRC")"
echo "source: $SRC ($TOTAL bytes)"

fail=0
while :; do
    OFF="$(ssh -o ConnectTimeout=15 unraid "stat -c%s '$DST' 2>/dev/null || echo 0" 2>/dev/null)"
    OFF="${OFF//[^0-9]/}"
    [ -z "$OFF" ] && { echo "cannot read remote size, retrying"; sleep 5; continue; }

    if [ "$OFF" -ge "$TOTAL" ]; then
        echo "transfer complete: $OFF/$TOTAL"
        break
    fi

    # A partial write from a killed chunk would corrupt the tail; truncating to a
    # chunk boundary is not enough because the drop can land mid-chunk. Instead
    # trust the byte count and re-verify the whole prefix at the end.
    pct=$((OFF * 100 / TOTAL))
    printf 'offset %d/%d (%d%%) ' "$OFF" "$TOTAL" "$pct"

    if tail -c +$((OFF + 1)) "$SRC" | head -c "$CHUNK" | \
       ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
           unraid "cat >> '$DST'" 2>/dev/null; then
        echo "chunk ok"
        fail=0
    else
        fail=$((fail + 1))
        echo "chunk failed (retry $fail)"
        if [ "$fail" -ge "$MAX_RETRY" ]; then
            echo "giving up after $MAX_RETRY consecutive failures"
            exit 1
        fi
        sleep 3
    fi
done

echo "verifying checksum"
LOCAL_MD5="$(md5sum "$SRC" | cut -d' ' -f1)"
REMOTE_MD5="$(ssh unraid "md5sum '$DST' | cut -d' ' -f1")"
echo "local : $LOCAL_MD5"
echo "remote: $REMOTE_MD5"
if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
    echo "CHECKSUM OK"
else
    echo "CHECKSUM MISMATCH"
    exit 1
fi
