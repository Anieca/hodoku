#!/bin/zsh
# 自分の Mac でだけ使う、署名用の自己署名証明書をログインキーチェーンに作る。
# これで署名すると、ビルドし直しても画面収録の許可が引き継がれる。
# 信頼設定は変えない。要らなくなったら「キーチェーンアクセス」で "Hodoku Local Signing" を削除すればよい。
set -euo pipefail

NAME="Hodoku Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "already exists: $NAME"
    exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cfg" <<CFG
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
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -days 3650 -config "$DIR/cfg" 2>/dev/null
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout "pass:$PASS" -name "$NAME" 2>/dev/null
security import "$DIR/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "created: $NAME"
