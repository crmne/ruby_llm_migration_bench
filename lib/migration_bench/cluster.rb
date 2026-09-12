# frozen_string_literal: true

module MigrationBench
  # Only connects to a new, private Unix-socket cluster. Existing databases and
  # PGHOST/DATABASE_URL are deliberately not supported.
  class Cluster
    PORT = 55_439
    USER = "benchmark"
    DATABASE_NAME = /\Arllm_bench_[a-z0-9_]+\z/

    attr_reader :directory

    def initialize(output:, shared_buffers: "2GB")
      raise "Invalid shared buffer size" unless /\A[1-9][0-9]*(MB|GB)\z/.match?(shared_buffers)

      @output = output
      @shared_buffers = shared_buffers
    end

    def start
      raise "Run the benchmark as a non-root user" if Process.uid.zero?

      @bindir = locate_binaries
      temporary_root = ENV.fetch("TMPDIR", File.join(MigrationBench::ROOT, "tmp"))
      FileUtils.mkdir_p(temporary_root)
      @directory = Dir.mktmpdir("rllm-", temporary_root)
      raise "Temporary directory path is too long for a PostgreSQL socket" if File.join(directory, ".s.PGSQL.#{PORT}").bytesize > 103
      @data = File.join(directory, "data")
      command("initdb", "-D", @data, "-U", USER, "--auth-local=trust",
        "--auth-host=reject", "--encoding=UTF8", "--locale=C")
      config = <<~CONFIG
        listen_addresses = ''
        unix_socket_directories = '#{directory.gsub("'", "''")}'
        unix_socket_permissions = 0700
        port = #{PORT}
        shared_buffers = '#{@shared_buffers}'
        work_mem = '32MB'
        maintenance_work_mem = '512MB'
        max_wal_size = '8GB'
        min_wal_size = '512MB'
        checkpoint_timeout = '15min'
        fsync = on
        synchronous_commit = on
        full_page_writes = on
        autovacuum = on
        track_io_timing = on
        log_checkpoints = on
        log_lock_waits = on
        max_connections = 30
      CONFIG
      File.write(File.join(@data, "postgresql.auto.conf"), config)
      @start_attempted = true
      command("pg_ctl", "-D", @data, "-l", File.join(@output, "postgres.log"), "-w", "-t", "30", "start")
      admin do |db|
        raise "PostgreSQL 15 or newer is required" if db.server_version < 150_000
      end
      self
    end

    def connection_options(database)
      check_name!(database)
      {adapter: "postgresql", host: directory, port: PORT, database:, username: USER, pool: 2}
    end

    def create_database(name, template: nil)
      check_name!(name)
      check_name!(template) if template
      admin do |db|
        sql = "CREATE DATABASE #{PG::Connection.quote_ident(name)}"
        sql += " TEMPLATE #{PG::Connection.quote_ident(template)}" if template
        db.exec(sql)
      end
    end

    def drop_database(name)
      check_name!(name)
      admin { |db| db.exec("DROP DATABASE #{PG::Connection.quote_ident(name)}") }
    end

    def close(discard:)
      ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
      if @start_attempted
        command("pg_ctl", "-D", @data, "-w", "-t", "30", "stop", "-m", "fast")
      end
      return unless directory

      if discard
        FileUtils.remove_entry_secure(directory)
      else
        warn "Failed run: stopped synthetic database retained at #{directory}"
      end
    end

    private

    def check_name!(name)
      raise "Not a benchmark database name: #{name.inspect}" unless name.bytesize <= 63 && DATABASE_NAME.match?(name)
    end

    def admin
      db = PG.connect(host: directory, port: PORT, dbname: "postgres", user: USER, connect_timeout: 5)
      actual = db.exec("SHOW data_directory").getvalue(0, 0)
      raise "Refusing access to a different PostgreSQL cluster" unless actual == @data

      yield db
    ensure
      db&.close
    end

    def locate_binaries
      candidates = [ENV["PG_BINDIR"]].compact
      unless ENV["PG_BINDIR"]
        begin
          output, status = Open3.capture2("pg_config", "--bindir")
          candidates << output.strip if status.success?
        rescue Errno::ENOENT
          # The server tools may still be available directly on PATH.
        end
        candidates.concat(ENV.fetch("PATH", "").split(File::PATH_SEPARATOR))
      end
      candidates.find do |path|
        %w[initdb pg_ctl postgres].all? { |name| File.executable?(File.join(path, name)) }
      end || raise("Install PostgreSQL server tools or set PG_BINDIR to their bin directory")
    end

    def command(binary, *arguments)
      output, status = Open3.capture2e(File.join(@bindir, binary), *arguments)
      File.open(File.join(@output, "cluster.log"), "a") { |file| file.puts(output) }
      raise "#{binary} failed: #{output}" unless status.success?
    end
  end
end
