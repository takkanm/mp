# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require_relative "cdp"

module Mp
  # Chrome をアプリモードで起動し、CDP で接続する。
  class Browser
    class NotFound < StandardError; end

    CANDIDATES = [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    ].freeze
    COMMANDS = %w[google-chrome google-chrome-stable chromium chromium-browser microsoft-edge].freeze

    attr_reader :cdp, :pid

    def self.find_executable
      return ENV["MP_BROWSER"] if ENV["MP_BROWSER"]

      found = CANDIDATES.find { |path| File.executable?(path) }
      found ||= COMMANDS.filter_map { |cmd|
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, cmd) }
           .find { |path| File.executable?(path) }
      }.first
      found or raise NotFound, "Chrome 系ブラウザが見つかりません。MP_BROWSER でパスを指定してください"
    end

    def initialize(url, fullscreen: true, profile: nil, headless: false, size: [1280, 720])
      @url = url
      @fullscreen = fullscreen
      @headless = headless
      @size = size
      @temp_profile = profile.nil?
      @profile = profile || Dir.mktmpdir("mp-chrome-")
      FileUtils.mkdir_p(@profile)
    end

    def launch
      args = [
        "--user-data-dir=#{@profile}",
        "--remote-debugging-port=0",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate",
        "--window-size=#{@size.join(",")}"
      ]
      args << "--start-fullscreen" if @fullscreen && !@headless
      args << "--headless=new" if @headless
      args << (@headless ? @url : "--app=#{@url}") # ヘッドレスは --app を無視する

      @pid = Process.spawn(self.class.find_executable, *args, out: File::NULL, err: File::NULL)
      @cdp = Cdp.new(wait_for_debugger_url)
      self
    end

    # 表示用ページに接続して session id を返す。起動直後はターゲットが無いことがあるので待つ
    def attach_page
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      loop do
        target = @cdp.call("Target.getTargets")["targetInfos"].find do |info|
          %w[page app].include?(info["type"]) && info["url"].start_with?(@url)
        end
        return @cdp.call("Target.attachToTarget", { targetId: target["targetId"], flatten: true })["sessionId"] if target
        raise Cdp::Error, "ページを取得できません" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end

    # 同じプロファイルで --app を起動すると、動いている Chrome にアプリウィンドウが増える
    def open_window(url)
      return @cdp.call("Target.createTarget", { url: url }) if @headless

      Process.detach(Process.spawn(self.class.find_executable, "--user-data-dir=#{@profile}", "--app=#{url}",
                                   out: File::NULL, err: File::NULL))
    end

    def wait
      Process.wait(@pid)
      @pid = nil
    rescue Errno::ECHILD
      @pid = nil
    end

    def close
      @cdp&.close
      if @pid
        Process.kill("TERM", @pid)
        Process.wait(@pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @pid = nil
      FileUtils.rm_rf(@profile) if @temp_profile
    end

    private

    def wait_for_debugger_url
      port_file = File.join(@profile, "DevToolsActivePort")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until File.size?(port_file)
        raise Cdp::Error, "ブラウザの起動を確認できません" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
      port, path = File.read(port_file).lines.map(&:strip)
      "ws://127.0.0.1:#{port}#{path}"
    end
  end
end
