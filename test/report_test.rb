# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/migration_bench/report"

class ReportTest < Minitest::Test
  FIXTURES = File.expand_path("../results/2026-09-11", __dir__)

  def test_original_measurements
    report = MigrationBench::Report.new(Dir[File.join(FIXTURES, "ten-*.json")])
    assert report.validate!
    assert_includes report.markdown, "| Rename | 20.09 s (19.82–20.15) | 20.09 s (19.82–20.15) |"
    assert_includes report.markdown, "| Online copy | 136.43 s (135.11–137.23) | 3.74 s (3.73–3.79) |"
  end

  def test_refuses_missing_trials
    assert_raises(RuntimeError) { MigrationBench::Report.new([]).validate! }
  end

  def test_refuses_failed_trials
    modified_report { |rows| rows.first["passed"] = false }
  end

  def test_refuses_mismatched_experiments
    modified_report { |rows| rows.first["gem_commit"] = "different" }
  end

  def test_refuses_wrong_downtime_boundary
    modified_report { |rows| rows.first["downtime_seconds"] += 1 }
  end

  def test_refuses_duplicate_trials
    modified_report { |rows| rows[1]["repeat"] = rows[0]["repeat"] }
  end

  private

  def modified_report
    rows = Dir[File.join(FIXTURES, "ten-*.json")].sort.map { |path| JSON.parse(File.read(path)) }
    yield rows
    Dir.mktmpdir("benchmark-report-test-") do |directory|
      paths = rows.each_with_index.map do |row, index|
        path = File.join(directory, "#{index}.json")
        File.write(path, JSON.generate(row))
        path
      end
      assert_raises(RuntimeError) { MigrationBench::Report.new(paths).validate! }
    end
  end
end
