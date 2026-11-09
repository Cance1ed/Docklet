#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity for Docklet.
#
# Why: an ad-hoc signature (`codesign -s -`) produces a new cdhash on every build,
# and macOS keys the Accessibility (TCC) grant to that hash — so the permission is
# revoked every time you rebuild. Signing with a persistent certificate keeps the
# designated requirement stable, so you only grant Accessibility once.
set -euo pipefail

NAME="${DOCKLET_SIGN_IDENTITY:-Docklet Self Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "${NAME}" >/dev/null 2>&1; then
  echo "✓ 签名身份「${NAME}」已存在，无需重复创建。"
  echo "  构建时会自动使用它： ./scripts/build_app.sh"
  exit 0
fi

echo "▸ 生成自签名证书「${NAME}」…"
cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = PLACEHOLDER_CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
sed -i '' "s/PLACEHOLDER_CN/${NAME}/" "$TMP/openssl.cnf"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1

# macOS Security.framework only reads legacy PKCS#12 encryption and rejects an
# empty passphrase, so pin the old algorithms and use a throwaway password.
P12_PASS="docklet"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "${NAME}" -out "$TMP/identity.p12" -passout "pass:${P12_PASS}" \
  -legacy -macalg sha1 >/dev/null 2>&1

echo "▸ 导入钥匙串（可能会弹窗要求输入登录密码）…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "${P12_PASS}" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "▸ 标记为受信任的代码签名证书（会弹出密码框，请输入登录密码）…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || {
  echo "⚠︎ 设置信任失败。请打开「钥匙串访问」，找到「${NAME}」，双击 → 信任 →「代码签名」设为「始终信任」。"
}

# Let codesign use the key without prompting on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "✓ 完成。现在重新构建： ./scripts/build_app.sh"
echo "  之后只需在「系统设置 → 隐私与安全性 → 辅助功能」授权一次，重建不会再失效。"
