#!/bin/bash
# 确保本机有可重复使用的代码签名身份「Tocode Local」。
# 使用专用钥匙串（已知口令）以便非交互 codesign；私钥与口令只留在本机，不进仓库。
set -euo pipefail

IDENTITY_NAME="Tocode Local"
KEYCHAIN_NAME="tocode-codesign.keychain-db"
KEYCHAIN_PATH="${HOME}/Library/Keychains/${KEYCHAIN_NAME}"
SUPPORT_DIR="${HOME}/Library/Application Support/com.tocode.app"
PASS_FILE="${SUPPORT_DIR}/codesign-keychain.pass"
OPENSSL="${TOCODE_OPENSSL:-/usr/bin/openssl}"

identity_available() {
  security find-identity -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
    | grep -F "\"${IDENTITY_NAME}\"" >/dev/null
}

if [[ -f "$KEYCHAIN_PATH" ]] && identity_available; then
  # 确保构建时能找到该钥匙串。
  security list-keychains -d user 2>/dev/null | grep -F "$KEYCHAIN_NAME" >/dev/null \
    || security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | sed -e 's/"//g')
  if [[ -f "$PASS_FILE" ]]; then
    security unlock-keychain -p "$(cat "$PASS_FILE")" "$KEYCHAIN_PATH" >/dev/null
  fi
  echo "${IDENTITY_NAME}"
  exit 0
fi

mkdir -p "$SUPPORT_DIR"
chmod 700 "$SUPPORT_DIR"

if [[ ! -f "$PASS_FILE" ]]; then
  "$OPENSSL" rand -base64 32 >"$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
keychain_pass="$(cat "$PASS_FILE")"

if [[ ! -f "$KEYCHAIN_PATH" ]]; then
  security create-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null
fi
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >/dev/null
security unlock-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null

# 把专用钥匙串放到搜索列表最前，保留现有登录钥匙串。
existing=()
while IFS= read -r line; do
  path="$(echo "$line" | sed -e 's/^ *"//' -e 's/" *$//')"
  [[ -n "$path" && "$path" != "$KEYCHAIN_PATH" ]] || continue
  existing+=("$path")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN_PATH" "${existing[@]+"${existing[@]}"}" >/dev/null

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tocode-codesign.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

key_pem="$tmpdir/key.pem"
cert_pem="$tmpdir/cert.pem"
p12_path="$tmpdir/identity.p12"
openssl_cfg="$tmpdir/openssl.cnf"
p12_pass="$("$OPENSSL" rand -base64 32)"

cat >"$openssl_cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = codesign_ext
[dn]
CN = ${IDENTITY_NAME}
[codesign_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$key_pem" \
  -out "$cert_pem" \
  -config "$openssl_cfg" \
  >/dev/null 2>&1

"$OPENSSL" pkcs12 -export \
  -inkey "$key_pem" \
  -in "$cert_pem" \
  -out "$p12_path" \
  -name "$IDENTITY_NAME" \
  -passout "pass:${p12_pass}" \
  >/dev/null 2>&1

# 若旧身份不完整则清掉证书后重导。
security delete-certificate -c "$IDENTITY_NAME" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

security import "$p12_path" \
  -k "$KEYCHAIN_PATH" \
  -P "$p12_pass" \
  -A \
  >/dev/null

# 已知口令下设置 partition，codesign 无需图形授权即可用私钥。
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_pass" \
  "$KEYCHAIN_PATH" \
  >/dev/null

# 信任本机自签的代码签名用途（用户域，无 sudo）。失败时仍可签名，verify 可能告警。
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN_PATH" \
  "$cert_pem" \
  >/dev/null 2>&1 || true

if ! identity_available; then
  echo "error: failed to create codesigning identity '${IDENTITY_NAME}'" >&2
  echo "hint: remove ${KEYCHAIN_PATH} and ${PASS_FILE}, then re-run scripts/build.sh" >&2
  exit 1
fi

echo "${IDENTITY_NAME}"
