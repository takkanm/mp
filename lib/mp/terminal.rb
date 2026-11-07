# frozen_string_literal: true

require "io/console"
require "pty"

module Mp
  # 1 つの埋め込みに対応するシェル。
  class Terminal
    def initialize(cwd:, cols:, rows:)
      env = { "TERM" => "xterm-256color", "COLORTERM" => "truecolor" }
      @output, @input, @pid = PTY.spawn(env, ENV.fetch("SHELL", "/bin/sh"), "-l", chdir: cwd)
      resize(cols, rows)
    end

    def read_loop
      loop { yield @output.readpartial(16_384) }
    rescue EOFError, Errno::EIO, IOError
      nil # シェル終了時、Linux では EIO になる
    end

    def write(data)
      @input.write(data)
    rescue IOError, Errno::EIO
      nil
    end

    def resize(cols, rows)
      @output.winsize = [rows.clamp(2, 500), cols.clamp(2, 500)]
    rescue IOError, Errno::EIO
      nil
    end

    def close
      Process.kill("HUP", @pid)
      Process.detach(@pid)
      [@input, @output].each(&:close)
    rescue Errno::ESRCH, IOError
      nil
    end
  end
end
