# frozen_string_literal: true

require "json"
require "listen"
require_relative "browser"
require_relative "frame_unblocker"
require_relative "server"

module Mp
  # サーバとブラウザを起動し、ウィンドウが閉じるまで待つ。
  class App
    attr_reader :server, :browser, :page_session

    MIRROR_WIDTH = 1280

    def initialize(path, fullscreen: true, port: 0, profile: nil, watch: true, headless: false, size: [1280, 720],
                   presenter: false)
      @path = path
      @fullscreen = fullscreen
      @port = port
      @profile = profile
      @watch = watch
      @headless = headless
      @size = size
      @presenter = presenter
      @done = Queue.new
    end

    def start
      @server = Server.new(@path, port: @port, on_quit: -> { @done << :quit }).start
      @server.on_open_presenter = -> { open_presenter }
      @server.on_frame_request = -> { send_frame }
      @browser = Browser.new(@server.boot_url, fullscreen: @fullscreen, profile: @profile,
                                               headless: @headless, size: @size).launch
      @page_session = @browser.attach_page
      cdp = @browser.cdp
      @target_id = cdp.call("Target.getTargetInfo", {}, session_id: @page_session)["targetInfo"]["targetId"]
      cdp.on("Target.targetDestroyed") { |params, _| @done << :closed if params["targetId"] == @target_id }
      cdp.on_close { @done << :closed }
      cdp.call("Target.setDiscoverTargets", { discover: true })

      # 埋め込み用の設定が終わってから本番ページへ遷移する
      FrameUnblocker.new(cdp).attach(@page_session)
      cdp.call("Page.navigate", { url: @server.app_url }, session_id: @page_session)
      start_watcher if @watch
      open_presenter if @presenter
      self
    rescue StandardError
      stop # 起動途中で失敗しても Chrome を残さない
      raise
    end

    def wait
      @done.pop
    end

    # シグナルハンドラからも呼べるよう、Queue への追加だけにしている
    def request_stop
      @done << :signal
    end

    def stop
      @listener&.stop
      @browser&.close
      @server&.stop
    end

    private

    def open_presenter
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @server.presenter_connected? || (@opened_at && now - @opened_at < 5) # キーの連打対策

      @opened_at = now
      @browser.open_window(@server.presenter_url)
      Thread.new { arrange_displays } unless @headless
    end

    # 聴衆画面の見た目を発表者ビューへ送る。screencast と違い、ウィンドウが
    # 他のウィンドウの裏にあっても最新の画面を取れる
    def send_frame
      cdp = @browser.cdp
      view = cdp.call("Page.getLayoutMetrics", {}, session_id: @page_session)["cssLayoutViewport"]
      clip = { x: 0, y: 0, width: view["clientWidth"], height: view["clientHeight"],
               scale: [MIRROR_WIDTH.to_f / view["clientWidth"], 1].min }
      frame = cdp.call("Page.captureScreenshot", { format: "jpeg", quality: 75, clip: clip, optimizeForSpeed: true },
                       session_id: @page_session)
      @server.send_frame(frame["data"])
    rescue Cdp::Error => e
      warn "[mp] #{e.message}" if ENV["MP_DEBUG"]
    end

    # 外部ディスプレイがあれば聴衆画面をそちらの全画面に、発表者ビューを手元に置く
    def arrange_displays
      screens = detect_screens
      external = screens.find { !_1["isPrimary"] }
      return warn("[mp] 外部ディスプレイが見つかりません。発表者ビューが全画面の裏に隠れたら、スペースを切り替えてください") unless external

      primary = screens.find { _1["isPrimary"] } || screens.first
      cdp = @browser.cdp
      presenter = wait_for_presenter_target
      audience = cdp.call("Browser.getWindowForTarget", { targetId: @target_id })
      unless inside_screen?(audience["bounds"], external)
        set_bounds(audience["windowId"], windowState: "normal")
        sleep 1 # macOS の全画面解除アニメーションの間は移動できない
        set_bounds(audience["windowId"], **screen_bounds(external))
        sleep 0.3
        set_bounds(audience["windowId"], windowState: "fullscreen") if @fullscreen
      end
      return unless presenter

      window = cdp.call("Browser.getWindowForTarget", { targetId: presenter["targetId"] })["windowId"]
      set_bounds(window, **screen_bounds(primary))
    rescue Cdp::Error => e
      warn "[mp] ウィンドウを配置できませんでした: #{e.message}"
    end

    def detect_screens
      cdp = @browser.cdp
      cdp.call("Browser.grantPermissions", { permissions: ["windowManagement"], origin: @server.origin })
      expression = <<~JS
        getScreenDetails().then((details) => JSON.stringify(details.screens.map((s) => ({
          left: s.availLeft, top: s.availTop, width: s.availWidth, height: s.availHeight, isPrimary: s.isPrimary,
        }))))
      JS
      reply = cdp.call("Runtime.evaluate", { expression: expression, awaitPromise: true, returnByValue: true, userGesture: true },
                       session_id: @page_session)
      JSON.parse(reply.dig("result", "value") || "[]")
    end

    def wait_for_presenter_target
      50.times do
        target = @browser.cdp.call("Target.getTargets")["targetInfos"].find { _1["url"] == @server.presenter_url }
        return target if target

        sleep 0.1
      end
      nil
    end

    def inside_screen?(bounds, screen)
      bounds["left"].between?(screen["left"], screen["left"] + screen["width"] - 1) &&
        bounds["top"].between?(screen["top"], screen["top"] + screen["height"] - 1)
    end

    def screen_bounds(screen) = screen.slice("left", "top", "width", "height").transform_keys(&:to_sym)

    def set_bounds(window_id, **bounds)
      @browser.cdp.call("Browser.setWindowBounds", { windowId: window_id, bounds: bounds })
    end

    def start_watcher
      dir = File.dirname(File.expand_path(@path))
      @listener = Listen.to(dir, only: /\.(md|markdown|css)\z/) { @server.reload }
      @listener.start
    end
  end
end
