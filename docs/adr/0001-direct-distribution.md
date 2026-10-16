# Mac App Storeではなく、Developer ID署名のDMGで直接配布する

EmojiBakoは選んだ絵文字を入力するために、アクセシビリティ権限を使って作業中のアプリへ`Cmd + V`を送る。Mac App StoreではApp Sandboxが必須になり、このキー送信が審査で問題になるおそれがある。そのため、公証済みのDMGをGitHubで直接配布する。App Storeでの配布は、需要を確かめてから改めて検討する。

## Consequences

- 更新の仕組みをアプリ自身が持つ必要がある（Storeの自動更新が使えないため）。
