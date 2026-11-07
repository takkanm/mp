# frozen_string_literal: true

require_relative "mp/version"
require_relative "mp/deck"
require_relative "mp/browser"
require_relative "mp/frame_unblocker"
require_relative "mp/server"
require_relative "mp/app"

module Mp
  ROOT = File.expand_path("..", __dir__)
end
