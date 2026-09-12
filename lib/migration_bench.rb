# frozen_string_literal: true

require "bundler/setup"
require "rails"
require "active_record"
require "pg"
require "json"
require "digest"
require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"
require "time"
require "ruby_llm"
require "generators/ruby_llm/upgrade/upgrade_generator"

module MigrationBench
  ROOT = File.expand_path("..", __dir__)
  GEM_COMMIT = "e5827a01a4226a1b4bbf28a4f42c0ff252918443"
  BATCH_SIZE = 10_000

  def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def self.log(event, **values)
    puts JSON.generate(event:, **values)
    $stdout.flush
  end

  def self.gem_commit
    source = Bundler.load.specs.find { |spec| spec.name == "ruby_llm" }.source
    revision = source.revision if source.respond_to?(:revision)
    raise "The loaded RubyLLM source does not match the benchmark pin" unless revision == GEM_COMMIT

    revision
  end

  class Application < Rails::Application
    config.eager_load = false
    config.root = ROOT
  end
end

ActiveRecord::Migration.verbose = false

require_relative "migration_bench/cluster"
require_relative "migration_bench/seed"
require_relative "migration_bench/trial"
require_relative "migration_bench/report"
