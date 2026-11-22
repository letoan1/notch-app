#!/bin/bash
# Thử lệnh roost push: một thẻ chạy tiến độ 0 → 100 rồi tự đóng, cùng --id nên chỉ có một thẻ.
#   scripts/demo-push.sh
set -euo pipefail
ROOST=$(command -v roost || echo /Applications/Roost.app/Contents/MacOS/roost-hook)
for p in 0 20 40 60 80; do
  "$ROOST" push "Đang deploy" --body "Bước $((p / 20 + 1))/5" --progress "$p" --id demo-deploy
  sleep 1
done
"$ROOST" push "Deploy xong" --body "Thẻ cập nhật tại chỗ, không tạo thẻ mới." --progress 100 --id demo-deploy
