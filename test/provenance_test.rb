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
end
