# frozen_string_literal: true

module MigrationBench
  class Trial
    USAGE_FIELDS = %w[chat_type chat_id message_type message_id operation provider model status
      input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens
      input_cost output_cost cache_read_cost cache_write_cost thinking_cost total_cost
      created_at updated_at].freeze

    def initialize(cluster:, output:, seed:, mode:, repeat:)
      raise "Unknown mode" unless %w[rename copy].include?(mode)

      @cluster, @root, @seed = cluster, output, seed
      @profile, @mode, @repeat = "ten", mode, Integer(repeat)
      @database = "rllm_bench_#{mode}_#{repeat}_#{SecureRandom.hex(3)}"
      @output = File.join(output, "ten-#{mode}-#{repeat}.json")
      raise "Result already exists: #{@output}" if File.exist?(@output)

      @result = {profile: @profile, mode:, repeat: @repeat, database: @database, phases: {}, passed: false}
    end

    def run
      @cluster.create_database(@database, template: @seed)
      ActiveRecord::Base.establish_connection(@cluster.connection_options(@database))
      @connection = ActiveRecord::Base.connection
      @connection.execute("SET lock_timeout = '10s'")
      @connection.execute("SET statement_timeout = '30min'")
      ActiveRecord::Migration.verbose = false
      metadata
      migrations = generate
      @legacy_columns = %w[chats messages models tool_calls].to_h { |table| [table, @connection.columns(table).map(&:name)] }
      expected = phase(:source_audit) { expected_fingerprints }
      legacy = phase(:legacy_audit) { legacy_fingerprints } if @mode == "copy"
      @connection.execute("CHECKPOINT")
      started = clock
      %i[prepare backfill finish].each { |name| phase(name) { migrations.fetch(name).migrate(:up) } }
      @result[:total_seconds] = clock - started
      @result[:downtime_seconds] = (@mode == "rename") ? @result[:total_seconds] : @result[:phases].fetch(:finish)
      phase(:target_audit) do
        actual = target_fingerprints
        raise "Derived data differs: #{expected.inspect} != #{actual.inspect}" unless expected == actual
        raise "Legacy rows changed" if legacy && legacy != legacy_fingerprints
        verify_counts
        @result[:fingerprints] = actual
      end
      @result[:database_bytes_after] = @connection.select_value("SELECT pg_database_size(current_database())")
      @result[:passed] = true
      log(:complete, total_seconds: @result[:total_seconds], downtime_seconds: @result[:downtime_seconds])
    rescue StandardError, Interrupt => error
      @result[:error] = error.full_message
      raise
    ensure
      File.open(@output, "wx") { |file| file.write(JSON.pretty_generate(@result)) }
      if @result[:passed]
        ActiveRecord::Base.connection_pool.disconnect!
        @cluster.drop_database(@database)
      end
    end

    private

    def metadata
      @result[:seed] = JSON.parse(@connection.select_value("SELECT data::text FROM bench_metadata"))
      @result[:ruby] = RUBY_DESCRIPTION
      @result[:active_record] = ActiveRecord::VERSION::STRING
      @result[:postgresql] = @connection.select_value("SELECT version()")
      @result[:database_bytes_before] = @connection.select_value("SELECT pg_database_size(current_database())")
      @result[:settings] = %w[fsync synchronous_commit full_page_writes autovacuum shared_buffers work_mem maintenance_work_mem]
        .to_h { |name| [name, @connection.select_value("SHOW #{name}")] }
      @result[:gem_commit] = MigrationBench.gem_commit
      @result[:machine] = machine_metadata
      @result[:harness_hashes] = Dir[File.join(MigrationBench::ROOT, "{lib,bin}", "**", "*")].select { |path| File.file?(path) }.sort.to_h do |path|
        [path.delete_prefix("#{MigrationBench::ROOT}/"), Digest::SHA256.file(path).hexdigest]
      end
      @result[:batch_size] = MigrationBench::BATCH_SIZE
      @result[:concurrent_writers] = false
      log(:start, seed: @result[:seed])
    end

    def generate
      directory = File.join(@root, "generated", @mode)
      unless Dir.exist?(directory)
        RubyLLM::Generators::UpgradeGenerator.start(["--mode=#{@mode}"], destination_root: directory)
      end
      namespace = Module.new
      @result[:migration_hashes] = {}
      %i[prepare backfill finish].to_h do |phase|
        path = Dir[File.join(directory, "db/migrate", "*#{phase}*.rb")].fetch(0)
        source = File.read(path)
        @result[:migration_hashes][phase] = Digest::SHA256.hexdigest(source)
        namespace.module_eval(source, path)
        name = source.match(/class (\w+) < ActiveRecord::Migration/)[1]
        migration = namespace.const_get(name)
        if phase == :backfill && migration.const_get(:BATCH_SIZE) != MigrationBench::BATCH_SIZE
          raise "Generated batch size differs from the benchmark configuration"
        end
        [phase, migration.new]
      end
    end

    def machine_metadata
      data = {platform: RUBY_PLATFORM}
      if File.exist?("/proc/cpuinfo")
        data[:cpu] = File.readlines("/proc/cpuinfo").find { |line| line.start_with?("model name") }&.split(":", 2)&.last&.strip
        data[:memory_kib] = File.read("/proc/meminfo")[/^MemTotal:\s+(\d+)/, 1].to_i
        filesystem, status = Open3.capture2("stat", "-f", "-c", "%T", @cluster.directory)
        data[:filesystem] = filesystem.strip if status.success?
      end
      data
    end

    def expected_fingerprints
      {
        messages: fingerprint(<<~SQL),
          SELECT id,chat_id,role,CASE WHEN content_raw IS NULL THEN content ELSE content_raw::text END AS content,
            content_raw::jsonb AS raw_content,thinking_text,thinking_signature,created_at,updated_at FROM messages
        SQL
        chats: fingerprint("SELECT c.id,m.provider,m.model_id FROM chats c JOIN models m ON m.id=c.model_id"),
        tools: fingerprint(<<~SQL),
          SELECT t.tool_call_id,t.name,t.arguments,t.thought_signature,'Message'::text AS message_type,t.message_id,
            'Message'::text AS result_type,r.id AS result_id,t.created_at,t.updated_at
          FROM tool_calls t JOIN messages r ON r.tool_call_id=t.id
        SQL
        usages: fingerprint(expected_usage)
      }
    end

    def target_fingerprints
      content = (@mode == "copy") ? "ruby_llm_content" : "content"
      {
        messages: fingerprint("SELECT id,chat_id,role,#{content} AS content,raw_content,thinking_text,thinking_signature,created_at,updated_at FROM messages"),
        chats: fingerprint("SELECT c.id,m.provider,m.model_id FROM chats c JOIN ruby_llm_models m ON m.id=c.ruby_llm_model_id"),
        tools: fingerprint("SELECT tool_call_id,name,arguments,thought_signature,message_type,message_id,result_type,result_id,created_at,updated_at FROM ruby_llm_tool_calls"),
        usages: fingerprint("SELECT #{USAGE_FIELDS.join(",")} FROM ruby_llm_usages")
      }
    end

    def expected_usage
      costs = %w[input output cache_read cache_write thinking].map do |key|
        "NULLIF(m.cost_details->>'#{key}','')::numeric(16,10) AS #{key}_cost"
      end
      <<~SQL
        SELECT 'Chat'::text AS chat_type,m.chat_id,'Message'::text AS message_type,m.id AS message_id,
          'chat'::text AS operation,COALESCE(mm.provider,cm.provider) AS provider,COALESCE(mm.model_id,cm.model_id) AS model,
          'succeeded'::text AS status,m.input_tokens,m.output_tokens,m.cached_tokens AS cache_read_tokens,
          m.cache_creation_tokens AS cache_write_tokens,m.thinking_tokens,#{costs.join(",")},
          COALESCE(m.total_cost,NULLIF(m.cost_details->>'total','')::numeric)::numeric(16,10) AS total_cost,
          m.created_at,m.updated_at FROM messages m LEFT JOIN models mm ON mm.id=m.model_id
          LEFT JOIN chats c ON c.id=m.chat_id LEFT JOIN models cm ON cm.id=c.model_id
          WHERE m.role='assistant'
      SQL
    end

    def legacy_fingerprints
      @legacy_columns.to_h do |table, columns|
        fields = columns.map { |column| @connection.quote_column_name(column) }.join(",")
        [table, fingerprint("SELECT #{fields} FROM #{@connection.quote_table_name(table)}")]
      end
    end

    def fingerprint(sql)
      @connection.select_one(<<~SQL)
        SELECT count(*) AS count,bit_xor(hashtextextended(to_jsonb(rows)::text,0))::text AS xor_hash,
          sum(hashtextextended(to_jsonb(rows)::text,1)::numeric)::text AS sum_hash FROM (#{sql}) rows
      SQL
    end

    def verify_counts
      raise "Chat count changed" unless @connection.select_value("SELECT count(*) FROM chats") == @result[:seed].fetch("chats")
      raise "Message count changed" unless @connection.select_value("SELECT count(*) FROM messages") == @result[:seed].fetch("messages")
      if @mode == "copy"
        raise "Journal not drained" unless @connection.select_value("SELECT count(*) FROM ruby_llm_v2_changes").zero?
        state = @connection.select_one("SELECT active_version,status FROM ruby_llm_v2_upgrades")
        raise "Copy not active on2.0" unless state == {"active_version" => 2, "status" => "active"}
      end
      duplicates = @connection.select_value("SELECT count(*) FROM (SELECT message_id FROM ruby_llm_usages GROUP BY message_id HAVING count(*) <> 1) d")
      raise "Duplicate usage" unless duplicates.zero?
    end

    def phase(name)
      started = clock
      result = yield
      @result[:phases][name] = clock - started
      log(:phase, name:, seconds: @result[:phases][name])
      result
    end

    def log(event, **values)
      puts JSON.generate(event:, profile: @profile, mode: @mode, repeat: @repeat, **values)
      $stdout.flush
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
