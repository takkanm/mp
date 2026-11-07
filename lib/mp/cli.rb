# frozen_string_literal: true

require "optparse"
require_relative "../mp"

module Mp
  module Cli
    def self.run(argv)
      options = { fullscreen: true, watch: true }
      parser = OptionParser.new do |o|
        o.banner = "使い方: mp [オプション] deck.md"
        o.on("-w", "--window", "全画面にせずウィンドウで開く") { options[:fullscreen] = false }
        o.on("-P", "--presenter", "発表者ビューも開く(外部ディスプレイがあれば聴衆画面をそちらへ移す)") { options[:presenter] = true }
        o.on("-p", "--port PORT", Integer, "ローカルサーバのポート(既定: 空きポート)") { options[:port] = _1 }
        o.on("--profile DIR", "Chrome のプロファイルを保存する(埋め込みページのログインを保持)") { options[:profile] = _1 }
        o.on("--no-watch", "ファイル変更時に再読み込みしない") { options[:watch] = false }
        o.on("-v", "--version") { puts VERSION; return 0 }
      end
      path = parser.parse(argv).first
      unless path && File.file?(path)
        warn(path ? "ファイルが見つかりません: #{path}" : parser.help)
        return 1
      end

      app = App.new(path, **options)
      %w[INT TERM].each { |signal| trap(signal) { app.request_stop } }
      app.start
      app.wait
      app.stop
      0
    rescue Browser::NotFound, OptionParser::ParseError, Cdp::Error => e
      warn e.message
      1
    end
  end
end
