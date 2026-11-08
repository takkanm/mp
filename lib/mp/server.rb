# frozen_string_literal: true

require "json"
require "puma"
require "puma/server"
require "rack"
require "rouge"
require "securerandom"
require "websocket/driver"
require_relative "deck"
require_relative "terminal"
require_relative "web_socket"

module Mp
  # デッキと埋め込みターミナルを配信するローカルサーバ。
  #
  # ターミナルは任意コマンドを実行できるので、127.0.0.1 のみで待ち受け、全パスに
  # ランダムトークンを要求し、WebSocket は Origin も検証する。
  class Server
    HOST = "127.0.0.1"
    CONTENT_HOST = "localhost"
    PUBLIC_DIR = File.expand_path("../../public", __dir__)
    VENDOR_DIR = File.expand_path("../../vendor/assets", __dir__)
    THEME_DIR = File.expand_path("../../themes", __dir__)
    SANDBOXED_TYPES = %w[text/html image/svg+xml application/xhtml+xml].freeze

    attr_reader :token, :port, :deck
    attr_accessor :on_open_presenter, :on_frame_request

    def initialize(path, port: 0, on_quit: nil)
      @path = File.expand_path(path)
      @requested_port = port
      @on_quit = on_quit
      @token = SecureRandom.hex(16)
      @clients = {} # socket => :audience / :presenter
      @terminals = []
      @lock = Mutex.new
      reload
    end

    def start
      log_writer = ENV["MP_DEBUG"] ? Puma::LogWriter.stdio : Puma::LogWriter.null
      @puma = Puma::Server.new(self, nil, min_threads: 0, max_threads: 16, log_writer: log_writer)
      @port = @puma.add_tcp_listener(HOST, @requested_port).addr[1]
      @puma.run
      self
    end

    def stop
      @lock.synchronize { @terminals.dup }.each(&:close)
      @puma&.stop(true)
    end

    def origin = "http://#{HOST}:#{@port}"

    # 埋め込むローカルページの配信元。アプリと別 origin にして、ページの JS が
    # ターミナルの WebSocket やデッキの API へ触れないようにする
    def content_origin = "http://#{CONTENT_HOST}:#{@port}"
    def boot_url = "#{origin}/#{@token}/_mp/boot"
    def app_url = "#{origin}/#{@token}/"
    def presenter_url = "#{origin}/#{@token}/presenter"

    def presenter_connected?
      @lock.synchronize { @clients.value?(:presenter) }
    end

    def send_frame(data)
      broadcast(JSON.generate(type: "frame", data: data), role: :presenter)
    end

    # デッキを読み直して表示中のページへ通知する。失敗したら前の内容のまま続ける
    def reload
      @deck = Deck.load(@path)
      broadcast(JSON.generate(type: "reload"))
    rescue Psych::Exception, SystemCallError => e
      raise unless @deck

      warn "[mp] 読み込みに失敗しました: #{e.message}"
    end

    def call(env)
      path = env["PATH_INFO"]
      prefix = "/#{@token}/"
      return not_found unless path.start_with?(prefix)

      relative = path.delete_prefix(prefix)
      return embedded_page(relative) if env["HTTP_HOST"] == "#{CONTENT_HOST}:#{@port}"

      route(relative, env)
    end

    private

    def route(path, env)
      case path
      when "" then file(File.join(PUBLIC_DIR, "index.html"), app_headers)
      when "presenter" then file(File.join(PUBLIC_DIR, "presenter.html"), app_headers)
      when "_mp/boot" then [200, { "content-type" => "text/plain" }, [""]]
      when "_mp/deck.json" then [200, { "content-type" => "application/json" }, [JSON.generate(deck_json)]]
      when "_mp/events" then websocket(env) { |socket| serve_events(socket, env) }
      when "_mp/pty" then websocket(env) { |socket| serve_terminal(socket, env) }
      when %r{\A_mp/vendor/(.+)\z} then static(VENDOR_DIR, Regexp.last_match(1))
      when %r{\A_mp/(.+)\z} then static(PUBLIC_DIR, Regexp.last_match(1))
      else deck_file(path)
      end
    end

    def app_headers
      {
        "content-security-policy" => [
          "default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline' https:",
          "img-src * data: blob:", "media-src *", "font-src 'self' data: https:", "frame-src *",
          "connect-src 'self' ws://#{HOST}:#{@port}", "object-src 'none'", "base-uri 'none'"
        ].join("; ")
      }
    end

    def deck_json
      deck = @deck.to_h
      embeds = deck[:embeds].transform_values { |embed| embed[:type] == "web" ? embed.merge(src: embed_url(embed[:src])) : embed }
      @started_at ||= Time.now # 最初にスライドを表示した時刻からタイマーを始める
      deck.merge(embeds: embeds, themeCss: theme_css, startedAt: timer_start)
    end

    def timer_start = (@started_at.to_f * 1000).round

    def embed_url(src)
      return src if src.empty? || src.match?(%r{\Ahttps?://}i)

      "#{content_origin}/#{@token}/#{src.sub(%r{\A(\./|/)+}, "")}"
    end

    def theme_css
      theme = @deck.globals["theme"].to_s
      theme = "default" if theme.empty?
      custom = File.expand_path(theme, @deck.base_dir)
      css = if theme.end_with?(".css") && inside?(@deck.base_dir, custom) && File.file?(custom)
              File.read(custom)
            else
              builtin = File.join(THEME_DIR, "#{File.basename(theme, ".css")}.css")
              File.read(File.file?(builtin) ? builtin : File.join(THEME_DIR, "default.css"))
            end
      mode = css.include?("mp-dark") ? :dark : :light
      "#{Rouge::Themes::Github.mode(mode).render(scope: ".highlight")}\n#{css}"
    end

    def inside?(dir, path)
      path.start_with?("#{File.expand_path(dir)}/")
    end

    def static(dir, relative)
      full = File.expand_path(relative, dir)
      inside?(dir, full) ? file(full) : not_found
    end

    # デッキのあるディレクトリのファイル(画像など)
    def deck_file(relative)
      full = resolve_deck_path(relative)
      full ? file(full, sandbox_headers(full)) : not_found
    end

    # 別 origin で配信するので sandbox は不要。wasm や ES モジュールを普通に読み込める
    def embedded_page(relative)
      full = resolve_deck_path(relative.empty? || relative.end_with?("/") ? "#{relative}index.html" : relative)
      full ? file(full) : not_found
    end

    def resolve_deck_path(relative)
      relative = Rack::Utils.unescape_path(relative)
      return if relative.split("/").any? { _1.start_with?(".") }

      base = File.realpath(@deck.base_dir)
      full = File.expand_path(relative, base)
      full if File.file?(full) && inside?(base, File.realpath(full))
    end

    # アプリの origin で HTML が動くと PTY の WebSocket へ届くので、origin を持たせない
    def sandbox_headers(path)
      return {} unless SANDBOXED_TYPES.include?(mime(path))

      { "content-security-policy" => "sandbox allow-scripts allow-forms allow-popups" }
    end

    def mime(path) = Rack::Mime.mime_type(File.extname(path), "application/octet-stream")

    def file(path, headers = {})
      return not_found unless File.file?(path)

      [200, { "content-type" => mime(path), "x-content-type-options" => "nosniff", "cache-control" => "no-store" }
        .merge(headers), [File.binread(path)]]
    end

    def not_found = [404, { "content-type" => "text/plain" }, ["not found"]]

    def websocket(env)
      return [403, {}, ["forbidden"]] unless env["HTTP_ORIGIN"] == origin
      return [400, {}, ["websocket only"]] unless WebSocket::Driver.websocket?(env)

      socket = WebSocketConnection.new(env)
      yield socket
      socket.run
      [-1, {}, []] # hijack 済み
    end

    def serve_events(socket, env)
      presenter = Rack::Utils.parse_query(env["QUERY_STRING"])["role"] == "presenter"
      @lock.synchronize { @clients[socket] = presenter ? :presenter : :audience }
      socket.on_message { |message| handle_event(socket, message) }
      socket.on_close { @lock.synchronize { @clients.delete(socket) } }
    end

    # スライドの状態は聴衆画面だけが持つ。発表者のコマンドと聴衆の状態はここで中継する
    def handle_event(socket, message)
      case JSON.parse(message)["type"]
      when "quit" then @on_quit&.call
      when "open-presenter" then @on_open_presenter&.call
      when "timer-reset"
        @started_at = Time.now
        broadcast(JSON.generate(type: "timer", startedAt: timer_start))
      when "frame" then @on_frame_request&.call
      else broadcast(message, except: socket)
      end
    rescue JSON::ParserError
      nil
    end

    def broadcast(message, role: nil, except: nil)
      targets = @lock.synchronize { @clients.select { |socket, r| socket != except && (role.nil? || r == role) }.keys }
      targets.each { _1.send_text(message) }
    end

    def serve_terminal(socket, env)
      params = Rack::Utils.parse_query(env["QUERY_STRING"])
      embed = @deck.embeds[params["id"]]
      return socket.close unless embed && embed[:type] == "terminal"

      terminal = Terminal.new(cwd: embed[:cwd], cols: params["cols"].to_i, rows: params["rows"].to_i)
      @lock.synchronize { @terminals << terminal }
      reader = Thread.new do
        terminal.read_loop { |data| socket.send_binary(data) }
        socket.close
      end
      socket.on_message do |message|
        data = JSON.parse(message)
        data["resize"] ? terminal.resize(*data["resize"].map(&:to_i)) : terminal.write(data["input"].to_s)
      end
      socket.on_close do
        @lock.synchronize { @terminals.delete(terminal) }
        terminal.close
        reader.kill
      end
    end
  end
end
