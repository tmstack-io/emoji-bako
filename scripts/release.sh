#!/bin/zsh
# EmojiBakoのリリース用DMGを作る（署名・公証・ステープルまで）。GitHub Releasesへのアップロードはしない。
#
# 使い方（リポジトリのルートで実行）:
#     zsh scripts/release.sh
#
# 事前に必要なもの（初回だけ）:
#   1. Developer ID Application証明書（Xcode > Settings > Accounts > Manage Certificates > ＋ > Developer ID Application）
#   2. 公証用の認証情報をキーチェーンに保存する（Apple IDのApp用パスワードを使う）:
#        xcrun notarytool store-credentials EmojiBako --apple-id <Apple ID> --team-id PCUA32D2L3
#      プロファイル名を変える場合は、環境変数NOTARY_PROFILEで指定する。
#
# 公証はアプリとDMGの両方に行い、両方にチケットをステープルする（オフラインでも初回起動の検証が通るように）。
set -euo pipefail

TEAM_ID="PCUA32D2L3"
NOTARY_PROFILE="${NOTARY_PROFILE:-EmojiBako}"
ROOT="${0:A:h:h}"
OUT="$ROOT/build/release"

fail() {
  print -u2 -- "❌ $1"
  exit 1
}

# --- 事前確認 ---------------------------------------------------------------

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
[[ -n "$IDENTITY" ]] || fail "チーム${TEAM_ID}のDeveloper ID Application証明書がキーチェーンにありません。スクリプト冒頭の手順1を行ってください。"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "公証用のキーチェーンプロファイル「${NOTARY_PROFILE}」を使えません。スクリプト冒頭の手順2を行ってください。"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || fail "コミットされていない変更があります。リリースはコミット済みの状態から作ってください。"

print "署名に使う証明書: $IDENTITY"

# --- ビルドと書き出し ---------------------------------------------------------

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"
xcodegen generate
[[ -z "$(git status --porcelain)" ]] || fail "xcodegenの生成結果がコミット済みのxcodeprojと異なります。project.ymlとxcodeprojを揃えてコミットしてください。"

xcodebuild archive \
  -project EmojiBako.xcodeproj -scheme EmojiBako -configuration Release \
  -archivePath "$OUT/EmojiBako.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  | grep -E "error:|warning:|ARCHIVE (SUCCEEDED|FAILED)"
xcodebuild -exportArchive \
  -archivePath "$OUT/EmojiBako.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"

APP="$OUT/export/EmojiBako.app"
[[ -d "$APP" ]] || fail "書き出したアプリが見つかりません: ${APP}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$(lipo -archs "$APP/Contents/MacOS/EmojiBako")" == "arm64" ]] || fail "arm64のみのバイナリになっていません"
codesign --verify --strict --deep "$APP"

# --- アプリの公証 -------------------------------------------------------------

ditto -c -k --keepParent "$APP" "$OUT/EmojiBako-app.zip"
xcrun notarytool submit "$OUT/EmojiBako-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

# --- DMGの作成と公証 ----------------------------------------------------------

DMG="$OUT/EmojiBako-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "EmojiBako $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# --- 検証 ---------------------------------------------------------------------

spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"

print "\n✅ $DMG"
print "次の手順（GitHubへの公開は内容を確認してから手動で行う）:"
print "  git tag v$VERSION && git push origin v$VERSION"
print "  gh release create v$VERSION \"$DMG\" \"$DMG.sha256\" --repo tmstack-io/EmojiBako --title \"EmojiBako $VERSION\""
