# frozen_string_literal: true

module MigrationBench
  class Report
    MODES = {"rename" => "Rename", "copy" => "Online copy"}.freeze

    def initialize(paths)
      @rows = paths.sort.map { |path| JSON.parse(File.read(path)) }
    end

    def validate!(repeats: 3)
      raise "Expected #{repeats} trials per mode" unless @rows.size == repeats * MODES.size

      MODES.each_key do |mode|
        rows = @rows.select { |row| row.fetch("mode") == mode }
        raise "Missing or duplicate #{mode} trials" unless rows.map { |r| r.fetch("repeat") }.sort == (1..repeats).to_a
      end
      @rows.each do |row|
        raise "Failed trial cannot be summarized" unless row.fetch("passed") == true
        %w[total_seconds downtime_seconds].each do |key|
          value = row.fetch(key)
          raise "Invalid duration" unless value.is_a?(Numeric) && value.finite? && value >= 0
        end
        expected = (row.fetch("mode") == "rename") ? row.fetch("total_seconds") : row.fetch("phases").fetch("finish")
        raise "Incorrect downtime boundary" unless (row.fetch("downtime_seconds") - expected).abs < 0.000001
      end
      signatures = @rows.map { |r| [r.fetch("gem_commit"), r.fetch("seed").values_at("chats", "messages", "profile", "payload_bytes"), r.fetch("settings")] }
      raise "Cannot combine different experiments" unless signatures.uniq.one?
      true
    end

    def markdown
      lines = ["| Mode | Total migration time | Required AI downtime |", "| --- | ---: | ---: |"]
      MODES.each do |mode, label|
        rows = @rows.select { |row| row.fetch("mode") == mode }
        lines << "| #{label} | #{format_duration(rows, "total_seconds")} | #{format_duration(rows, "downtime_seconds")} |"
      end
      lines.join("\n") + "\n"
    end

    private

    def format_duration(rows, key)
      values = rows.map { |row| row.fetch(key) }.sort
      middle = values.size / 2
      median = values.size.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
      format("%.2f s (%.2f–%.2f)", median, values.first, values.last)
    end
  end
end
