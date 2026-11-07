# mp

Markdown を全画面プレゼンテーションにする Ruby 製ツールです。スライドに本物のターミナルと Web ページを埋め込めます。

## 必要なもの

- Ruby 3.3 以上
- Chrome 系ブラウザ(Chrome / Chromium / Edge / Brave。別の場所にある場合は `MP_BROWSER` でパスを指定)

## 使い方

```bash
bundle install
bundle exec exe/mp examples/demo.md
```

| オプション | 説明 |
| --- | --- |
| `-w`, `--window` | 全画面にせずウィンドウで開く |
| `-P`, `--presenter` | 発表者ビューも開く |
| `-p`, `--port PORT` | ローカルサーバのポート(既定は空きポート) |
| `--profile DIR` | Chrome のプロファイルを保存する(埋め込みページのログインを保持) |
| `--no-watch` | ファイル変更時に再読み込みしない |

Markdown や CSS を保存すると自動で再読み込みします。このときターミナルのセッションはリセットされます。

## スライドの書き方

| 記法 | 結果 |
| --- | --- |
| `# 見出し` | 表紙スライド。次の H2 までの本文も表紙に入る |
| `## 見出し` | 通常のスライド 1 枚。見出しがページタイトルになる |
| `---` | タイトルなしの続きスライド |

見出しだけで本文がないスライドは、タイトルを画面の中央に置きます。左に寄せるには `<!-- _class: left -->` を書きます。

## ターミナルの埋め込み

````markdown
```terminal cwd=./demo height=60% font=20
npm test
git status
```
````

本文に書いたコマンドは 1 行ずつ入力欄に打ち込まれますが、**Enter を押すまで実行されません**。実行すると次の行が打ち込まれます。本文は空でも構いません。

| 属性 | 説明 |
| --- | --- |
| `cwd` | 作業ディレクトリ(デッキからの相対パス) |
| `height` / `width` | 大きさ(`60%`、`400px`)。省略すると残りの領域を埋める |
| `font` | 文字サイズ(既定 18) |

## Web ページの埋め込み

````markdown
```web zoom=0.8 height=70%
https://example.com
```
````

本文には `http(s)` の URL か、デッキからの相対パス(`./page.html`)を書きます。`X-Frame-Options` などで埋め込みを拒否するサイトも表示できます。

| 属性 | 説明 |
| --- | --- |
| `zoom` | 表示倍率 |
| `height` / `width` | ターミナルと同じ |

クリックするとページを操作でき、マウスが外に出るとスライドのキー操作に戻ります。

ターミナルとページを横に並べるには `<!-- _class: columns -->` を使います。

## Marp 互換の記法

**フロントマター / ディレクティブ**

```markdown
---
theme: default        # default / dark / ./my-theme.css
size: 16:9            # 16:9 / 4:3
title: タイトル
paginate: true
header: ヘッダー
footer: フッター
style: |
  section { font-size: 28px; }
---

<!-- class: lead -->             以降のスライドに適用
<!-- _backgroundColor: black --> このスライドだけに適用(先頭に _)
```

使えるディレクティブは `paginate` `header` `footer` `class` `color` `backgroundColor` `backgroundImage` `backgroundPosition` `backgroundRepeat` `backgroundSize` です。クラスには `lead`(中央寄せ)、`left`(左寄せ)、`invert`(配色反転)、`columns`(2 列)があります。

**画像**

```markdown
![w:300 h:200](a.png)            サイズ指定
![blur:5px grayscale](a.png)     フィルタ
![bg](a.png)                     背景(複数並べると分割)
![bg contain](a.png)             cover / contain / fit / auto / 50%
![bg right:40%](a.png)           画面を分割して片側に配置
```

**その他**

- 上記以外の `<!-- コメント -->` は発表者ノートになる(`n` で表示)
- `*` のリストは 1 項目ずつ表示し、`-` のリストは一度に表示する
- `# <!-- fit --> 見出し` は見出しを横幅いっぱいに拡大する
- `<style scoped>` はそのスライドだけに効く
- 数式は `$...$` と `$$...$$`(KaTeX)
- コードはシンタックスハイライトされる(Rouge)

## 発表者ビュー

```bash
bundle exec exe/mp --presenter examples/demo.md
```

発表中に `p` を押しても開けます。現在のスライド、次のスライド、発表者ノート、経過時間、現在時刻を表示します。

- **操作:** 発表者ビューのキー操作は聴衆画面に反映されます。聴衆画面を操作した場合も発表者ビューが追従します
- **次の枠:** `*` リストの未表示項目が残っていれば、次に表示される項目を先に見せます
- **ターミナルと Web:** 現在の枠には聴衆画面をそのまま映します(1 秒に数回更新)。次の枠にはコマンドや URL を表示します
- **台本の実行:** ターミナルのスライドでは次のコマンドを表示し、発表者ビューの `Enter` で聴衆画面のターミナルを実行します
- **ディスプレイ:** 外部ディスプレイがあれば、聴衆画面をそちらの全画面に移し、発表者ビューを手元の画面に置きます
- **閉じる:** 発表者ビューだけを閉じても発表は続きます。`q` を押すと全体が終了します

| キー | 動作 |
| --- | --- |
| `→` `↓` `Space` `PageDown` | 次へ |
| `←` `↑` `PageUp` | 前へ |
| `Home` / `End` | 最初 / 最後 |
| 数字 + `Enter` | そのページへ |
| `Enter` | 台本のコマンドを実行 |
| `r` | 経過時間をリセット |
| `+` / `-` | ノートの文字サイズ |
| `q` | 終了 |

1 画面で使うと、発表者ビューが聴衆画面の全画面の裏に隠れます。macOS ではスペースを切り替えて表示してください。

## キー操作

| キー | 動作 |
| --- | --- |
| `→` `↓` `Space` `PageDown` | 次へ |
| `←` `↑` `PageUp` | 前へ |
| `Home` / `End` | 最初 / 最後 |
| 数字 + `Enter` | そのページへ |
| `t` またはクリック | ターミナルを操作 |
| `⌘.` | ターミナルから抜ける |
| `⌘←` / `⌘→` | ターミナル操作中でもページ移動 |
| `f` | 全画面の切り替え |
| `n` | 発表者ノート |
| `p` | 発表者ビュー |
| `?` | ヘルプ |
| `q` | 終了 |

## しくみと安全性

Ruby のローカルサーバ(puma)がスライドを配信し、Chrome をアプリモードで開きます。ターミナルは Ruby の `PTY` と WebSocket で xterm.js につなぎます。Web 埋め込みでは、Chrome DevTools Protocol でフレームのレスポンスから `X-Frame-Options` と CSP の `frame-ancestors` を取り除きます。

ターミナルはコマンドを実行できるので、次のように保護しています。

- サーバは `127.0.0.1` のみで待ち受け、全パスにランダムトークンを要求する
- WebSocket は Origin を検証する
- CSP により、デッキ内の HTML に書いたスクリプトは実行されない
- デッキ配下の HTML は sandbox で配信し、ターミナルへ接続できない
- コマンドは Enter を押すまで実行されない

それでも、Enter を押せば書かれたコマンドは実行されます。**他人が作ったデッキは内容を確認してから発表してください。**

埋め込みを拒否するヘッダを外すのは、mp が起動する Chrome の中だけです。この Chrome は既定で一時プロファイルを使い、普段のプロファイルには影響しません。

## 制限

- 埋め込みページは iframe なので、サードパーティ Cookie の制限によりログイン状態を維持できないサイトがあります
- `:smile:` 形式の絵文字ショートコードは未対応です(Unicode の絵文字は使えます)
- 発表者ビューから入力できるのは `Enter` だけです。台本にないコマンドを打つときは、聴衆画面のターミナルをクリックしてください

## 開発

```bash
bundle exec rake test
bundle exec ruby test/e2e.rb
bundle exec ruby test/presenter_e2e.rb
```

`test/e2e.rb` と `test/presenter_e2e.rb` はヘッドレス Chrome で実際に動かして確認します。Web 埋め込みの確認にはネットワーク接続が必要です。

`vendor/assets` には xterm.js と KaTeX を同梱しています。実行に Node.js は不要です。

## リリース

| コマンド | 説明 |
| --- | --- |
| `bundle exec rake build` | テストを実行し、`pkg/` に gem を作る |
| `bundle exec rake install` | gem を作ってローカルにインストールする |
| `bundle exec rake release` | テスト、ビルド、タグ付け、push、RubyGems への公開を行う |

手順は次のとおりです。

1. `lib/mp/version.rb` のバージョンを上げる
2. `bundle install` で `Gemfile.lock` を更新する
3. 変更をコミットする
4. `bundle exec rake release` を実行する

`rake release` にはコミット済みの git リポジトリと `origin` リモート、RubyGems の認証情報が必要です。未コミットの変更があると公開前に中断します。
