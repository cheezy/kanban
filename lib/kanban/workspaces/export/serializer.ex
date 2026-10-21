defmodule Kanban.Workspaces.Export.Serializer do
  @moduledoc """
  The versioned JSON format of a workspace export archive, shared by the
  export (`Kanban.Workspaces.Export.Writer`) and the self-host import
  (`Kanban.Workspaces.Export.Importer`).

  An archive is a zip holding `manifest.json` and one JSON array per entity in
  `entities/0`. Each row is built from an explicit field allow-list
  (`fields/1`), never from a whole struct, so a column added to a schema later
  stays out of the archive until it is listed here. Nothing that authenticates
  anyone is listed: no password or token hashes, no session or invitation
  tokens, no API tokens, no webhook secrets, and nothing from the
  Organization — not even its name — so its address and contact details can
  never appear. Users appear only as `{id, email, name}`, and only when
  something in the archive refers to them.

  An archive holds only the workspace's boards and what is on them, plus its
  member and guest rows. It leaves out, besides the secrets above:

    * delivery targets, which belong to the user who made them rather than to
      a workspace — a goal's `target_id` is not listed, so an imported goal
      has no target;
    * webhook endpoints, notifications, workspace invitations, claim-expiry
      reports, metrics and audit events, and earlier exports.

  Rows keep their source ids so the importer can remap every reference; the
  importer never reuses one. `format_version/0` changes whenever a field is
  removed or changes meaning; the importer refuses any version it does not
  know.
  """

  @format "stride-workspace-export"
  @format_version 1

  @entities [
    :boards,
    :columns,
    :labels,
    :tasks,
    :task_labels,
    :comments,
    :task_history,
    :board_users,
    :workspace_members,
    :users
  ]

  @fields %{
    boards: [
      :id,
      :name,
      :description,
      :ai_optimized_board,
      :read_only,
      :field_visibility,
      :inserted_at,
      :updated_at
    ],
    columns: [:id, :board_id, :name, :position, :wip_limit, :inserted_at, :updated_at],
    labels: [:id, :board_id, :name, :color, :inserted_at, :updated_at],
    task_labels: [:task_id, :label_id],
    tasks: [
      :id,
      :column_id,
      :parent_id,
      :duplicate_of_id,
      :identifier,
      :title,
      :description,
      :acceptance_criteria,
      :position,
      :type,
      :priority,
      :status,
      :complexity,
      :estimated_files,
      :why,
      :what,
      :where_context,
      :patterns_to_follow,
      :database_changes,
      :validation_rules,
      :telemetry_event,
      :metrics_to_track,
      :logging_requirements,
      :error_user_message,
      :error_on_failure,
      :key_files,
      :verification_steps,
      :behaviour_test_matrix,
      :technology_requirements,
      :pitfalls,
      :out_of_scope,
      :security_considerations,
      :testing_strategy,
      :integration_points,
      :technical_details,
      :dependencies,
      :required_capabilities,
      :assigned_to_id,
      :created_by_id,
      :created_by_agent,
      :completed_at,
      :completed_by_id,
      :completed_by_agent,
      :completion_summary,
      :completion_notes,
      :claimed_at,
      :claim_expires_at,
      :actual_complexity,
      :actual_files_changed,
      :time_spent_minutes,
      :human_task,
      :needs_review,
      :review_status,
      :review_notes,
      :review_report,
      :workflow_steps,
      :changed_files,
      :explorer_result,
      :reviewer_result,
      :reviewed_by_id,
      :reviewed_at,
      :review_requested_at,
      :after_goal_status,
      :after_goal_result,
      :after_goal_attempts,
      :archived_at,
      :archive_reason,
      :archive_note,
      :archived_by_id,
      :inserted_at,
      :updated_at
    ],
    comments: [
      :id,
      :task_id,
      :author_user_id,
      :author_agent_name,
      :content,
      :edited_at,
      :mentioned_user_ids,
      :inserted_at,
      :updated_at
    ],
    task_history: [
      :id,
      :task_id,
      :type,
      :from_column,
      :to_column,
      :from_priority,
      :to_priority,
      :from_user_id,
      :to_user_id,
      :inserted_at
    ],
    board_users: [:board_id, :user_id, :access, :inserted_at, :updated_at],
    workspace_members: [:user_id, :role, :inserted_at, :updated_at],
    users: [:id, :email, :name]
  }

  @embed_fields %{
    key_files: [:file_path, :note, :position],
    verification_steps: [:step_type, :step_text, :expected_result, :position],
    behaviour_test_matrix: [
      :category,
      :behaviour,
      :test_name,
      :type,
      :status,
      :na_reason,
      :position
    ]
  }

  @doc "The archive's format name, written to and checked in the manifest."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The archive format version this code writes and reads."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc "The entities in an archive, in the order they are written and imported."
  @spec entities() :: [atom()]
  def entities, do: @entities

  @doc "The archive file name of `entity`, or of the manifest."
  @spec file_name(atom()) :: String.t()
  def file_name(:manifest), do: "manifest.json"
  def file_name(entity) when entity in @entities, do: "#{entity}.json"

  @doc "Every file name an archive may hold: the manifest and one per entity."
  @spec file_names() :: [String.t()]
  def file_names, do: [file_name(:manifest) | Enum.map(@entities, &file_name/1)]

  @doc "The allow-listed fields of `entity`, in archive order."
  @spec fields(atom()) :: [atom()]
  def fields(entity) when entity in @entities, do: Map.fetch!(@fields, entity)

  @doc "The allow-listed fields of one of a task's embedded lists."
  @spec embed_fields(atom()) :: [atom()]
  def embed_fields(embed), do: Map.fetch!(@embed_fields, embed)

  @doc """
  Encodes one struct or map as an archive row: a map with a string key for
  every allow-listed field of `entity` and nothing else. Atoms become strings,
  timestamps ISO 8601, and a task's embedded lists their own allow-listed maps.
  """
  @spec encode_row(atom(), map()) :: map()
  def encode_row(entity, row) do
    entity
    |> fields()
    |> Map.new(fn field -> {Atom.to_string(field), dump(field, Map.fetch!(row, field))} end)
  end

  @doc "Encodes the manifest for `workspace_name` with per-entity `counts`."
  @spec encode_manifest(String.t(), %{atom() => non_neg_integer()}, DateTime.t()) :: iodata()
  def encode_manifest(workspace_name, counts, %DateTime{} = exported_at) do
    Jason.encode_to_iodata!(%{
      "format" => @format,
      "format_version" => @format_version,
      "exported_at" => DateTime.to_iso8601(exported_at),
      "app_version" => app_version(),
      "workspace" => %{"name" => workspace_name},
      "counts" => Map.new(@entities, &{Atom.to_string(&1), Map.get(counts, &1, 0)}),
      "files" => Enum.map(@entities, &file_name/1)
    })
  end

  @doc """
  Decodes and checks a manifest. The format must be this one and the version
  one this code knows, before any other file is read.
  """
  @spec decode_manifest(binary()) ::
          {:ok, map()} | {:error, :invalid_manifest | {:unsupported_format_version, term()}}
  def decode_manifest(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, %{"format" => @format, "format_version" => @format_version} = manifest} ->
        validate_manifest(manifest)

      {:ok, %{"format" => @format, "format_version" => version}} ->
        {:error, {:unsupported_format_version, version}}

      _other ->
        {:error, :invalid_manifest}
    end
  end

  defp validate_manifest(%{"counts" => counts, "workspace" => %{"name" => name}} = manifest)
       when is_map(counts) and is_binary(name) do
    if Enum.all?(@entities, &non_neg_integer?(Map.get(counts, Atom.to_string(&1)))),
      do: {:ok, manifest},
      else: {:error, :invalid_manifest}
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_manifest}

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  @doc """
  Decodes one entity file into rows. The file must be a JSON array of objects;
  each row keeps only the allow-listed keys of `entity`, so anything else in
  the archive is dropped before it reaches a changeset. Values are left for
  the importer's changesets to cast.
  """
  @spec decode_rows(atom(), binary()) :: {:ok, [map()]} | {:error, {:invalid_file, atom()}}
  def decode_rows(entity, binary) when entity in @entities and is_binary(binary) do
    keys = entity |> fields() |> Enum.map(&Atom.to_string/1)

    case decode_objects(binary) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Map.take(&1, keys))}
      :error -> {:error, {:invalid_file, entity}}
    end
  end

  # A JSON array of objects, or :error.
  defp decode_objects(binary) do
    with {:ok, rows} when is_list(rows) <- Jason.decode(binary),
         true <- Enum.all?(rows, &is_map/1) do
      {:ok, rows}
    else
      _invalid -> :error
    end
  end

  defp dump(embed, rows) when is_map_key(@embed_fields, embed) and is_list(rows) do
    keys = embed_fields(embed)
    Enum.map(rows, fn row -> Map.new(keys, &{Atom.to_string(&1), dump(&1, Map.get(row, &1))}) end)
  end

  defp dump(_field, value), do: dump_value(value)

  defp dump_value(nil), do: nil
  defp dump_value(value) when is_boolean(value), do: value
  defp dump_value(value) when is_atom(value), do: Atom.to_string(value)
  defp dump_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp dump_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp dump_value(value), do: value

  defp app_version do
    case Application.spec(:kanban, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end
end
