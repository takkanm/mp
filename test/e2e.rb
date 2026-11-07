# frozen_string_literal: true

# 実際のサーバと Chrome を起動して確認する: bundle exec ruby test/e2e.rb [スクショ出力先]
require "tmpdir"
require_relative "../lib/mp"

out = ARGV[0] || Dir.mktmpdir("mp-e2e-")
deck = File.expand_path("../examples/demo.md", __dir__)
size = (ENV["MP_E2E_SIZE"] || "1280x720").split("x").map(&:to_i)
app = Mp::App.new(deck, headless: true, watch: false, size: size).start
cdp = app.browser.cdp
session = app.page_session
failures = 0

check = lambda do |name, ok, detail = nil|
  failures += 1 unless ok
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{" (#{detail})" if detail && !ok}"
end
js = lambda do |expression|
  reply = cdp.call("Runtime.evaluate", { expression: expression, returnByValue: true, awaitPromise: true }, session_id: session)
  raise reply["exceptionDetails"].to_s if reply["exceptionDetails"]

  reply.dig("result", "value")
end
key = lambda do |name, code, vk, text = nil|
  base = { key: name, code: code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk }
  cdp.call("Input.dispatchKeyEvent", base.merge(type: text ? "keyDown" : "rawKeyDown", text: text).compact, session_id: session)
  cdp.call("Input.dispatchKeyEvent", base.merge(type: "keyUp"), session_id: session)
end
right = -> { key.call("ArrowRight", "ArrowRight", 39) }
shot = lambda do |name|
  data = cdp.call("Page.captureScreenshot", { format: "png" }, session_id: session)["data"]
  File.binwrite(File.join(out, "#{name}.png"), data.unpack1("m"))
end
wait_for = lambda do |expression, seconds = 8|
  deadline = Time.now + seconds
  sleep 0.1 until js.call(expression) || Time.now > deadline
  js.call(expression)
end
title = -> { js.call("document.querySelector('section.active h1, section.active h2')?.textContent") }
go_to = lambda do |heading|
  20.times { break if title.call == heading; right.call; sleep 0.05 }
  sleep 0.2
end
term_text = "[...document.querySelectorAll('.terminal-host:not([hidden]) .xterm-rows')].map(e => e.textContent).join('')"

begin
  wait_for.call("document.querySelector('section.slide.active')")
  count = js.call("document.querySelectorAll('section.slide').length")
  check.call("スライド枚数", count == 9, count)
  check.call("表紙", title.call == "mp で作るプレゼン", title.call)
  check.call("CSP エラーなしで KaTeX 描画", js.call("document.querySelectorAll('.katex').length") >= 2)
  check.call("画面にフィットする", js.call("document.getElementById('stage').getBoundingClientRect().width") > 0)
  shot.call("01_cover")

  right.call
  sleep 0.1
  check.call("→ で次のスライド", title.call == "通常のスライド", title.call)
  shot.call("02_normal")

  right.call
  sleep 0.1
  hidden = "[...document.querySelectorAll('section.active .fragment')].filter(e => !e.classList.contains('shown')).length"
  check.call("フラグメントは最初隠れる", js.call(hidden) == 3, js.call(hidden))
  right.call
  check.call("→ で 1 項目表示", js.call(hidden) == 2, js.call(hidden))
  right.call
  right.call
  shot.call("03_fragments")

  go_to.call("コードと数式")
  check.call("コードブロックが pre で描画される", js.call("!!document.querySelector('section.active pre.highlight span')"))
  footer_bottom = js.call("(() => { const s = document.getElementById('stage').getBoundingClientRect(); const f = document.querySelector('section.active footer').getBoundingClientRect(); return (s.bottom - f.bottom) / s.height })()")
  check.call("フッターがスライド下端にある", footer_bottom < 0.06, footer_bottom)
  shot.call("04_code")
  go_to.call("背景画像を半分に敷く")
  check.call("背景画像の読み込み", js.call("fetch('assets/photo.svg').then(r => r.ok)"))
  shot.call("05_background")

  go_to.call("ターミナルの埋め込み")
  sleep 1.5
  wait_for.call("#{term_text}.includes('echo \"Hello from mp\"')")
  screen = js.call(term_text)
  check.call("台本のコマンドが入力される", screen.include?('echo "Hello from mp"'), screen)
  check.call("Enter まで実行されない", !screen.gsub('echo "Hello from mp"', "").include?("Hello from mp"), screen)
  key.call("t", "KeyT", 84, "t")
  sleep 0.1
  key.call("Enter", "Enter", 13, "\r")
  wait_for.call("#{term_text}.replace('echo \"Hello from mp\"', '').includes('Hello from mp')")
  check.call("Enter で実行される", js.call(term_text).sub('echo "Hello from mp"', "").include?("Hello from mp"), js.call(term_text))
  wait_for.call("#{term_text}.includes('ls -la')")
  check.call("次のコマンドが入力される", js.call(term_text).include?("ls -la"), js.call(term_text))
  key.call("Enter", "Enter", 13, "\r")
  wait_for.call("#{term_text}.includes('demo.md')")
  check.call("cwd がデッキのディレクトリ", js.call(term_text).include?("demo.md"), js.call(term_text))
  shot.call("06_terminal")
  fits = js.call("(() => { const h = document.querySelector('.terminal-host:not([hidden])'); const s = h.querySelector('.xterm-screen').getBoundingClientRect(), b = h.getBoundingClientRect(); return s.width <= b.width + 1 && s.height <= b.height + 1 })()")
  check.call("ターミナルが枠内に収まる", fits)
  sized = js.call("(() => { const t = [...terminals.values()][0]; return [t.term.options.fontSize, scale] })()")
  check.call("文字サイズが倍率に追従する", (sized[0] - 20 * sized[1]).abs <= 0.5, sized)
  js.call("document.querySelector('.terminal-host:not([hidden]) .xterm-helper-textarea').blur()")

  go_to.call("Web ページの埋め込み")
  check.call("別スライドではターミナルが隠れる", js.call("document.querySelectorAll('.terminal-host:not([hidden])').length") == 0)
  sleep 3
  frames = cdp.call("Target.getTargets")["targetInfos"].select { _1["type"] == "iframe" }.map { _1["url"] }
  check.call("Web 埋め込みの読み込み", frames.any? { _1.include?("ruby-lang.org") }, frames)
  check.call("アプリの URL が維持される", js.call("location.href").include?("/#"), js.call("location.href"))
  shot.call("07_web")

  go_to.call("ターミナルとページを並べる")
  sleep 2
  shot.call("08_columns")

  # Web 埋め込みの操作: クリックで操作でき、マウスが出るとキー操作がスライドへ戻る
  box = js.call("(() => { const r = document.querySelector('section.active .embed-web').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2, r.x - 40] })()")
  mouse = lambda do |type, x, y|
    args = { type: type, x: x, y: y }
    args.merge!(button: "left", clickCount: 1) unless type == "mouseMoved"
    cdp.call("Input.dispatchMouseEvent", args, session_id: session)
  end
  click = lambda do
    mouse.call("mouseMoved", box[0], box[1])
    mouse.call("mousePressed", box[0], box[1])
    mouse.call("mouseReleased", box[0], box[1])
    sleep 0.3
  end
  shield = "document.querySelector('section.active .shield').hidden"
  check.call("最初はシールドが覆う", js.call(shield) == false)
  click.call
  check.call("クリックでシールドが外れる", js.call(shield) == true)
  click.call
  local = cdp.call("Target.getTargets")["targetInfos"].find { _1["url"].end_with?("local.html") }
  count = if local
            frame = cdp.call("Target.attachToTarget", { targetId: local["targetId"], flatten: true })["sessionId"]
            cdp.call("Runtime.evaluate", { expression: "document.getElementById('n').textContent", returnByValue: true }, session_id: frame).dig("result", "value")
          else
            js.call("document.querySelector('section.active iframe').contentDocument?.getElementById('n')?.textContent ?? 'cross-origin'")
          end
  check.call("埋め込みページをクリックできる", count == "1", count)
  mouse.call("mouseMoved", box[2], box[1])
  sleep 0.2
  check.call("マウスが出るとシールドが戻る", js.call(shield) == false)
  go_to.call("ありがとうございました")
  offset = js.call("(() => { const s = document.querySelector('section.active').getBoundingClientRect(); const r = document.createRange(); r.selectNodeContents(document.querySelector('section.active h1')); const h = r.getBoundingClientRect(); return [Math.abs((h.left + h.right - s.left - s.right) / 2), Math.abs((h.top + h.bottom - s.top - s.bottom) / 2)] })()")
  check.call("タイトルのみのページは中央に置く", offset.all? { _1 < 2 }, offset)
  left_gap = js.call("(() => { const s = document.querySelector('section.active').getBoundingClientRect(); const r = document.createRange(); r.selectNodeContents(document.querySelector('section.active footer')); return (r.getBoundingClientRect().left - s.left) / s.width })()")
  check.call("中央のページでもフッターは左", left_gap < 0.1, left_gap)
  shot.call("09_end")

  # セキュリティ
  port = app.server.port
  blocked = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/wrongtoken/_mp/deck.json"))
  check.call("トークンなしは 404", blocked.code == "404", blocked.code)
  base = "http://127.0.0.1:#{port}/#{app.server.token}"
  traversal = Net::HTTP.get_response(URI("#{base}/..%2f..%2fGemfile"))
  check.call("パストラバーサルを拒否", traversal.code == "404", traversal.code)
  ws = Net::HTTP.new("127.0.0.1", port).get("/#{app.server.token}/_mp/pty?id=e1",
                                            { "Origin" => "http://evil.example", "Upgrade" => "websocket",
                                              "Connection" => "Upgrade", "Sec-WebSocket-Version" => "13",
                                              "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==" })
  check.call("別 Origin の PTY 接続を拒否", ws.code == "403", ws.code)
  html = Net::HTTP.get_response(URI("#{base}/local.html"))
  check.call("デッキ内 HTML は sandbox", html["content-security-policy"].to_s.start_with?("sandbox"), html.to_hash)
ensure
  app.stop
end

puts "screenshots: #{out}"
exit(failures.zero? ? 0 : 1)
