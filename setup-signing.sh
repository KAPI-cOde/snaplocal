#!/bin/bash
# setup-signing.sh — 開発ビルドの「毎回 画面録画権限を承認し直す」問題を一度きりで解消する。
#
# 背景: build-app.sh のアドホック署名(codesign --sign -)はビルドごとにバイナリのハッシュが
# 変わり、macOS の TCC が画面録画権限を黙って失効させる。そのため build-app.sh は tccutil reset で
# 毎回プロンプトを出し直していた。安定した自己署名証明書で署名すれば、署名の designated requirement
# がハッシュに依存しなくなり、再ビルドをまたいで権限が保持される(=承認は最初の一回だけ)。
#
# このスクリプトは「SnapLocal Dev Cert」という自己署名のコード署名証明書を login キーチェーンに
# 1つ作り、コード署名用に信頼設定する(codesign が identity として使えるようにする)だけ。
# ネットワーク通信なし・sudo 不要(信頼設定はユーザードメイン)・SnapLocal 専用ローカル鍵。
# 冪等: 再実行しても証明書は作り直さず、信頼設定だけ確実にする。
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

# 証明書(と鍵)がまだ無ければ生成してインポート
if security find-certificate -c "$IDENTITY" "$LOGIN_KC" >/dev/null 2>&1; then
    echo "証明書「$IDENTITY」は既に存在します。信頼設定だけ確認します。"
else
    echo "自己署名のコード署名証明書を生成中…"
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
        -subj "/CN=$IDENTITY" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

    # 注意: PKCS12 経由は OpenSSL 3.x の既定暗号を macOS の security が読めず
    # 「MAC verification failed」になる。鍵と証明書を PEM のまま別々にインポートし、
    # キーチェーン側で公開鍵一致により identity に紐付けさせる(最も互換性が高い)。
    echo "login キーチェーンへインポート中(codesign のみアクセス許可)…"
    security import "$TMP/key.pem"  -k "$LOGIN_KC" -T /usr/bin/codesign
    security import "$TMP/cert.pem" -k "$LOGIN_KC" -T /usr/bin/codesign
fi

# コード署名用に信頼設定する。自己署名は既定で untrusted(CSSMERR_TP_NOT_TRUSTED)のため
# codesign が "no identity found" になる。ユーザードメインの信頼設定で解消(sudo 不要、
# キーチェーンのパスワード確認ダイアログが一度出る場合あり)。証明書をキーチェーンから
# PEM 取り出して add-trusted-cert に渡す。
echo "コード署名用の信頼設定を付与中…"
security find-certificate -c "$IDENTITY" -p "$LOGIN_KC" > "$TMP/cert.pem"
security add-trusted-cert -p codeSign -k "$LOGIN_KC" "$TMP/cert.pem"

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ 完了。コード署名 ID をコード署名用に信頼設定しました。"
    echo "  次回 bash build-app.sh からはこの ID で署名され、画面録画権限は一度許可すれば保持されます。"
    echo "  最初の1回だけ codesign が鍵アクセスを尋ねたら『常に許可』を選んでください。"
else
    echo "⚠ まだ valid な署名 ID として認識されていません。"
    echo "  次を確認してください:  security find-identity -v -p codesigning"
    exit 1
fi
