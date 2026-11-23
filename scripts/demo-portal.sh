#!/bin/bash
# Thử Portal mà không cần iPhone (cần bật Cài đặt > Portal):
#   scripts/demo-portal.sh hello               Mac trả tên + id
#   scripts/demo-portal.sh pair [tên]          xin ghép: thẻ duyệt hiện dưới notch, cho phép thì lưu token
#   scripts/demo-portal.sh send <file>...      gửi file như iPhone (máy bay giấy bay ra từ mép phải; ROOST_Y=0..1 là độ cao)
#   scripts/demo-portal.sh clip ["chữ"]        gửi clipboard
# Máy khác trong mạng: ROOST_PORTAL=Ten-May.local:52525 scripts/demo-portal.sh …
set -euo pipefail
HOST=${ROOST_PORTAL:-localhost:52525}
TOKEN_FILE="${TMPDIR:-/tmp}/roost-portal-token"

token() {
  [ -s "$TOKEN_FILE" ] || { echo "Chưa ghép: chạy '$0 pair' trước." >&2; exit 1; }
  cat "$TOKEN_FILE"
}

urlencode() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1" 2>/dev/null || printf %s "$1"; }

case "${1:-}" in
  hello)
    curl -sS "http://$HOST/hello"; echo ;;
  pair)
    code=$(printf %04d $((RANDOM % 10000)))
    echo "Mã hiện trên thẻ duyệt phải là: $code (chờ tối đa 60 giây)"
    resp=$(curl -sS -m 70 -X POST -H 'Content-Type: application/json' \
      --data "{\"name\":\"${2:-Máy thử}\",\"code\":\"$code\"}" "http://$HOST/pair")
    echo "$resp"
    t=$(printf %s "$resp" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
    if [ -n "$t" ]; then printf %s "$t" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; echo "Đã lưu token vào $TOKEN_FILE"; fi ;;
  send)
    shift
    [ $# -gt 0 ] || { echo "Cần ít nhất một file." >&2; exit 1; }
    t=$(token)
    for f in "$@"; do
      type=$(file --mime-type -b "$f" 2>/dev/null || echo application/octet-stream)
      curl -sS -X POST -H "Authorization: Bearer $t" -H "X-Roost-Name: $(urlencode "$(basename "$f")")" -H "X-Roost-Y: ${ROOST_Y:-0.45}" \
        -H "Content-Type: $type" --data-binary @"$f" "http://$HOST/send"
      echo
    done ;;
  clip)
    t=$(token)
    printf %s "${2:-Xin chào từ Portal}" | curl -sS -X POST -H "Authorization: Bearer $t" \
      -H 'Content-Type: text/plain; charset=utf-8' --data-binary @- "http://$HOST/clipboard"
    echo ;;
  *)
    sed -n 2,7p "$0" ;;
esac
