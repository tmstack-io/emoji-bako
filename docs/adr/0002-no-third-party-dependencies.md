# アプリと生成スクリプトにサードパーティ製の依存を入れない

EmojiBakoはアクセシビリティ権限とクリップボードを扱い、自分自身の更新の仕組みも持つ。依存ライブラリが乗っ取られた場合の被害が大きいので、サプライチェーン攻撃を避けるためにサードパーティ製の依存を一切入れない。使ってよいのはAppleのフレームワークとmacOS標準のツールだけとする。

ただし、XcodeGenのように開発者の手元だけで動き、アプリに組み込まれない開発ツールは対象外とする。こうしたツールが生成したもの（`.xcodeproj`など）は、差分をレビューしてからリポジトリに入れる。

## Considered Options

- **ホットキー**: `sindresorhus/KeyboardShortcuts`を使わず、Carbonの`RegisterEventHotKey`とキーを記録するUIを自前で実装する。
- **更新**: Sparkleを使わず、GitHub Releases APIで最新版を確認して通知するだけにする。インストールは利用者が手動で行い、DMGの検証は公証とGatekeeperに任せる。
- **読みの生成**: pykakasiやSudachiPyを使わず、`CFStringTokenizer`と`CFStringTransform`で読みを作る。精度が足りない分は`claude -p`によるチェックと修正表で補う。
- **配布ページ**: GitHub Actionsを使わず、`main`ブランチの`/docs`からGitHub Pagesで公開する。
