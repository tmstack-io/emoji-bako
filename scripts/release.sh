#!/bin/zsh
# EmojiBakoのリリース用DMGを作る（署名・公証・ステープルまで）。GitHub Releasesへのアップロードはしない。
#
# 使い方（リポジトリのルートで実行）:
#     zsh scripts/release.sh
#
# 事前に必要なもの（初回だけ）:
#   1. Developer ID Application証明書（Xcode > Settings > Accounts > Manage Certificates > ＋ > Developer ID Application）
#   2. 公証用の認証情報をキーチェーンに保存する（Apple IDのApp用パスワードを使う）:
#        xcrun notarytool store-credentials notary-PCUA32D2L3 --apple-id <Apple ID> --team-id PCUA32D2L3
#      App用パスワードはMacごとに「notarytool-<Mac名>」の名前で発行し、プロファイルはチームごとに1つ（全アプリ共通）とする。
#      プロファイル名を変える場合は、環境変数NOTARY_PROFILEで指定する。
#   3. iCloud（使用回数の同期）を許可するDeveloper ID用のプロビジョニングプロファイル「EmojiBako Developer ID」:
#        developer.apple.comでApp ID io.tmstack.EmojiBakoのiCloudを有効にし、Profiles > ＋ > Developer IDで作成する。
#        ダウンロードしたファイルを ~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.provisionprofile に置く。
#        名前はscripts/ExportOptions.plistのprovisioningProfilesと一致させる。
#
# 公証はアプリとDMGの両方に行い、両方にチケットをステープルする（オフラインでも初回起動の検証が通るように）。
#
# 注意: 公証の待ち時間は数分から数十分かかる。画面がロックされるとnotarytoolがキーチェーンの認証情報を読めず、
# 「No Keychain password item found」で失敗するため、実行中は画面のスリープを止める。手動でロックした場合は防げない。
set -euo pipefail

# このスクリプトが終わるまで、画面のスリープ（とそれに伴う自動ロック）を止める
caffeinate -d -i -w $$ &!

TEAM_ID="PCUA32D2L3"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-${TEAM_ID}}"
BUNDLE_ID="io.tmstack.EmojiBako"
PROVISIONING_PROFILE_NAME="EmojiBako Developer ID"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
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

# 名前が一致するプロビジョニングプロファイルを探し、有効期限とiCloud KVSの許可を確かめる
PROFILE_PLIST="$(mktemp -t emojibako-profile)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
FOUND_PROFILE=""
for f in "$PROFILES_DIR"/*.provisionprofile(N); do
  if ! security cms -D -i "$f" > "$PROFILE_PLIST" 2>/dev/null; then
    print -u2 -- "⚠️ 読めないプロファイルを飛ばします: ${f}"
    continue
  fi
  [[ "$(plutil -extract Name raw -o - "$PROFILE_PLIST")" == "$PROVISIONING_PROFILE_NAME" ]] || continue
  [[ -z "$FOUND_PROFILE" ]] || fail "「${PROVISIONING_PROFILE_NAME}」という名前のプロファイルが複数あります。古いものを${PROFILES_DIR}から取り除いてください: ${FOUND_PROFILE} / ${f}"
  FOUND_PROFILE="$f"
  EXPIRATION="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")"
  [[ "$EXPIRATION" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || fail "プロファイル「${PROVISIONING_PROFILE_NAME}」の有効期限（${EXPIRATION}）が切れています。スクリプト冒頭の手順3で作り直してください。"
  [[ "$(plutil -extract Entitlements.com\\.apple\\.developer\\.ubiquity-kvstore-identifier raw -o - "$PROFILE_PLIST" 2>/dev/null)" == "${TEAM_ID}."* ]] \
    || fail "プロファイル「${PROVISIONING_PROFILE_NAME}」にiCloud key-value storageの許可がありません。App IDでiCloudを有効にしてから作り直してください。"
  [[ "$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - "$PROFILE_PLIST" 2>/dev/null)" == "${TEAM_ID}.${BUNDLE_ID}" ]] \
    || fail "プロファイル「${PROVISIONING_PROFILE_NAME}」のApp IDが${TEAM_ID}.${BUNDLE_ID}ではありません。"
done
[[ -n "$FOUND_PROFILE" ]] || fail "プロファイル「${PROVISIONING_PROFILE_NAME}」が${PROFILES_DIR}にありません。スクリプト冒頭の手順3を行ってください。"

print "署名に使う証明書: $IDENTITY"

# --- ビルドと書き出し ---------------------------------------------------------

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"
xcodegen generate
DIRTY="$(git status --porcelain)"
[[ -z "$DIRTY" ]] || fail "xcodegenの生成結果がコミット済みのファイルと異なります。project.ymlを変えたら、xcodegen generateで生成したxcodeprojとEmojiBako/Info.plistも一緒にコミットしてください。差分のあるファイル:
${DIRTY}"

xcodebuild archive \
  -project EmojiBako.xcodeproj -scheme EmojiBako -configuration Release \
  -archivePath "$OUT/EmojiBako.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_NAME" \
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
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || fail "書き出したアプリにプロビジョニングプロファイルが埋め込まれていません"
KVS_ID="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -extract com\\.apple\\.developer\\.ubiquity-kvstore-identifier raw -o - -)" \
  || fail "書き出したアプリの署名にiCloud KVSのentitlementがありません"
[[ "$KVS_ID" == "${TEAM_ID}.${BUNDLE_ID}" ]] || fail "署名のiCloud KVSの識別子が想定と異なります: ${KVS_ID}"

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
print "  gh release create v$VERSION \"$DMG\" \"$DMG.sha256\" --repo tmstack-io/emoji-bako --title \"EmojiBako $VERSION\""
