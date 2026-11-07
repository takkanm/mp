# frozen_string_literal: true

require "json"
require "monitor"
require "socket"
require "uri"
require "websocket/driver"

module Mp
  # Chrome DevTools Protocol の最小クライアント(flatten セッション前提)。
  class Cdp
    class Error < StandardError; end

    attr_reader :url

    def initialize(ws_url, timeout: 10)
      @url = ws_url
      @timeout = timeout
      uri = URI(ws_url)
      @socket = TCPSocket.new(uri.host, uri.port)
      @write_lock = Monitor.new
      @pending = {}
      @pending_lock = Mutex.new
      @next_id = 0
      @handlers = Hash.new { |h, k| h[k] = [] }
      @events = Queue.new

      @driver = WebSocket::Driver.client(self, max_length: 256 * 1024 * 1024)
      opened = Queue.new
      @driver.on(:open) { opened << true }
      @driver.on(:message) { |e| dispatch(JSON.parse(e.data)) }
      @driver.on(:close) { @events.close }
      @driver.start

      @reader = Thread.new { read_loop }
      # ハンドラ内から call しても reader を塞がないよう、イベントは別スレッドで処理する
      @worker = Thread.new { event_loop }
      opened.pop(timeout: @timeout) or raise Error, "CDP に接続できません: #{ws_url}"
    end

    # websocket-driver が呼ぶ
    def write(data)
      @write_lock.synchronize { @socket.write(data) }
    end

    def on(method, &block)
      @handlers[method] << block
    end

    def on_close(&block)
      @on_close = block
    end

    def call(method, params = {}, session_id: nil)
      reply = Queue.new
      id = @pending_lock.synchronize do
        @next_id += 1
        @pending[@next_id] = reply
        @next_id
      end
      message = { id: id, method: method, params: params }
      message[:sessionId] = session_id if session_id
      @write_lock.synchronize { @driver.text(JSON.generate(message)) }

      response = reply.pop(timeout: @timeout)
      raise Error, "CDP タイムアウト: #{method}" unless response
      raise Error, "#{method}: #{response["error"]["message"]}" if response["error"]

      response["result"]
    ensure
      @pending_lock.synchronize { @pending.delete(id) }
    end

    # 応答を待たない呼び出し。ターゲットが消えた後の失敗は無視してよい場面で使う
    def cast(method, params = {}, session_id: nil)
      message = { id: 0, method: method, params: params }
      message[:sessionId] = session_id if session_id
      @write_lock.synchronize { @driver.text(JSON.generate(message)) }
    rescue IOError, SystemCallError
      nil
    end

    def close
      @socket.close
    rescue IOError, SystemCallError
      nil
    end

    private

    def read_loop
      loop { @driver.parse(@socket.readpartial(65_536)) }
    rescue IOError, SystemCallError
      @events.close
    end

    def dispatch(message)
      if message.key?("id")
        reply = @pending_lock.synchronize { @pending[message["id"]] }
        reply&.push(message)
      else
        @events << message
      end
    rescue ClosedQueueError
      nil
    end

    def event_loop
      while (event = @events.pop)
        @handlers[event["method"]].each do |handler|
          handler.call(event["params"], event["sessionId"])
        rescue Error, IOError, SystemCallError => e
          warn "[mp] CDP: #{e.message}" if ENV["MP_DEBUG"]
        end
      end
      @on_close&.call
    end
  end
end
