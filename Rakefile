# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) { _1.pattern = "test/*_test.rb" }

# テストが通らない gem を作らない(release も build を経由する)
task build: :test
task default: :test
