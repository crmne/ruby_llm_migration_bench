# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/migration_bench"

class ClusterTest < Minitest::Test
  def setup
    @cluster = MigrationBench::Cluster.new(output: "/unused")
  end

  def test_refuses_non_benchmark_names_before_connecting
    ["postgres", "production", "rllm_bench_x;DROP DATABASE postgres", "rllm_bench_" + "x" * 60].each do |name|
      assert_raises(RuntimeError) { @cluster.create_database(name) }
      assert_raises(RuntimeError) { @cluster.drop_database(name) }
    end
  end

  def test_refuses_external_templates_before_connecting
    assert_raises(RuntimeError) { @cluster.create_database("rllm_bench_trial", template: "production") }
  end

  def test_refuses_injected_configuration
    assert_raises(RuntimeError) do
      MigrationBench::Cluster.new(output: "/unused", shared_buffers: "1GB'\nlisten_addresses='*'")
    end
  end

  def test_checks_the_loaded_gem_revision
    assert_equal MigrationBench::GEM_COMMIT, MigrationBench.gem_commit
  end
end
