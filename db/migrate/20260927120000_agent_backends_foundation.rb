# frozen_string_literal: true

class AgentBackendsFoundation < ActiveRecord::Migration[8.1]
  def change
    change_table :backends, bulk: true do |t|
      t.string :connection_kind, null: false, default: 'legacy'
      t.references :owner_user, foreign_key: { to_table: :users }
      t.string :description
      t.string :visibility, null: false, default: 'private'
      t.boolean :paused, null: false, default: false
      t.boolean :owner_priority, null: false, default: true
      t.integer :max_queued_per_other_user, null: false, default: 3
      t.jsonb :allowed_workflow_ids
      t.string :auto_download_policy, null: false, default: 'owner_jobs'
      t.string :agent_version
      t.string :comfyui_version
      t.jsonb :system_json, null: false, default: {}
      t.boolean :model_downloads_enabled, default: false, null: false
      t.string :gpu_name
      t.bigint :vram_total
      t.datetime :connected_at
      t.datetime :last_seen_at
      t.datetime :offline_since
      t.string :offline_reason
      t.jsonb :last_status_json, null: false, default: {}
      t.datetime :last_status_persisted_at
      t.datetime :deleted_at
    end

    change_column_null :backends, :base_url, true

    create_table :backend_keys do |t|
      t.references :backend, null: false, foreign_key: true
      t.string :prefix, null: false
      t.string :key_hash, null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.string :last_ip
      t.datetime :last_rejected_at
      t.string :last_rejected_reason
      t.timestamps
    end
    add_index :backend_keys, :prefix, unique: true

    create_table :backend_shares do |t|
      t.references :backend, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :backend_shares, %i[backend_id user_id], unique: true

    create_table :backend_inventories do |t|
      t.references :backend, null: false, foreign_key: true, index: { unique: true }
      t.string :inventory_hash, null: false
      t.jsonb :models_json, null: false, default: {}
      t.jsonb :node_types_json, null: false, default: []
      t.string :object_info_hash
      t.timestamps
    end

    create_table :backend_models do |t|
      t.references :backend, null: false, foreign_key: true
      t.string :folder, null: false
      t.string :filename, null: false
      t.timestamps
    end
    add_index :backend_models, %i[backend_id folder filename], unique: true
    add_index :backend_models, %i[backend_id filename]

    change_table :generations, bulk: true do |t|
      t.string :agent_state
      t.jsonb :filled_workflow_json
      t.string :structure_hash
      t.string :model_set_hash
      t.float :work_units
      t.string :dispatch_request_id
      t.datetime :queued_at
      t.datetime :dispatched_at
      t.datetime :accepted_at
      t.datetime :running_at
      t.datetime :cancel_requested_at
      t.datetime :last_terminal_at
      t.string :agent_phase
      t.float :agent_progress, default: 0.0
      t.string :current_node
      t.integer :agent_attempt, null: false, default: 0
      t.integer :agent_moves, null: false, default: 0
      t.float :queue_order
      t.bigint :pinned_backend_id
      t.jsonb :excluded_backend_ids, null: false, default: []
      t.jsonb :error_json, null: false, default: {}
      t.boolean :warm, null: false, default: false
      t.integer :predicted_total_ms
      t.integer :predicted_p90_ms
      t.datetime :predicted_start_at
      t.datetime :predicted_end_at
      t.string :prediction_confidence
      t.integer :prediction_source
    end
    add_index :generations, %i[backend_id agent_state]
    add_index :generations, :pinned_backend_id

    create_table :generation_inputs do |t|
      t.references :generation, null: false, foreign_key: true
      t.string :input_id, null: false
      t.string :storage_key, null: false
      t.string :filename, null: false
      t.string :mime
      t.bigint :bytes
      t.string :sha256
      t.timestamps
    end
    add_index :generation_inputs, %i[generation_id input_id], unique: true

    create_table :generation_outputs do |t|
      t.string :upload_id, null: false
      t.references :generation, null: false, foreign_key: true
      t.references :backend, foreign_key: true
      t.string :node, null: false
      t.string :filename, null: false
      t.string :kind, null: false
      t.string :mime
      t.bigint :bytes
      t.string :storage_key
      t.timestamps
    end
    add_index :generation_outputs, :upload_id, unique: true

    change_table :model_downloads, bulk: true do |t|
      t.string :agent_download_id
      t.string :agent_state
      t.bigint :bytes_total
      t.bigint :bytes_done, default: 0
      t.bigint :speed_bps
      t.string :agent_reason
      t.text :agent_detail
      t.string :sha256
      t.references :requested_by_user, foreign_key: { to_table: :users }
      t.boolean :auto, null: false, default: false
      t.jsonb :for_generation_ids, null: false, default: []
      t.datetime :sent_at
    end
    add_index :model_downloads, :agent_download_id, unique: true, where: 'agent_download_id IS NOT NULL'

    change_table :workflows, bulk: true do |t|
      t.jsonb :ui_graph
      t.jsonb :requirements_json
      t.string :structure_hash
      t.integer :default_timeout_s
      t.boolean :requirements_need_review, null: false, default: false
    end

    change_table :users, bulk: true do |t|
      t.string :backend_affinity, null: false, default: 'auto'
      t.boolean :delete_uploads_after_run, null: false, default: false
    end

    change_table :app_settings, bulk: true do |t|
      t.boolean :allow_user_backends, null: false, default: true
    end
  end
end
