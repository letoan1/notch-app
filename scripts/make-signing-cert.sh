#!/bin/bash
# Tạo 1 lần: chứng chỉ ký code tự ký trong login keychain.
# Ký cố định → TCC nhận diện app theo bundle id + chứng chỉ, không hỏi lại quyền mỗi lần build.
#   scripts/make-signing-cert.sh                          → "Notch Local Signing" (build dev)
#   scripts/make-signing-cert.sh "Roost Release Signing"  → chứng chỉ ký bản phát hành (make-dmg.sh)
# Chứng chỉ phát hành phải giữ suốt đời app: mất khoá riêng thì mọi người dùng phải cấp lại quyền.
# Sao lưu ngay: Keychain Access → My Certificates → chuột phải "Roost Release Signing" → Export (.p12).
set -euo pipefail
NAME="${1:-Notch Local Signing}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Đã có chứng chỉ \"$NAME\""; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout pass:notch -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P notch -T /usr/bin/codesign
echo "Đã tạo chứng chỉ \"$NAME\""
