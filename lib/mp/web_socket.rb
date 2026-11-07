# frozen_string_literal: true

require "monitor"
require "websocket/driver"

module Mp
  # Rack hijack したソケットを WebSocket として扱う。
  class WebSocketConnection
    attr_reader :env

    def initialize(env)
      @env = env
      @lock = Monitor.new
      @socket = env["rack.hijack"].call
      @driver = WebSocket::Driver.rack(self, max_length: 16 * 1024 * 1024)
    end

    def on_message(&block) = @driver.on(:message) { |event| block.call(event.data) }
    def on_close(&block) = (@on_close = block)

    def run
      @driver.start
      Thread.new do
        loop { @driver.parse(@socket.readpartial(16_384)) }
      rescue IOError, SystemCallError
        nil
      ensure
        @socket.close unless @socket.closed?
        @on_close&.call
      end
    end

    # websocket-driver が呼ぶ
    def write(data)
      @lock.synchronize { @socket.write(data) }
    rescue IOError, SystemCallError
      nil
    end

    def send_text(text) = @lock.synchronize { @driver.text(text) }
    def send_binary(data) = @lock.synchronize { @driver.binary(data.bytes) }

    def close
      @socket.close unless @socket.closed?
    rescue IOError
      nil
    end
  end
end
