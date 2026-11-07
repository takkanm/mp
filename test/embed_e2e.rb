# frozen_string_literal: true

# Worker と wasm を使うページの埋め込みを確認する: bundle exec ruby test/embed_e2e.rb
require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/mp"

fixture = File.expand_path("fixtures/wasm/app", __dir__)
failures = 0
check = lambda do |name, ok, detail = nil|
  failures += 1 unless ok
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{" (#{detail})" if detail && !ok}"
end

Dir.mktmpdir("mp-embed-") do |dir|
  FileUtils.cp_r(fixture, File.join(dir, "app"))
  File.write(File.join(dir, ".secret"), "secret")
  deck = File.join(dir, "deck.md")
  File.write(deck, "# T\n\n## 埋め込み\n\n```web\n./app/\n```\n\n## 台本\n\n```terminal\n```\n")
  app = Mp::App.new(deck, headless: true, watch: false).start
  cdp = app.browser.cdp
  session = app.page_session
  js = lambda do |expression|
    cdp.call("Runtime.evaluate", { expression: expression, returnByValue: true, awaitPromise: true }, session_id: session).dig("result", "value")
  end

  begin
    sleep 0.5 until js.call("document.querySelector('section.slide.active')")
    # ローカルページへアプリの URL を渡して、届かないことも確認させる
    js.call("deck.embeds.e1.src += '?app=' + encodeURIComponent(location.origin + location.pathname); show(1, { fragments: 'all' }); 0")

    result = nil
    deadline = Time.now + 10
    until result || Time.now > deadline
      sleep 0.2
      target = cdp.call("Target.getTargets")["targetInfos"].find { _1["type"] == "iframe" && _1["url"].include?("/app/") }
      next unless target

      frame = cdp.call("Target.attachToTarget", { targetId: target["targetId"], flatten: true })["sessionId"]
      text = cdp.call("Runtime.evaluate", { expression: "document.getElementById('result')?.textContent", returnByValue: true }, session_id: frame).dig("result", "value")
      result = JSON.parse(text) if text&.start_with?("{")
    end

    check.call("ページが最後まで動く", !result.nil?)
    result ||= {}
    check.call("専用の origin を持つ", result["origin"] == app.server.content_origin, result["origin"])
    check.call("wasm が動く", result["main"] == 5, result["main"])
    check.call("Worker 内の wasm が動く", result["worker"] == 42, result["worker"])
    check.call("localStorage が使える", result["storage"] == "1", result["storage"])
    check.call("デッキの情報を読めない", result["deck"] == "blocked", result["deck"])
    check.call("ターミナルに接続できない", result["pty"] == "blocked", result["pty"])

    port = app.server.port
    token = app.server.token
    get = ->(host, path) { Net::HTTP.start(host, port) { |http| http.get("/#{token}/#{path}", { "Host" => "#{host}:#{port}" }) } }
    check.call("別 origin ではアプリを配信しない", get.call("localhost", "_mp/deck.json").code == "404")
    check.call("別 origin でも隠しファイルを読めない", get.call("localhost", ".secret").code == "404")
    check.call("別 origin でも親ディレクトリを読めない", get.call("localhost", "..%2f..%2fetc%2fhosts").code == "404")
    check.call("別 origin でもトークンが必要", Net::HTTP.start("localhost", port) { _1.get("/wrong/app/index.html") }.code == "404")
    check.call("wasm の Content-Type", get.call("localhost", "app/add.wasm")["content-type"] == "application/wasm")
    check.call("アプリの origin の HTML は sandbox のまま", get.call("127.0.0.1", "app/index.html")["content-security-policy"].to_s.start_with?("sandbox"))
  ensure
    app.stop
  end
end

exit(failures.zero? ? 0 : 1)
