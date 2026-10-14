#!/bin/bash
# 一次性创建本地代码签名证书，让 TCC 授权在重新编译后仍然有效。
#
# 解决的问题：
#   应用默认是 ad-hoc 临时签名。TCC 把权限记录与代码签名绑定，
#   每次重新编译都会改变 CDHash，之前授的权限随即失效，必须重新勾选。
#   换成一个**固定的自签名证书**后，TCC 认的是证书身份而不是内容哈希，
#   重新编译不再影响授权。
#
# 只需运行一次。重复运行是安全的（会检测已有证书）。
#
# 用法：./scripts/setup-signing.sh

set -euo pipefail

IDENTITY="BooksBridge Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "==> 检查是否已有签名身份"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "    已存在「${IDENTITY}」，无需重复创建"
    security find-identity -v -p codesigning 2>/dev/null | grep "$IDENTITY"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 生成自签名代码签名证书"
cat > "$WORK/cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = BooksBridge Dev
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/cnf" 2>/dev/null
echo "    CN=BooksBridge Dev，有效期 10 年"

echo "==> 打包并导入钥匙串"
# 必须用 -legacy：OpenSSL 3 的默认加密算法 macOS 的 security 工具不认，
# 直接导入会报 "MAC verification failed during PKCS12 import"。
openssl pkcs12 -export -legacy \
    -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:booksbridge 2>/dev/null

# -T /usr/bin/codesign：授权 codesign 使用这把私钥，避免签名时弹授权框
security import "$WORK/id.p12" -k "$KEYCHAIN" -P booksbridge \
    -T /usr/bin/codesign 2>&1 | tail -1

echo "==> 设为受信任（用户级，不需要管理员密码）"
# -d 加到用户信任域、-r trustRoot 作为根、-p codeSign 仅用于代码签名。
# 不加信任的话身份会显示 CSSMERR_TP_NOT_TRUSTED，TCC 也可能不认。
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "==> 完成"
security find-identity -v -p codesigning 2>/dev/null | grep "$IDENTITY" || {
    echo "✗ 证书创建了但未被识别为有效签名身份，请检查钥匙串" >&2
    exit 1
}
echo
echo "现在重新构建，之后重新编译不会再丢失权限："
echo "    ./scripts/build-app.sh"
echo
echo "注意：第一次授权后，如果之后又改了 Bundle ID，授权仍需重做一次"
echo "（TCC 同时认证书身份与 bundle id）。"
