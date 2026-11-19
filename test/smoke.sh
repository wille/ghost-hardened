#!/usr/bin/env bash
# Smoke + hardening test for a ghost-hardened image.
#   test/smoke.sh [image]        (default: ghost-hardened:dev)
# Boots Ghost (sqlite) with the same runtime hardening as compose.yaml, exercises
# the admin flows that touch the filesystem and native addons, then runs
# test/attack.js under the image's exact Node flags. Exits non-zero on failure.
set -euo pipefail

IMAGE="${1:-ghost-hardened:dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-2399}"
NAME="ghost-hardened-smoke-$$"
WORK="$(mktemp -d)"
BASE="http://localhost:$PORT"
fail=0

cleanup() { docker rm -fv "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok    $1 ($3)"; else echo "FAIL  $1 (want $2, got $3)"; fail=1; fi
}

docker run -d --name "$NAME" -p "127.0.0.1:$PORT:2368" --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m --cap-drop ALL --security-opt no-new-privileges \
    -v /ghost/content \
    -e database__client=sqlite3 -e database__connection__filename=/ghost/content/data/ghost.db \
    -e database__useNullAsDefault=true -e url="$BASE" \
    -e security__staffDeviceVerification=false "$IMAGE" >/dev/null

for _ in $(seq 1 60); do curl -fs -o /dev/null "$BASE/" && break; sleep 2; done

# Fixtures: a 64x64 PNG and a copy of the bundled Source theme renamed to "smoketheme".
python3 -I - "$WORK" <<'PY'
import os, struct, sys, zlib
w = h = 64
raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
c = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(os.path.join(sys.argv[1], "t.png"), "wb").write(
    b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b""))
PY
# docker cp keeps the image's read-only modes; tar applies dir modes last, then make it writable.
docker cp "$NAME:/ghost/current/content/themes/source" - | tar -x -C "$WORK"
mv "$WORK/source" "$WORK/theme"; chmod -R u+w "$WORK/theme"
python3 -I - "$WORK" <<'PY'
import json, os, sys, zipfile
root = os.path.join(sys.argv[1], "theme")
pkg = os.path.join(root, "package.json")
d = json.load(open(pkg)); d["name"] = "smoketheme"; json.dump(d, open(pkg, "w"))
with zipfile.ZipFile(os.path.join(sys.argv[1], "smoketheme.zip"), "w") as z:
    for r, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(r, f); z.write(p, os.path.relpath(p, root))
PY

J="$WORK/jar"; A="$BASE/ghost/api/admin"
H=(-H "Origin: $BASE" -H 'Accept-Version: v6.0')
PW="$(openssl rand -hex 12)"
code() { curl -s -c "$J" -b "$J" "${H[@]}" -o "$WORK/out" -w '%{http_code}' "$@"; }

check home 200 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")"
check setup 201 "$(code -H 'Content-Type: application/json' -X POST "$A/authentication/setup/" \
    -d "{\"setup\":[{\"name\":\"Smoke\",\"email\":\"smoke@example.com\",\"password\":\"$PW\",\"blogTitle\":\"Smoke\"}]}")"
check login 201 "$(code -H 'Content-Type: application/json' -X POST "$A/session/" \
    -d "{\"username\":\"smoke@example.com\",\"password\":\"$PW\"}")"
check "image upload" 201 "$(code -F "file=@$WORK/t.png" -F purpose=image "$A/images/upload/")"
url="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["images"][0]["url"])' "$WORK/out")"
check "image fetch" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$url")"
check "image resize (sharp)" 200 "$(curl -s -o /dev/null -w '%{http_code}' "${url/\/content\/images\//\/content\/images\/size\/w320\/}")"
check "theme upload" 200 "$(code -F "file=@$WORK/smoketheme.zip" "$A/themes/upload/")"
check "theme activate" 200 "$(code -X PUT "$A/themes/smoketheme/activate/")"
check "post create" 201 "$(code -H 'Content-Type: application/json' -X POST "$A/posts/?source=html" \
    -d '{"posts":[{"title":"Hello","html":"<p>hi</p>","status":"published"}]}')"
check "post page" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/hello/")"
check "db export" 200 "$(code "$A/db/")"; cp "$WORK/out" "$WORK/db.json"
check "db import" 200 "$(code -F "importfile=@$WORK/db.json" "$A/db/")"

if docker logs "$NAME" 2>&1 | grep -qE 'ERR_ACCESS_DENIED|has been restricted|EACCES|EROFS'; then
    echo "FAIL  permission errors in Ghost logs:"; docker logs "$NAME" 2>&1 | grep -E 'ERR_ACCESS_DENIED|has been restricted|EACCES|EROFS' | head; fail=1
else
    echo "ok    no permission errors in Ghost logs"
fi

echo "--- attack simulation (image's exact Node flags)"
mapfile -t ENTRY < <(docker inspect "$NAME" --format '{{range .Config.Entrypoint}}{{println .}}{{end}}' | sed '/^$/d;/entrypoint\.js$/d')
docker exec -i "$NAME" "${ENTRY[@]}" - < "$HERE/attack.js" 2>/dev/null | tee "$WORK/attack" | grep -E '^(ok|FAIL)'
grep -q '^FAIL' "$WORK/attack" && fail=1
grep -q '^DONE' "$WORK/attack" || { echo "FAIL  attack simulation did not complete"; fail=1; }

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
