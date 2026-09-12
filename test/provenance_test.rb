# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "digest"

class ProvenanceTest < Minitest::Test
  ROOT = File.expand_path("../results/2026-09-11", __dir__)

  def test_archived_migrations_match_recorded_source_hashes
    Dir[File.join(ROOT, "ten-*.json")].each do |path|
      row = JSON.parse(File.read(path))
      row.fetch("migration_hashes").each do |phase, expected|
        files = Dir[File.join(ROOT, "migrations", row.fetch("mode"), "*#{phase}*.rb")]
        assert_equal 1, files.size
        assert_equal expected, Digest::SHA256.file(files.first).hexdigest
      end
    end
  end

  def test_standalone_run_reproduces_original_data_and_migrations
    paths = Dir[File.join(ROOT, "../2026-09-12/ten-*.json")]
    assert_equal 6, paths.size
    paths.each do |path|
      row = JSON.parse(File.read(path))
      baseline = JSON.parse(File.read(File.join(ROOT, "ten-#{row.fetch("mode")}-1.json")))
      assert_equal true, row.fetch("passed")
      assert_equal baseline.fetch("fingerprints"), row.fetch("fingerprints")
      assert_equal baseline.fetch("migration_hashes"), row.fetch("migration_hashes")
      assert_equal baseline.fetch("gem_commit"), row.fetch("gem_commit")
      assert_equal 10_000, row.fetch("batch_size")
      assert_equal false, row.fetch("concurrent_writers")
    end
  end
end
