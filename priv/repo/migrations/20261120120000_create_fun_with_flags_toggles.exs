defmodule Kanban.Repo.Migrations.CreateFunWithFlagsToggles do
  @moduledoc """
  Creates `fun_with_flags_toggles`, where the fun_with_flags Ecto store keeps
  every feature-flag gate (`Kanban.FeatureFlags`, W2907): one row per flag,
  gate type and target, with whether that gate is on.

  Copied from the library's own
  `priv/ecto_repo/migrations/00000000000000_create_feature_flags_table.exs`
  (fun_with_flags 1.13). The store upserts on `(flag_name, gate_type, target)`
  and its changeset names the unique index `fwf_flag_name_gate_target_idx`,
  so both the columns and the index name must stay exactly as they are. The
  table name and the bigserial primary key are the library defaults, which
  this app does not override.

  A user gate stores the text `"user:<id>"` in `target`, not a foreign key,
  so deleting an account leaves its gate behind. `Kanban.FeatureFlags.state/1`
  still reports that id, which is what lets the admin page show and clear it.
  """
  use Ecto.Migration

  def up do
    create table(:fun_with_flags_toggles, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :flag_name, :string, null: false
      add :gate_type, :string, null: false
      add :target, :string, null: false
      add :enabled, :boolean, null: false
    end

    create index(
             :fun_with_flags_toggles,
             [:flag_name, :gate_type, :target],
             unique: true,
             name: "fwf_flag_name_gate_target_idx"
           )
  end

  def down do
    drop table(:fun_with_flags_toggles)
  end
end
