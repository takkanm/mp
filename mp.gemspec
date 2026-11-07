# frozen_string_literal: true

require_relative "lib/mp/version"

Gem::Specification.new do |spec|
  spec.name = "mp"
  spec.version = Mp::VERSION
  spec.summary = "Markdown を全画面プレゼンテーションにするツール(ターミナル / Web 埋め込み対応)"
  spec.authors = ["takkanm"]
  spec.homepage = "https://github.com/takkanm/mp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.files = Dir["lib/**/*", "exe/*", "themes/*", "public/**/*", "vendor/assets/**/*", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["mp"]

  spec.add_dependency "kramdown", "~> 2.5"
  spec.add_dependency "kramdown-parser-gfm", "~> 1.1"
  spec.add_dependency "listen", "~> 3.9"
  spec.add_dependency "puma", ">= 6"
  spec.add_dependency "rack", ">= 3"
  spec.add_dependency "rouge", ">= 4"
  spec.add_dependency "websocket-driver", "~> 0.8"
end
