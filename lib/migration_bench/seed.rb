# frozen_string_literal: true

module MigrationBench
  class Seed
    def initialize(connection) = @connection = connection

    def run(chats:, payload_bytes: 256)
      started = MigrationBench.clock
      create_schema
      profile = "ten"
      expression = "10"
      @connection.execute(<<~SQL)
        INSERT INTO models(model_id,name,provider,created_at,updated_at)
        VALUES ('gpt-4.1','GPT-4.1','openai','2026-08-01','2026-08-01'),
               ('gpt-4.1-mini','GPT-4.1 mini','openai','2026-08-01','2026-08-01');
        CREATE TABLE bench_chat_lengths AS
        SELECT id, length, COALESCE(sum(length) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)::bigint AS start_id
        FROM (SELECT id, #{expression} AS length FROM generate_series(1,#{Integer(chats)}) id) lengths;
        ALTER TABLE bench_chat_lengths ADD PRIMARY KEY(id);
        INSERT INTO chats(id,model_id,created_at,updated_at)
        SELECT id,1,'2026-08-01','2026-08-01' FROM bench_chat_lengths;
      SQL
      blocks = [(Integer(payload_bytes) / 32.0).ceil, 1].max
      (1..chats).step(1000) do |first|
        @connection.execute(<<~SQL)
          INSERT INTO messages(id,chat_id,model_id,role,content,content_raw,input_tokens,output_tokens,
            cached_tokens,cache_creation_tokens,thinking_tokens,total_cost,cost_details,created_at,updated_at)
          SELECT id,chat_id,CASE WHEN id%3=0 THEN NULL ELSE 1 END,role,
            CASE WHEN id%20=10 THEN NULL ELSE payload END,
            CASE WHEN id%10=0 OR role='tool' THEN json_build_object('text',payload,'ordinal',id) ELSE NULL END,
            CASE WHEN role='assistant' THEN 150+(id%5000) END,
            CASE WHEN role='assistant' THEN 50+(id%1000) END,
            CASE WHEN role='assistant' THEN (id%100)::int END,
            CASE WHEN role='assistant' THEN (id%50)::int END,
            CASE WHEN role='assistant' THEN (id%20)::int END,
            CASE WHEN role='assistant' AND id%3=0 THEN 0.0000123456 END,
            CASE WHEN role='assistant' THEN '{"input":0.00001,"output":0.000002,"cache_read":0.0000001,"cache_write":0.0000002,"thinking":0.0000000456,"total":0.0000123456}'::jsonb END,
            '2026-08-01'::timestamp + (id%1000000)*interval '1 second',
            '2026-08-01'::timestamp + (id%1000000)*interval '1 second'
          FROM (
            SELECT start_id+position AS id, c.id AS chat_id,
              CASE WHEN position%10=4 THEN 'tool' WHEN position%2=0 OR position%10=3 THEN 'assistant' ELSE 'user' END AS role,
              (SELECT string_agg(md5((start_id+position)::text || ':' || part::text),'') FROM generate_series(1,#{blocks}) part) AS payload
            FROM bench_chat_lengths c CROSS JOIN LATERAL generate_series(1,c.length) position
            WHERE c.id BETWEEN #{first} AND #{[first + 999, chats].min}
          ) source;
        SQL
        MigrationBench.log("seed_progress", chats: [first + 999, chats].min) if first % 10_000 == 1
      end
      @connection.execute(<<~SQL)
        INSERT INTO tool_calls(id,message_id,tool_call_id,name,arguments,created_at,updated_at)
        SELECT m.id,m.id-1,'call-'||m.id,'lookup',jsonb_build_object('query','synthetic-'||m.id),m.created_at,m.updated_at
        FROM messages m WHERE role='tool';
        UPDATE messages SET tool_call_id=id WHERE role='tool';
      SQL
      %w[chats messages tool_calls].each { @connection.reset_pk_sequence!(it) }
      @connection.execute("VACUUM (ANALYZE)")
      @connection.execute("CHECKPOINT")
      stats = @connection.select_one(<<~SQL)
        SELECT count(*)::bigint AS chats,sum(length)::bigint AS messages,min(length) AS min_length,
          max(length) AS max_length,avg(length)::float AS mean_length,
          percentile_disc(ARRAY[0.5,0.95,0.99,0.999]) WITHIN GROUP (ORDER BY length) AS percentiles
        FROM bench_chat_lengths
      SQL
      stats.merge!(profile: profile, payload_bytes: payload_bytes, seed_seconds: MigrationBench.clock - started,
        database_bytes: @connection.select_value("SELECT pg_database_size(current_database())"),
        message_table_bytes: @connection.select_value("SELECT pg_total_relation_size('messages')"))
      @connection.execute("CREATE TABLE bench_metadata (data jsonb NOT NULL)")
      @connection.execute("INSERT INTO bench_metadata VALUES (#{@connection.quote(JSON.generate(stats))}::jsonb)")
      stats
    end

    def create_schema
      ActiveRecord::Schema.define do
        create_table :models do |table|
          table.string :model_id, :name, :provider, null: false
          table.string :family
          table.datetime :model_created_at
          table.integer :context_window, :max_output_tokens
          table.date :knowledge_cutoff
          table.jsonb :modalities, :pricing, :metadata, default: {}
          table.jsonb :capabilities, default: []
          table.timestamps
          table.index [:provider, :model_id], unique: true
          table.index :provider
          table.index :family
          table.index :capabilities, using: :gin
          table.index :modalities, using: :gin
        end
        create_table :chats do |table|
          table.references :model, foreign_key: true
          table.timestamps
        end
        create_table :messages do |table|
          table.string :role, null: false
          table.text :content, :thinking_text, :thinking_signature
          table.json :content_raw
          table.integer :thinking_tokens, :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens
          table.decimal :total_cost, precision: 16, scale: 10
          table.jsonb :cost_details
          table.references :chat, null: false, foreign_key: true
          table.references :model, foreign_key: true
          table.timestamps
          table.index :role
        end
        create_table :tool_calls do |table|
          table.string :tool_call_id, :name, null: false
          table.text :thought_signature
          table.jsonb :arguments, default: {}
          table.references :message, null: false, foreign_key: true
          table.timestamps
          table.index :tool_call_id, unique: true
          table.index :name
        end
        add_reference :messages, :tool_call, foreign_key: true
      end
    end
  end
end
