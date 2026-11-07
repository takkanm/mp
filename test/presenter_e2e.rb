# frozen_string_literal: true

# 発表者ビューの確認: bundle exec ruby test/presenter_e2e.rb [スクショ出力先]
require "tmpdir"
require_relative "../lib/mp"

out = ARGV[0] || Dir.mktmpdir("mp-presenter-")
deck = File.expand_path("../examples/demo.md", __dir__)
app = Mp::App.new(deck, headless: true, watch: false, size: [1600, 900]).start
cdp = app.browser.cdp
audience = app.page_session
failures = 0

check = lambda do |name, ok, detail = nil|
  failures += 1 unless ok
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{" (#{detail})" if detail && !ok}"
end
js = lambda do |session, expression|
  reply = cdp.call("Runtime.evaluate", { expression: expression, returnByValue: true, awaitPromise: true }, session_id: session)
  raise reply["exceptionDetails"].to_s if reply["exceptionDetails"]

  reply.dig("result", "value")
end
key = lambda do |session, name, code, vk, text = nil|
  base = { key: name, code: code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk }
  cdp.call("Input.dispatchKeyEvent", base.merge(type: text ? "keyDown" : "rawKeyDown", text: text).compact, session_id: session)
  cdp.call("Input.dispatchKeyEvent", base.merge(type: "keyUp"), session_id: session)
end
wait_for = lambda do |session, expression, seconds = 8|
  deadline = Time.now + seconds
  sleep 0.1 until js.call(session, expression) || Time.now > deadline
  js.call(session, expression)
end
shot = lambda do |session, name|
  File.binwrite(File.join(out, "#{name}.png"), cdp.call("Page.captureScreenshot", { format: "png" }, session_id: session)["data"].unpack1("m"))
end
right = ->(session) { key.call(session, "ArrowRight", "ArrowRight", 39); sleep 0.15 }
left = ->(session) { key.call(session, "ArrowLeft", "ArrowLeft", 37); sleep 0.15 }
heading = ->(session, id) { js.call(session, "document.querySelector('#{id} section.active :is(h1, h2)')?.textContent") }
audience_heading = -> { heading.call(audience, "#stage") }

begin
  wait_for.call(audience, "document.querySelector('section.slide.active')")

  key.call(audience, "p", "KeyP", 80, "p")
  target = nil
  50.times do
    target = cdp.call("Target.getTargets")["targetInfos"].find { _1["url"] == app.server.presenter_url }
    break if target

    sleep 0.1
  end
  check.call("p で発表者ビューが開く", !target.nil?)
  presenter = cdp.call("Target.attachToTarget", { targetId: target["targetId"], flatten: true })["sessionId"]
  wait_for.call(presenter, "document.querySelector('#current section.active')")
  sleep 0.3

  key.call(audience, "p", "KeyP", 80, "p")
  sleep 0.5
  windows = cdp.call("Target.getTargets")["targetInfos"].count { _1["url"] == app.server.presenter_url }
  check.call("二重に開かない", windows == 1, windows)

  check.call("現在のスライドが表示される", heading.call(presenter, "#current") == "mp で作るプレゼン", heading.call(presenter, "#current"))
  check.call("次のスライドが表示される", heading.call(presenter, "#next") == "通常のスライド", heading.call(presenter, "#next"))
  check.call("ノートが表示される", js.call(presenter, "document.getElementById('speaker-notes').textContent").include?("表紙のノート"))
  check.call("ページ番号", js.call(presenter, "document.getElementById('page').textContent") == "1 / 9")

  right.call(presenter)
  check.call("発表者の操作で聴衆画面が進む", audience_heading.call == "通常のスライド", audience_heading.call)
  check.call("発表者ビューも追従する", heading.call(presenter, "#current") == "通常のスライド")
  check.call("複数行ノート", js.call(presenter, "document.getElementById('speaker-notes').textContent").include?("\n"))
  shot.call(presenter, "p1_normal")

  right.call(audience)
  sleep 0.15
  check.call("聴衆側の操作にも追従する", heading.call(presenter, "#current") == "少しずつ表示する")
  shown = ->(id) { js.call(presenter, "document.querySelectorAll('#{id} section.active .fragment.shown').length") }
  check.call("次の枠は次の項目を先に見せる", shown.call("#current") == 0 && shown.call("#next") == 1, [shown.call("#current"), shown.call("#next")])
  right.call(presenter)
  check.call("項目の表示も同期する", shown.call("#current") == 1 && js.call(audience, "document.querySelectorAll('section.active .fragment.shown').length") == 1)
  right.call(presenter); right.call(presenter)
  check.call("全項目のあとは次の枠が次のスライド", heading.call(presenter, "#next") == "コードと数式", heading.call(presenter, "#next"))
  left.call(presenter)
  check.call("戻ると項目が隠れる", shown.call("#current") == 2, shown.call("#current"))
  right.call(presenter)

  check.call("スライドのタイマーが動く", js.call(presenter, "/^\\d\\d:\\d\\d$/.test(document.getElementById('elapsed').textContent)"))

  key.call(presenter, "6", "Digit6", 54, "6")
  key.call(presenter, "Enter", "Enter", 13, "\r")
  sleep 0.2
  check.call("番号指定で移動", audience_heading.call == "ターミナルの埋め込み", audience_heading.call)

  script = "document.getElementById('script').textContent"
  check.call("入力前は Enter を案内しない", !js.call(presenter, script).include?("Enter"), js.call(presenter, script))
  key.call(presenter, "Enter", "Enter", 13, "\r") # 早押ししても空行を送らない
  wait_for.call(presenter, "#{script}.includes('Enter で実行')")
  check.call("台本の次のコマンドを表示", js.call(presenter, script).include?('echo "Hello from mp"'), js.call(presenter, script))
  check.call("ミラーが表示される", wait_for.call(presenter, "!document.getElementById('mirror').hidden"))
  term = "[...document.querySelectorAll('.terminal-host:not([hidden]) .xterm-rows')].map(e => e.textContent).join('')"
  key.call(presenter, "Enter", "Enter", 13, "\r")
  wait_for.call(audience, "#{term}.replace('echo \"Hello from mp\"', '').includes('Hello from mp')")
  check.call("発表者の Enter で聴衆のターミナルが実行", js.call(audience, term).sub('echo "Hello from mp"', "").include?("Hello from mp"), js.call(audience, term))
  wait_for.call(presenter, "#{script}.includes('Enter で実行: ls -la')")
  check.call("次のコマンドへ進む", js.call(presenter, script).include?("ls -la"), js.call(presenter, script))
  before = js.call(presenter, "document.getElementById('mirror').src.length")
  key.call(presenter, "Enter", "Enter", 13, "\r")
  wait_for.call(presenter, "#{script}.includes('すべて実行')")
  wait_for.call(presenter, "document.getElementById('mirror').src.length !== #{before}")
  check.call("ミラーが更新される", js.call(presenter, "document.getElementById('mirror').src.length") != before)
  sleep 0.6
  shot.call(presenter, "p2_terminal")

  right.call(presenter)
  sleep 3
  check.call("Web スライドもミラー", js.call(presenter, "!document.getElementById('mirror').hidden"))
  check.call("台本表示が消える", js.call(presenter, "document.getElementById('script').hidden"))
  shot.call(presenter, "p3_web")

  key.call(presenter, "End", "End", 35)
  sleep 0.3
  check.call("End で最後へ", audience_heading.call == "ありがとうございました", audience_heading.call)
  check.call("最後は次の枠に案内", js.call(presenter, "!document.getElementById('end').hidden"))
  check.call("埋め込みのないスライドでミラーが消える", js.call(presenter, "document.getElementById('mirror').hidden"))

  cdp.call("Target.closeTarget", { targetId: target["targetId"] })
  sleep 0.5
  check.call("発表者ビューを閉じても発表は続く", audience_heading.call == "ありがとうございました")
  check.call("閉じたら接続が解除される", !app.server.presenter_connected?)
ensure
  app.stop
end

puts "screenshots: #{out}"
exit(failures.zero? ? 0 : 1)
