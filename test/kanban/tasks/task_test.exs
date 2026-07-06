defmodule Kanban.Tasks.TaskTest do
  @moduledoc """
  Changeset validation tests for `Kanban.Tasks.Task` archive-metadata
  fields introduced in W570 — `archive_reason`, `archive_note`,
  `archived_by_id`, `duplicate_of_id`.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  # Only includes archive-related casts. Required base fields (title,
  # position, type, priority, status) are already set on the persisted
  # task by the fixture, so validate_required/2 reads them via get_field/2
  # without us re-casting and risking the unique [column_id, position]
  # constraint when we later persist via Repo.update/1.
  defp base_attrs(overrides), do: overrides

  describe "varchar(255) length validation (D81)" do
    @over String.duplicate("a", 256)
    @at_limit String.duplicate("a", 255)

    test "changeset/2 rejects a title over 255 characters", %{column: column} do
      task = task_fixture(column)
      changeset = Task.changeset(task, base_attrs(%{title: @over}))

      refute changeset.valid?
      assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "changeset/2 accepts a title of exactly 255 characters", %{column: column} do
      task = task_fixture(column)
      changeset = Task.changeset(task, base_attrs(%{title: @at_limit}))

      assert changeset.valid?
    end

    test "changeset/2 rejects each free-text varchar(255) field over 255 characters",
         %{column: column} do
      task = task_fixture(column)

      for field <- [
            :title,
            :estimated_files,
            :telemetry_event,
            :created_by_agent,
            :completed_by_agent
          ] do
        changeset = Task.changeset(task, base_attrs(%{field => @over}))

        refute changeset.valid?, "expected #{field} over 255 chars to be invalid"
        assert Keyword.has_key?(changeset.errors, field)
      end
    end

    test "api_create_changeset/2 rejects an oversized title" do
      attrs = %{
        "title" => @over,
        "position" => 0,
        "type" => "work",
        "priority" => "medium"
      }

      changeset = Task.api_create_changeset(%Task{}, attrs)

      refute changeset.valid?
      assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "api_update_changeset/2 rejects an oversized title", %{column: column} do
      task = task_fixture(column)
      changeset = Task.api_update_changeset(task, %{"title" => @over})

      refute changeset.valid?
      assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "counts Unicode code points, not graphemes, to match Postgres varchar(255)",
         %{column: column} do
      task = task_fixture(column)

      # 200 grapheme clusters of "é" (e + combining acute) = 400 code points.
      # A grapheme-based check would see 200 (<= 255) and wrongly pass, letting
      # the value overflow varchar(255) in the DB. Code-point counting rejects it.
      decomposed = String.duplicate("e" <> <<0x0301::utf8>>, 200)
      assert String.length(decomposed) == 200
      assert decomposed |> String.codepoints() |> length() == 400

      changeset = Task.changeset(task, base_attrs(%{title: decomposed}))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :title)
    end
  end

  describe "varchar(255)[] array-element length validation (D81 follow-up)" do
    # security_considerations / dependencies / required_capabilities are stored
    # as Postgres varchar(255)[]. Each ELEMENT is capped at 255 code points; an
    # oversized element must fail with a 422 changeset error rather than reaching
    # the DB and raising a 22001 (string_data_right_truncation) → HTTP 500.

    test "changeset/2 rejects a security_considerations element over 255 characters",
         %{column: column} do
      task = task_fixture(column)
      changeset = Task.changeset(task, base_attrs(%{security_considerations: ["ok", @over]}))

      refute changeset.valid?

      assert %{security_considerations: ["each entry should be at most 255 character(s)"]} =
               errors_on(changeset)
    end

    test "changeset/2 accepts a security_considerations element of exactly 255 characters",
         %{column: column} do
      task = task_fixture(column)
      changeset = Task.changeset(task, base_attrs(%{security_considerations: [@at_limit, "ok"]}))

      assert changeset.valid?
    end

    test "api_create_changeset/2 rejects an oversized security_considerations element" do
      attrs = %{
        "title" => "t",
        "position" => 0,
        "type" => "work",
        "priority" => "medium",
        "security_considerations" => ["fine", @over]
      }

      changeset = Task.api_create_changeset(%Task{}, attrs)

      refute changeset.valid?

      assert %{security_considerations: ["each entry should be at most 255 character(s)"]} =
               errors_on(changeset)
    end

    test "api_update_changeset/2 rejects an oversized security_considerations element",
         %{column: column} do
      task = task_fixture(column)

      changeset =
        Task.api_update_changeset(task, %{"security_considerations" => [@over]})

      refute changeset.valid?

      assert %{security_considerations: ["each entry should be at most 255 character(s)"]} =
               errors_on(changeset)
    end

    test "changeset/2 rejects an oversized dependencies element", %{column: column} do
      task = task_fixture(column)
      changeset = Task.changeset(task, base_attrs(%{dependencies: ["W1", @over]}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :dependencies)
    end

    test "counts Unicode code points, not graphemes, for array elements",
         %{column: column} do
      task = task_fixture(column)
      # 200 "e + combining acute" graphemes = 200 graphemes but 400 code points.
      # A grapheme-based check (String.length) would see 200 (<= 255) and wrongly
      # pass, letting the value overflow varchar(255)[]. Code-point counting rejects it.
      decomposed = String.duplicate("e" <> <<0x0301::utf8>>, 200)
      assert String.length(decomposed) == 200
      assert decomposed |> String.codepoints() |> length() == 400

      changeset = Task.changeset(task, base_attrs(%{security_considerations: [decomposed]}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :security_considerations)
    end
  end

  describe "archive_reason field" do
    test "accepts :completed with no archive_note", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: :completed}))
      assert changeset.valid?
      assert get_change(changeset, :archive_reason) == :completed
    end

    test "accepts a nil archive_reason (legacy archived rows)", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: nil}))
      assert changeset.valid?
    end

    test "rejects unknown archive_reason atom via Ecto.Enum", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: :nonsense}))

      refute changeset.valid?
      assert errors_on(changeset).archive_reason != []
    end
  end

  describe "archive_note required for :wontdo / :deferred / :cancelled" do
    for reason <- [:wontdo, :deferred, :cancelled] do
      @reason reason

      test "#{@reason} requires archive_note", %{column: column} do
        task = task_fixture(column)

        changeset = Task.changeset(task, base_attrs(%{archive_reason: @reason}))

        refute changeset.valid?

        assert "must be set when archive_reason is :wontdo, :deferred, or :cancelled" in errors_on(
                 changeset
               ).archive_note
      end

      test "#{@reason} accepts a present archive_note", %{column: column} do
        task = task_fixture(column)

        changeset =
          Task.changeset(
            task,
            base_attrs(%{archive_reason: @reason, archive_note: "Out of scope for v1."})
          )

        assert changeset.valid?
      end

      test "#{@reason} treats whitespace-only archive_note as missing", %{column: column} do
        task = task_fixture(column)

        changeset =
          Task.changeset(task, base_attrs(%{archive_reason: @reason, archive_note: "   \n"}))

        refute changeset.valid?
        assert errors_on(changeset).archive_note != []
      end
    end
  end

  describe "duplicate_of_id required for :duplicate" do
    test "requires duplicate_of_id when archive_reason is :duplicate", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: :duplicate}))

      refute changeset.valid?

      assert "must be set when archive_reason is :duplicate" in errors_on(changeset).duplicate_of_id
    end

    test "accepts a present duplicate_of_id when archive_reason is :duplicate",
         %{column: column} do
      canonical = task_fixture(column)
      task = task_fixture(column)

      changeset =
        Task.changeset(
          task,
          base_attrs(%{archive_reason: :duplicate, duplicate_of_id: canonical.id})
        )

      assert changeset.valid?
    end
  end

  describe "duplicate_of_id forbidden for non-:duplicate reasons" do
    for reason <- [:completed, :wontdo, :deferred, :cancelled] do
      @reason reason

      test "#{@reason} rejects a non-nil duplicate_of_id", %{column: column} do
        canonical = task_fixture(column)
        task = task_fixture(column)

        attrs =
          base_attrs(%{
            archive_reason: @reason,
            archive_note: "Some note",
            duplicate_of_id: canonical.id
          })

        changeset = Task.changeset(task, attrs)

        refute changeset.valid?

        assert "may only be set when archive_reason is :duplicate" in errors_on(changeset).duplicate_of_id
      end
    end
  end

  describe "target_id restricted to goal-type tasks" do
    for type <- [:work, :defect] do
      @task_type type

      test "#{@task_type} rejects a non-nil target_id", %{column: column, user: user} do
        target = delivery_target_fixture(user)
        task = task_fixture(column, %{type: @task_type})

        changeset = Task.changeset(task, base_attrs(%{target_id: target.id}))

        refute changeset.valid?
        assert "may only be set on goal-type tasks" in errors_on(changeset).target_id
      end
    end

    test "accepts a target_id on a goal task", %{column: column, user: user} do
      target = delivery_target_fixture(user)
      goal = task_fixture(column, %{type: :goal})

      changeset = Task.changeset(goal, base_attrs(%{target_id: target.id}))

      assert changeset.valid?
    end

    test "accepts a goal task with no target_id", %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      changeset = Task.changeset(goal, base_attrs(%{title: "Goal without a target"}))

      assert changeset.valid?
    end

    test "accepts a work task with no target_id", %{column: column} do
      task = task_fixture(column, %{type: :work})

      changeset = Task.changeset(task, base_attrs(%{title: "Work without a target"}))

      assert changeset.valid?
    end

    test "target_id nullifies when the referenced target is removed",
         %{column: column, user: user} do
      target = delivery_target_fixture(user)
      goal = task_fixture(column, %{type: :goal})

      {:ok, goal} =
        goal
        |> Task.changeset(base_attrs(%{target_id: target.id}))
        |> Repo.update()

      assert goal.target_id == target.id

      Repo.delete!(target)

      reloaded = Repo.get!(Task, goal.id)
      assert reloaded.target_id == nil
    end
  end

  describe "self-reference check constraint" do
    test "rejects a task that marks itself as its own duplicate", %{column: column} do
      task = task_fixture(column)

      changeset =
        Task.changeset(task, base_attrs(%{archive_reason: :duplicate, duplicate_of_id: task.id}))

      assert {:error, %Ecto.Changeset{} = errored} = Repo.update(changeset)

      assert "must not reference the task itself" in errors_on(errored).duplicate_of_id
    end
  end

  describe "archived_by foreign key" do
    test "accepts a valid archived_by_id pointing at a user",
         %{column: column, user: user} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archived_by_id: user.id}))
      assert changeset.valid?
      assert {:ok, persisted} = Repo.update(changeset)
      assert persisted.archived_by_id == user.id
    end

    test "rejects an archived_by_id that does not point at a real user",
         %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archived_by_id: 99_999_999}))
      assert {:error, %Ecto.Changeset{} = errored} = Repo.update(changeset)
      assert errors_on(errored).archived_by_id != []
    end
  end

  describe "associations" do
    test "belongs_to :archived_by loads the persisted user", %{column: column, user: user} do
      task = task_fixture(column)

      {:ok, updated} =
        task
        |> Task.changeset(base_attrs(%{archived_by_id: user.id}))
        |> Repo.update()

      loaded = Repo.preload(updated, :archived_by)
      assert loaded.archived_by.id == user.id
    end

    test "belongs_to :duplicate_of loads the canonical task", %{column: column} do
      canonical = task_fixture(column)
      task = task_fixture(column)

      {:ok, updated} =
        task
        |> Task.changeset(
          base_attrs(%{archive_reason: :duplicate, duplicate_of_id: canonical.id})
        )
        |> Repo.update()

      loaded = Repo.preload(updated, :duplicate_of)
      assert loaded.duplicate_of.id == canonical.id
    end
  end

  # ---------------------------------------------------------------------------
  # W1412: varchar(255) validator coverage guard
  # ---------------------------------------------------------------------------

  # Columns that are varchar(255) in the database but intentionally NOT covered
  # by a free-text length validator:
  #
  #   * enum-backed columns (type/priority/status/complexity/actual_complexity/
  #     review_status/archive_reason) are guarded by cast + validate_inclusion,
  #     which rejects any out-of-range value before length could matter. These
  #     are derived structurally from the schema (see enum_backed_fields/0), not
  #     hardcoded, so a future enum column is excluded automatically.
  #   * identifier is server-generated and bounded by construction.
  @server_generated_varchar_255 [:identifier]

  # Maps each schema field's database column name back to the field atom.
  # Avoids String.to_atom/1 on database-supplied names (the column names are
  # resolved against the known schema fields instead).
  defp schema_field_by_source do
    for field <- Task.__schema__(:fields), into: %{} do
      {Atom.to_string(field), field}
    end
  end

  # The set of Ecto.Enum-backed fields, derived from the schema rather than
  # hardcoded, so the guard's exclusion list tracks the schema automatically.
  defp enum_backed_fields do
    Task.__schema__(:fields)
    |> Enum.filter(fn field ->
      match?({:parameterized, {Ecto.Enum, _}}, Task.__schema__(:type, field))
    end)
    |> MapSet.new()
  end

  # The only reliable source for array ELEMENT length is pg_catalog.format_type/2:
  # information_schema.element_types reports a NULL character_maximum_length for
  # varchar(255)[] elements.
  @bounded_columns_sql """
  SELECT a.attname, format_type(a.atttypid, a.atttypmod)
  FROM pg_attribute a
  JOIN pg_class cl ON cl.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = cl.relnamespace
  WHERE n.nspname = 'public'
    AND cl.relname = 'tasks'
    AND a.attnum > 0
    AND NOT a.attisdropped
  """

  # Derives the length-bounded varchar(255) columns straight from the live
  # database. Returns {scalar_fields, array_fields} as MapSets of schema field
  # atoms.
  defp bounded_varchar_255_columns do
    field_by_source = schema_field_by_source()
    %{rows: rows} = Repo.query!(@bounded_columns_sql, [])

    rows
    |> Enum.map(fn [name, type] -> {Map.get(field_by_source, name), type} end)
    |> Enum.reduce({MapSet.new(), MapSet.new()}, &classify_bounded_column/2)
  end

  defp classify_bounded_column({nil, _type}, acc), do: acc

  defp classify_bounded_column({field, "character varying(255)"}, {scalars, arrays}),
    do: {MapSet.put(scalars, field), arrays}

  defp classify_bounded_column({field, "character varying(255)[]"}, {scalars, arrays}),
    do: {scalars, MapSet.put(arrays, field)}

  defp classify_bounded_column({_field, _type}, acc), do: acc

  # The bounded scalar columns that a free-text length validator must cover:
  # everything length-bounded in the DB minus the documented exceptions.
  defp scalar_columns_requiring_validator(bounded_scalars) do
    excluded = MapSet.union(enum_backed_fields(), MapSet.new(@server_generated_varchar_255))
    MapSet.difference(bounded_scalars, excluded)
  end

  describe "varchar(255) validator coverage guard (W1412)" do
    # Regression guard for D81: every length-bounded varchar(255) column on the
    # `tasks` table must be covered by a changeset length validator, or oversized
    # input bypasses validation and raises a Postgrex 22001
    # (string_data_right_truncation) -> HTTP 500. The bounded column sets are
    # DERIVED from the live schema (never hardcoded), so a future varchar(255)
    # column added without the matching validator fails this guard.

    test "every length-bounded scalar varchar(255) column is in @varchar_255_fields" do
      {scalar_columns, _array_columns} = bounded_varchar_255_columns()
      required = scalar_columns_requiring_validator(scalar_columns)
      validated = MapSet.new(Task.varchar_255_fields())

      assert MapSet.equal?(required, validated), """
      @varchar_255_fields is out of sync with the database schema.
      Bounded scalar varchar(255) columns requiring a validator: #{inspect(Enum.sort(required))}
      @varchar_255_fields: #{inspect(Enum.sort(validated))}
      Missing a validator (add to @varchar_255_fields): #{inspect(Enum.sort(MapSet.difference(required, validated)))}
      Listed but not actually bounded (remove from @varchar_255_fields): #{inspect(Enum.sort(MapSet.difference(validated, required)))}
      """
    end

    test "every length-bounded varchar(255)[] array column is in @varchar_255_array_fields" do
      {_scalar_columns, array_columns} = bounded_varchar_255_columns()
      validated = MapSet.new(Task.varchar_255_array_fields())

      assert MapSet.equal?(array_columns, validated), """
      @varchar_255_array_fields is out of sync with the database schema.
      Bounded varchar(255)[] columns requiring a validator: #{inspect(Enum.sort(array_columns))}
      @varchar_255_array_fields: #{inspect(Enum.sort(validated))}
      Missing a validator (add to @varchar_255_array_fields): #{inspect(Enum.sort(MapSet.difference(array_columns, validated)))}
      Listed but not actually bounded (remove from @varchar_255_array_fields): #{inspect(Enum.sort(MapSet.difference(validated, array_columns)))}
      """
    end

    test "the guard fails when a bounded column lacks a validator" do
      # Proves the guard actually catches an unguarded column. :where_context is
      # a real, castable schema field stored as :text (unbounded). Simulating it
      # turning into a varchar(255) column — a bounded column added without being
      # added to @varchar_255_fields — must make the guard flag it.
      {scalar_columns, _array_columns} = bounded_varchar_255_columns()
      refute MapSet.member?(scalar_columns, :where_context)

      simulated = MapSet.put(scalar_columns, :where_context)
      required = scalar_columns_requiring_validator(simulated)
      validated = MapSet.new(Task.varchar_255_fields())

      refute MapSet.equal?(required, validated),
             "guard should fail when a bounded column is missing from @varchar_255_fields"

      missing = MapSet.difference(required, validated)

      assert MapSet.member?(missing, :where_context),
             "the unguarded :where_context column should be named as missing a validator"
    end
  end
end
