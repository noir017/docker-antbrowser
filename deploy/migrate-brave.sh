#!/bin/bash
# Migrate Brave profiles into Ant Browser.
#
# Copies each Brave user-data-dir into Ant Browser's UserDataRoot and registers it
# via the Launch API. Both trees live on the same btrfs pool, so --reflink=always
# makes each copy near-instant and free: 18G of profiles cost ~0 extra space, and
# the originals stay untouched as a rollback path.
#
# Copy rather than point at braveData directly: Chromium rewrites "Last Version"
# and the prefs on first launch, so a shared directory would mutate state the
# still-running Brave container depends on.
#
# Usage:
#   migrate-brave.sh --core-id <id> [--dry-run] [--only name1,name2] [--src DIR]
set -uo pipefail

SRC="/mnt/cache/appdata/braveData"
DST_ROOT="/mnt/cache/appdata/antbrowser/data/data"
API="http://192.168.2.201:19877"
CORE_ID=""
DRY_RUN=0
ONLY=""
# Brave ran with a spoofed Firefox UA; Ant Browser would otherwise inject its own
# Chrome fingerprint and change the identity these cookies were issued to.
KEEP_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0"
PRESERVE_UA=0

while [ $# -gt 0 ]; do
    case "$1" in
        --core-id)     CORE_ID="${2:-}"; shift 2 ;;
        --src)         SRC="${2:-}"; shift 2 ;;
        --only)        ONLY="${2:-}"; shift 2 ;;
        --api)         API="${2:-}"; shift 2 ;;
        --preserve-ua) PRESERVE_UA=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$CORE_ID" ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "error: --core-id is required (see: sqlite3 app.db 'select core_id,core_name from browser_cores')"
    exit 1
fi

command -v jq > /dev/null || { echo "error: jq required"; exit 1; }

if ! curl -fsS --max-time 5 "$API/api/health" > /dev/null 2>&1; then
    echo "error: Launch API not reachable at $API"
    exit 1
fi

# Registering by name is not idempotent on the API side, so skip dirs that are
# already registered instead of creating duplicates pointing at the same data.
existing="$(curl -fsS --max-time 10 "$API/api/profiles" 2>/dev/null \
            | jq -r '.items[]? | .userDataDir // empty' | sort -u)"

is_registered() {
    printf '%s\n' "$existing" | grep -qxF "$1"
}

should_include() {
    [ -z "$ONLY" ] && return 0
    printf '%s' "$ONLY" | tr ',' '\n' | grep -qxF "$1"
}

mkdir -p "$DST_ROOT"

printf '%-16s %-10s %s\n' "PROFILE" "SIZE" "RESULT"
printf '%-16s %-10s %s\n' "-------" "----" "------"

ok=0; skipped=0; failed=0

for dir in "$SRC"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    should_include "$name" || continue

    size="$(du -sh "$dir" 2>/dev/null | cut -f1)"

    # A Brave profile always has Local State; anything else is not a user-data-dir.
    if [ ! -f "$dir/Local State" ]; then
        printf '%-16s %-10s %s\n' "$name" "$size" "SKIP (no Local State)"
        skipped=$((skipped + 1))
        continue
    fi

    if is_registered "$name"; then
        printf '%-16s %-10s %s\n' "$name" "$size" "SKIP (already registered)"
        skipped=$((skipped + 1))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%-16s %-10s %s\n' "$name" "$size" "WOULD MIGRATE"
        ok=$((ok + 1))
        continue
    fi

    target="$DST_ROOT/$name"
    if [ -e "$target" ]; then
        printf '%-16s %-10s %s\n' "$name" "$size" "SKIP (target exists)"
        skipped=$((skipped + 1))
        continue
    fi

    if ! cp -a --reflink=always "$dir" "$target" 2>/dev/null; then
        printf '%-16s %-10s %s\n' "$name" "$size" "FAIL (copy)"
        failed=$((failed + 1))
        continue
    fi
    chown -R 99:100 "$target" 2>/dev/null

    # Chromium refuses to reuse a profile still holding a singleton lock, and
    # Brave's live locks come along with the copy.
    find "$target" -maxdepth 2 \
        \( -name 'SingletonLock' -o -name 'SingletonCookie' -o -name 'SingletonSocket' \) \
        -delete 2>/dev/null

    if [ "$PRESERVE_UA" -eq 1 ]; then
        payload="$(jq -n --arg n "$name" --arg d "$name" --arg c "$CORE_ID" --arg ua "$KEEP_UA" \
          '{profile:{profileName:$n,userDataDir:$d,coreId:$c,launchArgs:["--disable-sync","--no-first-run",("--user-agent="+$ua)],fingerprintArgs:[]}}')"
    else
        payload="$(jq -n --arg n "$name" --arg d "$name" --arg c "$CORE_ID" \
          '{profile:{profileName:$n,userDataDir:$d,coreId:$c}}')"
    fi

    response="$(curl -sS -X POST "$API/api/profiles" \
                  -H 'Content-Type: application/json' -d "$payload" 2>&1)"

    if printf '%s' "$response" | jq -e '.profileId // .profile.profileId' > /dev/null 2>&1; then
        code="$(printf '%s' "$response" | jq -r '.launchCode // .profile.launchCode // "-"')"
        printf '%-16s %-10s %s\n' "$name" "$size" "OK (code $code)"
        ok=$((ok + 1))
    else
        err="$(printf '%s' "$response" | jq -r '.error // .' 2>/dev/null | head -c 90)"
        printf '%-16s %-10s %s\n' "$name" "$size" "FAIL: $err"
        # Leave the copy in place: it is free (reflink) and lets you retry
        # registration without re-copying.
        failed=$((failed + 1))
    fi
done

echo
echo "migrated=$ok skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
