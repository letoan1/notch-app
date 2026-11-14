#!/bin/bash
# Gửi một yêu cầu giả của Claude Code tới Roost để xem thẻ trên notch, không cần mở Claude.
#   scripts/demo-claude.sh              thẻ xin quyền chạy lệnh (Bash: npm run build && npm test)
#   scripts/demo-claude.sh --question   thẻ Claude hỏi (chọn đáp án)
# In ra quyết định Roost trả về. Không đụng tới cài đặt Claude thật: gợi ý "Luôn cho phép" chỉ có
# phạm vi phiên (session) và không có Claude nào đọc kết quả, nên bấm nút nào cũng không ghi gì.
set -euo pipefail

HOOK="/Applications/Roost.app/Contents/MacOS/roost-hook"
[[ -x "$HOOK" ]] || { echo "Chưa thấy $HOOK. Cài app trước: ./build.sh install"; exit 1; }

SESSION="roost-demo-$(date +%s)"
CWD="/tmp/roost-demo/my-app"

if [[ "${1:-}" == "--question" ]]; then
  PAYLOAD=$(cat <<JSON
{"session_id":"$SESSION","transcript_path":"","cwd":"$CWD","permission_mode":"default",
 "hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
 "tool_input":{"questions":[{"question":"Bạn muốn notch trông thế nào?","header":"Giao diện","multiSelect":false,
   "options":[{"label":"Tối giản","description":"Chỉ những gì cần thiết"},
              {"label":"Dynamic Island","description":"Bo tròn, nảy nhẹ"},
              {"label":"Kính mờ","description":"Nền blur trong suốt"},
              {"label":"Retro","description":"Pixel 8-bit"}]}]}}
JSON
)
else
  PAYLOAD=$(cat <<JSON
{"session_id":"$SESSION","transcript_path":"","cwd":"$CWD","permission_mode":"default",
 "hook_event_name":"PermissionRequest","tool_name":"Bash",
 "tool_input":{"command":"npm run build && npm test","description":"Build rồi chạy test"},
 "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],
                            "behavior":"allow","destination":"session"}]}
JSON
)
fi

echo "Đã gửi, mở notch để trả lời (tự huỷ sau 60 giây)..."
OUT=$(printf '%s' "$PAYLOAD" | env -u CLAUDE_PID NOTCH_HOOK_TIMEOUT=60 "$HOOK" || true)
if [[ -z "$OUT" ]]; then
  echo "Không có quyết định (hết giờ hoặc Roost không chạy)."
else
  echo "Roost trả về:"
  printf '%s\n' "$OUT" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False, indent=2))' 2>/dev/null \
    || printf '%s\n' "$OUT"
fi
