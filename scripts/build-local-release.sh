#!/bin/bash
# 本机可运行的 Release 必须使用稳定证书。不要用 ad-hoc 构建替换日常使用版，
# 否则每次重新编译的 designated requirement 都变化，旧钥匙串授权无法复用。
# 可用 TERMO_SIGNING_IDENTITY 指定证书名称或 SHA-1；不会修改钥匙串访问控制。
set -euo pipefail
TERMO_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TERMO_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
export TERMO_IDENTITIES
TERMO_SIGNER="$(/usr/bin/python3 - <<'PY'
import os, re, sys
identities = re.findall(r'\) ([A-Fa-f0-9]{40}) "([^"\n]+)"', os.environ['TERMO_IDENTITIES'])
requested = os.environ.get('TERMO_SIGNING_IDENTITY', '')
if requested:
    candidates = [item for item in identities if requested in item]
else:
    candidates = [item for item in identities if item[1].startswith('Apple Development:')]
    if not candidates:
        candidates = [item for item in identities if item[1].startswith('Developer ID Application:')]
if len(candidates) != 1:
    sys.exit('需要唯一可用的代码签名证书；请用 TERMO_SIGNING_IDENTITY 指定。本机交付不回退临时签名。')
print(candidates[0][0])
PY
)"
unset TERMO_IDENTITIES
/usr/bin/xcodebuild -project "$TERMO_PROJECT_ROOT/Termo.xcodeproj" -scheme Termo \
    -configuration Release -destination 'platform=macOS' \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$TERMO_SIGNER" DEVELOPMENT_TEAM= \
    OTHER_CODE_SIGN_FLAGS=--timestamp=none build
/usr/bin/codesign --verify --deep --strict "$TERMO_PROJECT_ROOT/build/Release/Termo.app"
/usr/bin/codesign -d -r- "$TERMO_PROJECT_ROOT/build/Release/Termo.app"
