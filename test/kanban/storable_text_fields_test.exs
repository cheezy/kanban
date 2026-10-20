defmodule Kanban.StorableTextFieldsTest do
  @moduledoc """
  D383: every changeset that casts user-entered text refuses a NUL byte or
  invalid UTF-8 on the field itself, through `Kanban.ChangesetText`, instead of
  letting Postgres raise. One NUL value and one invalid-UTF-8 value per field.
  """
  use Kanban.DataCase, async: true

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards.Board
  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Messages.Message
  alias Kanban.Organizations.Organization
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Workspaces.Invitation

  @message "contains characters that are not allowed"
  @nul <<"bad", 0, "text">>
  @invalid <<"bad", 0xFF, "text">>
  @bad_values [{"a NUL byte", @nul}, {"invalid UTF-8", @invalid}]

  # Runs `build` with each bad value and asserts the error lands on `field`.
  defp assert_refused(field, build, message \\ @message) do
    for {label, value} <- @bad_values do
      changeset = build.(value)
      refute changeset.valid?, "#{field} accepted #{label}"
      errors = changeset |> errors_on() |> Map.get(field, [])
      assert message in errors, "#{field} with #{label} gave #{inspect(errors_on(changeset))}"
    end
  end

  describe "Board" do
    test "changeset/2 and owner_changeset/2 refuse bad bytes in name and description" do
      for fun <- [&Board.changeset/2, &Board.owner_changeset/2], field <- [:name, :description] do
        assert_refused(field, fn value -> fun.(%Board{}, %{field => value}) end)
      end
    end
  end

  describe "Column" do
    test "changeset/2 refuses bad bytes in name" do
      assert_refused(:name, &Column.changeset(%Column{}, %{name: &1, position: 0}))
    end
  end

  describe "Label" do
    test "changeset/2 refuses bad bytes in name" do
      assert_refused(:name, &Label.changeset(%Label{}, %{name: &1, color: :red}))
    end
  end

  describe "Organization" do
    test "changeset/2 refuses bad bytes in every text field" do
      for field <- Keyword.keys(Organization.max_lengths()) do
        assert_refused(field, &Organization.changeset(%Organization{}, %{field => &1}))
      end
    end
  end

  describe "Message" do
    test "changeset/2 refuses bad bytes in title and body" do
      for field <- [:title, :body] do
        assert_refused(field, &Message.changeset(%Message{}, %{field => &1}))
      end
    end
  end

  describe "DeliveryTarget" do
    test "changeset/2 refuses bad bytes in name and description" do
      for field <- [:name, :description] do
        assert_refused(field, &DeliveryTarget.changeset(%DeliveryTarget{}, %{field => &1}))
      end
    end
  end

  describe "ApiToken" do
    test "changeset/2 and workspace_changeset/2 refuse bad bytes in every text field" do
      for fun <- [&ApiToken.changeset/2, &ApiToken.workspace_changeset/2],
          field <- [:name, :agent_model, :agent_version, :agent_purpose] do
        assert_refused(field, fn value -> fun.(%ApiToken{}, %{field => value}) end)
      end

      for fun <- [&ApiToken.changeset/2, &ApiToken.workspace_changeset/2] do
        assert_refused(:agent_capabilities, fn value ->
          fun.(%ApiToken{}, %{agent_capabilities: ["code_generation", value]})
        end)
      end
    end
  end

  describe "User" do
    test "registration_changeset/3 and email_changeset/3 refuse bad bytes in name and email" do
      for fun <- [&User.registration_changeset/3, &User.email_changeset/3],
          field <- [:name, :email] do
        assert_refused(field, fn value ->
          fun.(%User{}, %{field => value}, validate_unique: false)
        end)
      end
    end

    test "name_changeset/2 refuses bad bytes in name" do
      assert_refused(:name, &User.name_changeset(%User{}, %{name: &1}))
    end
  end

  describe "Invitation" do
    test "workspace_changeset/1 and board_changeset/1 refuse bad bytes in email" do
      assert_refused(:email, &Invitation.workspace_changeset(%{email: &1, role: :member}))
      assert_refused(:email, &Invitation.board_changeset(%{email: &1, board_access: :read_only}))
    end
  end

  describe "REST writers that bypass the schema changesets" do
    test "Tasks.update_changed_files/2 refuses bad bytes anywhere in an entry" do
      user = Kanban.AccountsFixtures.user_fixture()
      board = Kanban.BoardsFixtures.board_fixture(user)
      column = Kanban.ColumnsFixtures.column_fixture(board)
      task = Kanban.TasksFixtures.task_fixture(column)

      for {label, value} <- @bad_values,
          entry <- [
            %{"path" => "lib/a.ex", "diff" => value},
            %{"path" => value, "diff" => "@@"},
            %{value => "extra key", "path" => "lib/a.ex"}
          ] do
        assert {:error, changeset} = Kanban.Tasks.update_changed_files(task, [entry])
        assert %{changed_files: [@message]} = errors_on(changeset), label
      end

      assert {:ok, _} =
               Kanban.Tasks.update_changed_files(task, [%{"path" => "lib/a.ex", "diff" => "ok"}])
    end

    test "the after_goal report refuses an output it cannot store" do
      for {_label, value} <- @bad_values do
        assert {:error, :unstorable_after_goal_output} =
                 KanbanWeb.API.TaskTransitions.validate_after_goal_result(%{
                   "exit_code" => 0,
                   "output" => value,
                   "duration_ms" => 1
                 })
      end

      assert {:ok, %{"output" => "line one\nline two\ttab"}} =
               KanbanWeb.API.TaskTransitions.validate_after_goal_result(%{
                 "exit_code" => 0,
                 "output" => "line one\nline two\ttab",
                 "duration_ms" => 1
               })
    end
  end

  describe "TaskComment" do
    test "changeset/2 refuses bad bytes in content with its own message" do
      assert_refused(
        :content,
        &TaskComment.changeset(%TaskComment{task_id: 1}, %{content: &1}),
        "is invalid"
      )
    end

    test "put_author_agent_name/2 refuses bad bytes with its own message" do
      assert_refused(
        :author_agent_name,
        fn value ->
          %TaskComment{task_id: 1}
          |> TaskComment.changeset(%{content: "Hi"})
          |> TaskComment.put_author_agent_name(value)
        end,
        "is invalid"
      )
    end
  end

  describe "Task" do
    @string_fields ~w(title description acceptance_criteria why what where_context
                      patterns_to_follow estimated_files database_changes validation_rules
                      telemetry_event metrics_to_track logging_requirements
                      error_user_message error_on_failure)a

    @array_fields ~w(technology_requirements pitfalls out_of_scope security_considerations
                     dependencies)a

    @map_fields ~w(testing_strategy integration_points technical_details)a

    @pipelines [
      {"changeset/2", &Task.changeset/2},
      {"api_create_changeset/2", &Task.api_create_changeset/2},
      {"api_update_changeset/2", &Task.api_update_changeset/2}
    ]

    test "every pipeline refuses bad bytes in each string field" do
      for {_name, fun} <- @pipelines, field <- @string_fields do
        assert_refused(field, fn value -> fun.(%Task{}, %{field => value}) end)
      end
    end

    test "every pipeline refuses bad bytes inside each array field" do
      for {_name, fun} <- @pipelines, field <- @array_fields do
        assert_refused(field, fn value -> fun.(%Task{}, %{field => ["fine", value]}) end)
      end
    end

    test "every pipeline refuses bad bytes nested inside each map field" do
      for {_name, fun} <- @pipelines, field <- @map_fields do
        assert_refused(field, fn value ->
          fun.(%Task{}, %{field => %{"unit_tests" => ["fine", value]}})
        end)
      end
    end

    test "changeset/2 refuses bad bytes in the agent-written and review fields" do
      for field <- ~w(completion_summary completion_notes completed_by_agent
                      actual_files_changed review_notes review_report)a do
        assert_refused(field, &Task.changeset(%Task{}, %{field => &1}))
      end

      for field <- ~w(workflow_steps changed_files)a do
        assert_refused(field, &Task.changeset(%Task{}, %{field => [%{"name" => &1}]}))
      end

      for field <- ~w(explorer_result reviewer_result)a do
        assert_refused(field, &Task.changeset(%Task{}, %{field => %{"summary" => &1}}))
      end
    end

    test "archive_changeset/2 refuses bad bytes in archive_note" do
      assert_refused(
        :archive_note,
        &Task.archive_changeset(%Task{}, %{archive_reason: :wontdo, archive_note: &1})
      )
    end

    test "every pipeline refuses bad bytes in key_files, on the embedded field" do
      for {_name, fun} <- @pipelines, {label, value} <- @bad_values do
        changeset =
          fun.(%Task{}, %{
            key_files: [%{"file_path" => "lib/a.ex", "note" => value, "position" => 0}]
          })

        assert %{key_files: [%{note: [@message]}]} = errors_on(changeset), label
      end

      changeset =
        Task.changeset(%Task{}, %{
          key_files: [%{"file_path" => @invalid, "position" => 0}]
        })

      assert %{key_files: [%{file_path: [@message]}]} = errors_on(changeset)
    end

    test "every pipeline refuses bad bytes in verification_steps, on the embedded field" do
      for {_name, fun} <- @pipelines,
          field <- ~w(step_text expected_result step_type),
          {label, value} <- @bad_values do
        step =
          Map.put(
            %{"step_type" => "command", "step_text" => "mix test", "position" => 0},
            field,
            value
          )

        changeset = fun.(%Task{}, %{verification_steps: [step]})
        assert %{verification_steps: [errors]} = errors_on(changeset)

        assert @message in Map.get(errors, String.to_existing_atom(field), []),
               "#{field} with #{label} gave #{inspect(errors)}"
      end
    end

    test "every pipeline refuses bad bytes in behaviour_test_matrix rows, on the row field" do
      base = %{
        "category" => "Happy path",
        "behaviour" => "It works",
        "test_name" => "test/a_test.exs",
        "type" => "unit",
        "status" => "planned",
        "position" => 0
      }

      for {_name, fun} <- @pipelines,
          field <- ~w(category behaviour test_name type status na_reason),
          {label, value} <- @bad_values do
        changeset = fun.(%Task{}, %{behaviour_test_matrix: [Map.put(base, field, value)]})
        assert %{behaviour_test_matrix: [errors]} = errors_on(changeset)

        assert @message in Map.get(errors, String.to_existing_atom(field), []),
               "#{field} with #{label} gave #{inspect(errors)}"
      end
    end
  end
end
