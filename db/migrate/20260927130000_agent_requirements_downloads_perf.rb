# frozen_string_literal: true

class AgentRequirementsDownloadsPerf < ActiveRecord::Migration[8.1]
  def change
    create_workflow_tables
    create_credential_tables
    create_attempt_tables
    create_perf_tables
    create_load_tables
  end

  private

  def create_workflow_tables
    create_table :workflow_models do |t|
      t.references :workflow, null: false, foreign_key: true
      t.string :folder, null: false
      t.string :filename, null: false
      t.text :url
      t.string :sha256
      t.bigint :bytes
      t.string :source, null: false, default: 'api'
      t.timestamps
    end
    add_index :workflow_models, %i[workflow_id folder filename], unique: true

    create_table :backend_object_infos do |t|
      t.references :backend, null: false, foreign_key: true
      t.string :object_info_hash, null: false
      t.binary :blob_gz, null: false
      t.timestamps
    end
    add_index :backend_object_infos, %i[backend_id object_info_hash], unique: true

    create_table :workflow_availabilities do |t|
      t.references :workflow, null: false, foreign_key: true
      t.references :backend, null: false, foreign_key: true
      t.string :status, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    add_index :workflow_availabilities, %i[workflow_id backend_id], unique: true
  end

  def create_credential_tables
    create_table :source_credentials do |t|
      t.references :owner_user, foreign_key: { to_table: :users }
      t.string :host, null: false
      t.text :secret, null: false
      t.string :label
      t.string :last4, null: false
      t.timestamps
    end
    add_index :source_credentials, %i[owner_user_id host], unique: true
  end

  def create_attempt_tables
    create_table :job_attempts do |t|
      t.references :generation, null: false, foreign_key: true
      t.integer :attempt, null: false
      t.references :backend, foreign_key: true
      t.string :outcome, null: false
      t.string :reason
      t.boolean :infra, null: false, default: false
      t.jsonb :timings_json, null: false, default: {}
      t.boolean :warm, null: false, default: false
      t.integer :predicted_execute_ms
      t.datetime :started_at
      t.datetime :ended_at
      t.timestamps
    end
    add_index :job_attempts, %i[backend_id created_at]
  end

  def create_perf_tables
    create_table :perf_samples do |t|
      t.references :job_attempt, foreign_key: true
      t.references :backend, null: false, foreign_key: true
      t.references :workflow, foreign_key: true
      t.string :structure_hash
      t.float :work_units, null: false, default: 1.0
      t.boolean :warm, null: false, default: false
      t.float :cached_ratio, null: false, default: 0.0
      t.integer :execute_ms
      t.integer :inputs_ms
      t.integer :upload_ms
      t.integer :local_queue_ms
      t.integer :dispatch_ms
      t.bigint :input_bytes
      t.bigint :output_bytes
      t.datetime :completed_at, null: false
      t.timestamps
    end
    add_index :perf_samples, %i[backend_id structure_hash warm]
    add_index :perf_samples, :completed_at

    create_table :perf_stats do |t|
      t.references :backend, null: false, foreign_key: true
      t.string :structure_hash, null: false
      t.references :workflow, foreign_key: true
      t.boolean :warm, null: false, default: false
      t.integer :n, null: false, default: 0
      t.float :sw, null: false, default: 0.0
      t.float :swx, null: false, default: 0.0
      t.float :swy, null: false, default: 0.0
      t.float :swxx, null: false, default: 0.0
      t.float :swxy, null: false, default: 0.0
      t.float :sres2, null: false, default: 0.0
      t.float :median_work_units
      t.float :output_bytes_ewma
      t.timestamps
    end
    add_index :perf_stats, %i[backend_id structure_hash warm], unique: true

    create_table :backend_speeds do |t|
      t.references :backend, null: false, foreign_key: true, index: { unique: true }
      t.float :speed_index, null: false, default: 1.0
      t.integer :n_workflows, null: false, default: 0
      t.float :cold_penalty_ms
      t.float :busy_local_ewma_s
      t.timestamps
    end

    create_table :transfer_stats do |t|
      t.references :backend, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :host, null: false, default: ''
      t.float :ewma_bps
      t.float :ewma_fixed_ms
      t.integer :n, null: false, default: 0
      t.timestamps
    end
    add_index :transfer_stats, %i[backend_id kind host], unique: true

    create_table :prediction_logs do |t|
      t.references :generation, null: false, foreign_key: true
      t.references :backend, foreign_key: true
      t.string :structure_hash
      t.integer :predicted_total_ms
      t.integer :actual_total_ms
      t.string :confidence
      t.integer :source
      t.timestamps
    end
    add_index :prediction_logs, :created_at
  end

  def create_load_tables
    create_table :backend_load_minutes do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.references :backend, null: false, foreign_key: true, index: false
      t.datetime :minute, null: false
      t.float :online_s, null: false, default: 0.0
      t.float :busy_s, null: false, default: 0.0
      t.float :busy_local_s, null: false, default: 0.0
      t.integer :queue_len_max, null: false, default: 0
      t.integer :jobs_completed, null: false, default: 0
    end
    add_index :backend_load_minutes, %i[backend_id minute], unique: true

    create_table :backend_load_hours do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.references :backend, null: false, foreign_key: true, index: false
      t.datetime :hour, null: false
      t.float :online_s, null: false, default: 0.0
      t.float :busy_s, null: false, default: 0.0
      t.float :busy_local_s, null: false, default: 0.0
      t.integer :queue_len_max, null: false, default: 0
      t.integer :jobs_completed, null: false, default: 0
    end
    add_index :backend_load_hours, %i[backend_id hour], unique: true
  end
end
