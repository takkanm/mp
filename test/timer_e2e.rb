# frozen_string_literal: true

# duration のタイマーを確認する: bundle exec ruby test/timer_e2e.rb [スクショ出力先]
require "timeout"
require "tmpdir"
require_relative "../lib/mp"

out = ARGV[0] || Dir.mktmpdir("mp-timer-")
failures = 0
check = lambda do |name, ok, detail = nil|
  failures += 1 unless ok
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{" (#{detail})" if detail && !ok}"
end

# 条件を満たすまで待つ。上限を過ぎたら false
def wait_until(seconds = 8)
  deadline = Time.now + seconds
  sleep 0.1 until (ok = yield) || Time.now > deadline
  !!ok
end

def run(deck, out, shot_name = nil)
  app = Mp::App.new(deck, headless: true, watch: true).start
  cdp = app.browser.cdp
  session = app.page_session
  js = lambda do |s, expression|
    cdp.call("Runtime.evaluate", { expression: expression, returnByValue: true }, session_id: s).dig("result", "value")
  end
  wait_until { js.call(session, "document.querySelector('section.slide.active') && 1") } or raise "スライドが表示されません"
  sleep 0.3
  yield app, cdp, session, js
  if shot_name
    File.binwrite(File.join(out, "#{shot_name}.png"), cdp.call("Page.captureScreenshot", { format: "png" }, session_id: session)["data"].unpack1("m"))
  end
ensure
  app&.stop
end

timer = "document.getElementById('timer')"
total = "#{timer}.querySelector('.timer-total')"
page = "#{timer}.querySelector('.timer-slide')"
pages = "#{timer}.querySelector('.timer-pages')"
text = ->(selector) { "#{selector}.querySelector('b')?.textContent ?? #{selector}.textContent" }

Timeout.timeout(150) do Dir.mktmpdir("mp-timer-") do |dir|
  deck = File.join(dir, "deck.md")

  # 20 分で表紙と 2 枚 → 表紙を除いて 1 枚 10 分
  File.write(deck, "---\nduration: '20:00'\npaginate: true\n---\n\n# 表紙\n\n## 本文\n\nテキスト\n\n## 2 枚目\n")
  run(deck, out, "t1_normal") do |app, cdp, session, js|
    key = lambda do |s, name, code, vk|
      base = { key: name, code: code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk }
      cdp.call("Input.dispatchKeyEvent", base.merge(type: "keyDown", text: name), session_id: s)
      cdp.call("Input.dispatchKeyEvent", base.merge(type: "keyUp"), session_id: s)
    end
    seconds = ->(mmss) { mmss.to_s[/\d+:\d+/]&.split(":")&.then { |m, ss| (m.to_i * 60) + ss.to_i } }

    # 表紙にいる間は始まらない
    sleep 1.5
    check.call("表紙ではタイマーが始まらない", js.call(session, "startedAt").nil? && app.server.send(:timer_start).nil?)
    check.call("表紙では全体の残りが止まっている", js.call(session, text.(total)) == "20:00", js.call(session, text.(total)))
    check.call("表紙ではページの残りを出さない", js.call(session, "#{page}.hidden") == true)
    check.call("表紙でも枚数は出す", js.call(session, "#{pages}.textContent") == "1 / 3", js.call(session, "#{pages}.textContent"))

    # 次のページで始まる
    js.call(session, "show(1, { fragments: 'all' }); 0")
    check.call("表紙の次へ進むと始まる", wait_until(3) { js.call(session, "startedAt") })
    sleep 0.3
    check.call("全体の残りを表示する", js.call(session, text.(total)).match?(/\A(20:00|19:5\d)\z/), js.call(session, text.(total)))
    check.call("ページ番号と総枚数を表示する", js.call(session, "#{pages}.textContent") == "2 / 3", js.call(session, "#{pages}.textContent"))
    check.call("持ち時間は表紙を除いて均等割り", js.call(session, text.(page)).match?(/\A(10:00|09:5\d)\z/), js.call(session, text.(page)))
    check.call("通常の色", js.call(session, "#{total}.dataset.state") == "normal" && js.call(session, "#{page}.dataset.state") == "normal")
    place = js.call(session, "(() => { const s = document.getElementById('stage').getBoundingClientRect(), t = #{timer}.getBoundingClientRect(); return [(s.right - t.right) / s.width, (s.bottom - t.bottom) / s.height] })()")
    check.call("右下に置く", place.all? { _1.between?(0, 0.05) }, place)
    check.call("paginate のページ番号は隠す", js.call(session, "getComputedStyle(document.querySelector('section.active .page-number')).display") == "none")

    # ページを離れても使った時間は残り、戻ると続きから数える
    sleep 2.1
    js.call(session, "show(2, { fragments: 'all' }); 0")
    sleep 0.3
    check.call("離れたページの使用時間を記録する", js.call(session, "slideSpent.get(1)").to_i >= 2000, js.call(session, "slideSpent.get(1)"))
    check.call("別のページは自分の持ち時間で数える", js.call(session, text.(page)).match?(/\A(10:00|09:5\d)\z/), js.call(session, text.(page)))
    js.call(session, "show(1, { fragments: 'all' }); 0")
    sleep 0.3
    check.call("戻ると続きから数える", js.call(session, text.(page)).match?(/\A09:5[0-8]\z/), js.call(session, text.(page)))

    # 始まったあとは表紙へ戻っても止まらない
    js.call(session, "show(0, { fragments: 'all' }); 0")
    sleep 0.3
    check.call("開始後は表紙でも全体の残りが進む", seconds.(js.call(session, text.(total))) < 1200, js.call(session, text.(total)))
    js.call(session, "show(1, { fragments: 'all' }); 0")
    sleep 0.3

    # 保存して再読み込みしてもタイマーは戻らず、持ち時間は枚数に合わせて変わる
    before = js.call(session, "startedAt")
    File.write(deck, File.read(deck, encoding: "UTF-8") + "\n## 追加\n")
    wait_until { js.call(session, "slides.length") == 4 } or warn("  (再読み込みを待てませんでした)")
    sleep 0.3
    check.call("再読み込みしても続く", js.call(session, "startedAt") == before)
    check.call("枚数が増えると持ち時間が変わる", js.call(session, text.(page)).match?(/\A06:[34]\d\z/) && js.call(session, "#{pages}.textContent") == "2 / 4",
               [js.call(session, text.(page)), js.call(session, "#{pages}.textContent")])

    # 発表者ビュー
    js.call(session, "events.send(JSON.stringify({ type: 'open-presenter' })); 0")
    target = nil
    30.times { target = cdp.call("Target.getTargets")["targetInfos"].find { _1["url"] == app.server.presenter_url }; break if target; sleep 0.1 }
    presenter = cdp.call("Target.attachToTarget", { targetId: target["targetId"], flatten: true })["sessionId"]
    wait_until { js.call(presenter, "deck && 1") } or warn("  (発表者ビューの読み込みを待てませんでした)")
    sleep 1.3
    remaining = js.call(presenter, "document.getElementById('remaining').textContent")
    check.call("発表者ビューにも全体の残り", remaining.start_with?("残り 19:5"), remaining)
    slide_text = js.call(presenter, "document.getElementById('slide-remaining').textContent")
    audience_slide = js.call(session, text.(page))
    # 2 つの画面は別の瞬間に読むので、秒の境目をまたぐと 1 秒ずれる
    check.call("発表者ビューにもページの残り", slide_text.start_with?("このページ ") && (seconds.(slide_text) - seconds.(audience_slide)).abs <= 1,
               [slide_text, audience_slide])
    check.call("発表者ビューと同じ開始時刻", js.call(presenter, "startedAt") == before)

    # 途中で r を押すと、その時点から数え直す
    key.call(presenter, "r", "KeyR", 82)
    wait_until(3) { js.call(session, "startedAt").to_i > before }
    sleep 0.3
    check.call("途中の r で全体の残りが戻る", js.call(session, "startedAt").to_i > before && js.call(session, text.(total)) == "20:00", js.call(session, text.(total)))
    check.call("r でページの使用時間も戻る", js.call(session, "slideSpent.size") == 0 && js.call(session, text.(page)) == "06:40", js.call(session, text.(page)))
    check.call("r で発表者ビューも戻る", js.call(presenter, "startedAt") == js.call(session, "startedAt") &&
               js.call(presenter, "document.getElementById('slide-remaining').textContent") == "このページ 06:40",
               js.call(presenter, "document.getElementById('slide-remaining').textContent"))

    # 表紙で r を押すと開始前に戻る
    js.call(session, "show(0, { fragments: 'all' }); 0")
    sleep 0.3
    key.call(presenter, "r", "KeyR", 82)
    sleep 1.5
    check.call("表紙の r で開始前に戻る", js.call(session, "startedAt").nil? && js.call(session, text.(total)) == "20:00", js.call(session, text.(total)))
    check.call("開始前は発表者ビューの経過も 0", js.call(presenter, "document.getElementById('elapsed').textContent") == "00:00" &&
               js.call(presenter, "document.getElementById('slide-remaining').hidden") == true)
    js.call(session, "show(1, { fragments: 'all' }); 0")
    check.call("再び表紙の次へ進むと始まる", wait_until(3) { js.call(session, "startedAt") })
  end

  # 6 秒で 2 枚 → 1 枚 3 秒。ページは超過しても全体はまだ残っている
  File.write(deck, "---\nduration: 0.1\n---\n\n## 1 枚目\n\n## 2 枚目\n")
  run(deck, out, "t2_slide_over") do |_app, _cdp, session, js|
    check.call("ページの残りが少ないと警告色", wait_until(4) { js.call(session, "#{page}.dataset.state") == "warn" })
    check.call("ページの持ち時間を過ぎたら赤", wait_until(3) { js.call(session, "#{page}.dataset.state") == "over" })
    check.call("ページの超過時間を表示", js.call(session, text.(page)).match?(/\A\+00:0\d\z/), js.call(session, text.(page)))
    check.call("全体はまだ超過していない", js.call(session, "#{total}.dataset.state") != "over", js.call(session, text.(total)))
  end

  # 3 秒で 1 枚。全体が超過したら赤
  File.write(deck, "---\nduration: 0.05\n---\n\n## 短いトーク\n")
  run(deck, out, "t3_over") do |_app, _cdp, session, js|
    # 3 秒のトークは全体の 2 割(0.6 秒)を切ったら警告になる
    check.call("全体の残りが少ないと警告色", wait_until(4) { js.call(session, "#{total}.dataset.state") == "warn" })
    wait_until(4) { js.call(session, text.(total)).start_with?("+00:01") }
    check.call("全体の時間を過ぎたら超過表示", js.call(session, text.(total)).match?(/\A\+00:0\d\z/), js.call(session, text.(total)))
    check.call("全体の超過は赤", js.call(session, "#{total}.dataset.state") == "over")
  end

  File.write(deck, "---\npaginate: true\n---\n\n## duration なし\n")
  run(deck, out) do |_app, _cdp, session, js|
    check.call("duration がなければ表示しない", js.call(session, "#{timer}.hidden") == true)
    check.call("duration がなければページ番号はそのまま", js.call(session, "getComputedStyle(document.querySelector('section.active .page-number')).display") != "none")
  end
end end

puts "screenshots: #{out}"
exit(failures.zero? ? 0 : 1)
