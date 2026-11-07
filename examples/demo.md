---
theme: default
title: mp デモ
paginate: true
footer: mp demo
---

# mp で作るプレゼン

Markdown がそのまま全画面スライドになる

<!-- 表紙のノート。n キーで表示します -->

## 通常のスライド

<!-- ここで強調すること:
H2 ごとに 1 枚になる -->

H2 が **1枚のスライド** になり、見出しがページタイトルになります。

- 箇条書き、`インラインコード`、[リンク](https://example.com)
- 表や引用も使えます

> 引用はこのように表示されます

## 少しずつ表示する

`*` のリストは Marp と同じく 1 項目ずつ表示します。

* 1 つ目
* 2 つ目
* 3 つ目

## コードと数式

```ruby
def greet(name) = "Hello, #{name}!"
puts greet("mp")
```

インライン数式 $E = mc^2$ と、ブロック数式です。

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

## 背景画像を半分に敷く

![bg right:40%](assets/photo.svg)

`![bg right:40%](...)` で画面を分割します。

| 記法 | 意味 |
| --- | --- |
| `![w:200](a.png)` | 幅指定 |
| `![bg](a.png)` | 背景 |

<!-- _class: invert -->
<!-- _paginate: false -->

---

## ターミナルの埋め込み

Enter を押すまでコマンドは実行されません(`t` かクリックで操作)。

```terminal cwd=. font=20
echo "Hello from mp"
ls -la
```

## Web ページの埋め込み

```web
https://www.ruby-lang.org/ja/
```

## ターミナルとページを並べる

<!-- _class: columns -->

```terminal cwd=.
ruby -v
```

```web zoom=0.8
./local.html
```

# ありがとうございました

<!-- _class: lead -->
