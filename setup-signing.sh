#!/bin/bash
# setup-signing.sh - dev build の「毎回 画面録画権限を承認し直す」問題を一度きりで解消する。
#
# 背景: build-app.sh のアドホック署名(codesign --sign -)はビルドごとにバイナリのハッシュが
# 変わり、macOS の TCC が画面録画権限を黙って失効させる。そのため build-app.sh は tccutil reset で
# 毎回プロンプトを出し直していた。安定した自己署名証明書で署名すれば、署名の designated requirement
# がハッシュに依存しなくなり、再ビルドをまたいで権限が保持される(=承認は最初の一回だけ)。
#
# このスクリプトは "SnapLocal Dev Cert" という自己署名のコード署名証明書を login キーチェーンに
# 作り、コード署名用に信頼設定する(codesign が identity として使えるようにする)だけ。
# ネットワーク通信なし・sudo 不要(信頼設定はユーザードメイン)・SnapLocal 専用ローカル鍵。
# 自己修復: 既存の同名証明書があれば削除して作り直すので、何度実行しても正しい状態に収束する。
# 取り消したいときは:  security delete-identity -c "SnapLocal Dev Cert"
#
# 注意: codesign に鍵を使わせる ACL(-T /usr/bin/codesign)だけ付与する。全アプリ開放(-A)はしない。
# 初回の codesign 実行時にキーチェーンのアクセス確認が一度出たら「常に許可」を選べば以後は出ない。

set -e
IDENTITY="SnapLocal Dev Cert"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# 既存の同名証明書/鍵を一掃(過去に key usage 不足の壊れた証明書を作っている可能性があるため)
while security find-certificate -c "$IDENTITY" "$LOGIN_KC" >/dev/null 2>&1; do
    security delete-identity -c "$IDENTITY" "$LOGIN_KC" >/dev/null 2>&1 \
        || security delete-certificate -c "$IDENTITY" "$LOGIN_KC" >/dev/null 2>&1 \
        || break
done

echo "自己署名のコード署名証明書を生成中..."
# code signing には keyUsage=digitalSignature と extendedKeyUsage=codeSigning の両方が必須。
# 前者が無いと codesign が "Invalid Key Usage for policy" → "no identity found" になる。
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

# 注意: PKCS12 経由は OpenSSL 3.x の既定暗号を macOS の security が読めず
# 「MAC verification failed」になる。鍵と証明書を PEM のまま別々にインポートし、
# キーチェーン側で公開鍵一致により identity に紐付けさせる(最も互換性が高い)。
echo "login キーチェーンへインポート中(codesign のみアクセス許可)..."
security import "$TMP/key.pem"  -k "$LOGIN_KC" -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$LOGIN_KC" -T /usr/bin/codesign

# 自己署名は既定で untrusted のため、コード署名用にユーザードメインで信頼設定する
# (sudo 不要。キーチェーンのパスワード確認ダイアログが一度出る場合あり)。
echo "コード署名用の信頼設定を付与中..."
security add-trusted-cert -p codeSign -k "$LOGIN_KC" "$TMP/cert.pem"

echo ""
# 実際に codesign できるかをダミーバイナリで検証(最も確実)
cp /bin/echo "$TMP/probe" 2>/dev/null || cp "$(command -v true)" "$TMP/probe"
if codesign --force --sign "$IDENTITY" "$TMP/probe" >/dev/null 2>&1; then
    echo "OK 完了。コード署名 ID が使える状態になりました。"
    echo "  次に:  bash build-app.sh   (Stable identity used と表示される)"
    echo "  その後アプリを起動し、画面録画を最後に一度だけ許可すれば以降は保持されます。"
    echo "  最初の codesign 実行時に鍵アクセスを尋ねられたら『常に許可』を選んでください。"
else
    echo "NG まだ codesign に使えません。次の出力を貼ってください:"
    echo "  security find-identity -v -p codesigning"
    security find-identity -v -p codesigning 2>/dev/null | grep -i snaplocal || true
    exit 1
fi
