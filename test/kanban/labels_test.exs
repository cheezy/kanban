defmodule Kanban.LabelsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Labels
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    modifier = user_fixture()
    reader = user_fixture()
    outsider = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

    other_owner = user_fixture()
    other_board = board_fixture(other_owner)

    %{
      owner: owner,
      other_owner: other_owner,
      board: board,
      column: column_fixture(board),
      other_board: other_board,
      owner_scope: Scope.for_user(owner),
      modify_scope: Scope.for_user(modifier),
      read_only_scope: Scope.for_user(reader),
      outsider_scope: Scope.for_user(outsider)
    }
  end

  defp label_count, do: Repo.aggregate(Label, :count)

  defp task_label_ids(task) do
    TaskLabel
    |> where([tl], tl.task_id == ^task.id)
    |> select([tl], tl.label_id)
    |> Repo.all()
    |> Enum.sort()
  end

  describe "Label.colors/0" do
    test "returns the fixed list of colour token names" do
      assert Label.colors() == [
               :gray,
               :red,
               :orange,
               :yellow,
               :green,
               :teal,
               :blue,
               :purple,
               :pink
             ]
    end
  end

  describe "list_labels/2" do
    test "returns the board's labels ordered by name ignoring case", ctx do
      zeta = label_fixture(ctx.board, %{name: "zeta"})
      alpha = label_fixture(ctx.board, %{name: "Alpha"})
      beta = label_fixture(ctx.board, %{name: "beta"})

      ids = ctx.owner_scope |> Labels.list_labels(ctx.board) |> Enum.map(& &1.id)
      assert ids == [alpha.id, beta.id, zeta.id]
    end

    test "is readable by read-only and modify members", ctx do
      label = label_fixture(ctx.board)

      assert [%Label{id: id}] = Labels.list_labels(ctx.read_only_scope, ctx.board)
      assert id == label.id
      assert [%Label{id: ^id}] = Labels.list_labels(ctx.modify_scope, ctx.board)
    end

    test "returns [] to a user without access to the board", ctx do
      label_fixture(ctx.board)

      assert Labels.list_labels(ctx.outsider_scope, ctx.board) == []
    end

    test "returns [] for a nil scope or a scope without a user", ctx do
      label_fixture(ctx.board)

      assert Labels.list_labels(nil, ctx.board) == []
      assert Labels.list_labels(%Scope{user: nil}, ctx.board) == []
    end

    test "excludes labels from other boards the caller can also read", ctx do
      {:ok, _} =
        Boards.add_user_to_board(ctx.other_board, ctx.owner, :read_only, ctx.other_owner)

      label_fixture(ctx.other_board)
      own = label_fixture(ctx.board)

      assert [%Label{id: id}] = Labels.list_labels(ctx.owner_scope, ctx.board)
      assert id == own.id
    end
  end

  describe "list_viewable_labels/2" do
    test "returns the board's labels to members, ordered like list_labels/2", ctx do
      zeta = label_fixture(ctx.board, %{name: "zeta"})
      alpha = label_fixture(ctx.board, %{name: "Alpha"})

      for scope <- [ctx.owner_scope, ctx.modify_scope, ctx.read_only_scope] do
        assert scope |> Labels.list_viewable_labels(ctx.board) |> Enum.map(& &1.id) ==
                 [alpha.id, zeta.id]
      end
    end

    test "returns [] to a non-member of a private board", ctx do
      label_fixture(ctx.board)

      assert Labels.list_viewable_labels(ctx.outsider_scope, ctx.board) == []
    end

    test "returns the labels to a non-member of a public read-only board", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{read_only: true}, ctx.owner)
      label = label_fixture(board)

      assert [%Label{id: id}] = Labels.list_viewable_labels(ctx.outsider_scope, board)
      assert id == label.id
    end

    test "returns [] for a nil scope or a scope without a user", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{read_only: true}, ctx.owner)
      label_fixture(board)

      assert Labels.list_viewable_labels(nil, board) == []
      assert Labels.list_viewable_labels(%Scope{user: nil}, board) == []
    end

    test "excludes labels from other boards", ctx do
      {:ok, _} = Boards.update_board(ctx.other_board, %{read_only: true}, ctx.other_owner)
      label_fixture(ctx.other_board)
      own = label_fixture(ctx.board)

      assert [%Label{id: id}] = Labels.list_viewable_labels(ctx.owner_scope, ctx.board)
      assert id == own.id
    end
  end

  describe "create_label/3" do
    test "creates a label on the board for the owner", ctx do
      assert {:ok, %Label{} = label} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{name: "Bug", color: :red})

      assert label.board_id == ctx.board.id
      assert label.name == "Bug"
      assert label.color == :red
    end

    test "creates a label for a modify member and accepts a string colour", ctx do
      assert {:ok, %Label{color: :green}} =
               Labels.create_label(ctx.modify_scope, ctx.board, %{
                 "name" => "Feature",
                 "color" => "green"
               })
    end

    test "returns unauthorized for read-only members, outsiders and nil scopes", ctx do
      attrs = %{name: "Bug", color: :red}

      for scope <- [ctx.read_only_scope, ctx.outsider_scope, nil, %Scope{user: nil}] do
        assert {:error, :unauthorized} = Labels.create_label(scope, ctx.board, attrs)
      end

      assert label_count() == 0
    end

    test "trims the name before saving", ctx do
      assert {:ok, %Label{name: "Bug"}} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{name: "  Bug  ", color: :red})
    end

    test "rejects a duplicate name differing only in case or whitespace on the same board",
         ctx do
      label_fixture(ctx.board, %{name: "Bug"})

      for name <- ["bug", "  BUG "] do
        assert {:error, changeset} =
                 Labels.create_label(ctx.owner_scope, ctx.board, %{name: name, color: :red})

        assert "has already been taken" in errors_on(changeset).name
      end
    end

    test "allows the same name on another board", ctx do
      label_fixture(ctx.other_board, %{name: "Bug"})

      assert {:ok, %Label{}} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{name: "bug", color: :red})
    end

    test "limits the name to 40 characters", ctx do
      assert {:ok, %Label{}} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{
                 name: String.duplicate("a", 40),
                 color: :red
               })

      assert {:error, changeset} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{
                 name: String.duplicate("b", 41),
                 color: :red
               })

      assert "should be at most 40 character(s)" in errors_on(changeset).name
    end

    test "requires a name and a colour", ctx do
      assert {:error, changeset} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{name: "   "})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.color
    end

    test "rejects a colour outside the fixed token list", ctx do
      assert {:error, changeset} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{name: "Bug", color: "magenta"})

      assert "is invalid" in errors_on(changeset).color

      assert {:error, changeset} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{
                 name: "Bug",
                 color: "#ff0000"
               })

      assert "is invalid" in errors_on(changeset).color
    end

    test "ignores a board_id in the attributes", ctx do
      assert {:ok, %Label{} = label} =
               Labels.create_label(ctx.owner_scope, ctx.board, %{
                 name: "Bug",
                 color: :red,
                 board_id: ctx.other_board.id
               })

      assert label.board_id == ctx.board.id
    end
  end

  describe "change_label/2" do
    test "returns a label changeset, defaulting to a new label" do
      assert %Ecto.Changeset{data: %Label{id: nil}, valid?: false} = Labels.change_label()

      label = %Label{name: "Bug", color: :red}
      changeset = Labels.change_label(label, %{name: "  Defect  "})

      assert changeset.data == label
      assert Ecto.Changeset.get_change(changeset, :name) == "Defect"
    end
  end

  describe "update_label/3" do
    test "updates the name and colour for the owner and a modify member", ctx do
      label = label_fixture(ctx.board, %{name: "Bug", color: :red})

      assert {:ok, %Label{name: "Defect", color: :orange} = label} =
               Labels.update_label(ctx.owner_scope, label, %{name: "Defect", color: :orange})

      assert {:ok, %Label{name: "Issue", color: :yellow}} =
               Labels.update_label(ctx.modify_scope, label, %{name: "Issue", color: :yellow})
    end

    test "returns unauthorized for read-only members and outsiders", ctx do
      label = label_fixture(ctx.board, %{name: "Bug", color: :red})

      for scope <- [ctx.read_only_scope, ctx.outsider_scope] do
        assert {:error, :unauthorized} = Labels.update_label(scope, label, %{name: "Changed"})
      end

      assert %Label{name: "Bug"} = Repo.get!(Label, label.id)
    end

    test "rejects renaming to a case-variant of a sibling label's name", ctx do
      label_fixture(ctx.board, %{name: "Bug"})
      label = label_fixture(ctx.board, %{name: "Feature"})

      assert {:error, changeset} = Labels.update_label(ctx.owner_scope, label, %{name: "BUG"})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "allows changing the case of the label's own name", ctx do
      label = label_fixture(ctx.board, %{name: "Bug"})

      assert {:ok, %Label{name: "BUG"}} =
               Labels.update_label(ctx.owner_scope, label, %{name: "BUG"})
    end

    test "clearing the name returns a blank error instead of raising", ctx do
      label = label_fixture(ctx.board, %{name: "Bug"})

      assert {:error, changeset} = Labels.update_label(ctx.owner_scope, label, %{name: ""})
      assert "can't be blank" in errors_on(changeset).name
      assert %Label{name: "Bug"} = Repo.get!(Label, label.id)
    end

    test "a label deleted since it was loaded returns an :id error instead of raising", ctx do
      label = label_fixture(ctx.board, %{name: "Bug"})
      Repo.delete!(label)

      assert {:error, changeset} = Labels.update_label(ctx.owner_scope, label, %{name: "Defect"})
      assert Keyword.has_key?(changeset.errors, :id)
    end

    test "cannot move a label to another board", ctx do
      label = label_fixture(ctx.board)

      assert {:ok, %Label{} = updated} =
               Labels.update_label(ctx.owner_scope, label, %{board_id: ctx.other_board.id})

      assert updated.board_id == ctx.board.id
    end
  end

  describe "delete_label/2" do
    test "deletes a label for the owner and a modify member", ctx do
      first = label_fixture(ctx.board)
      second = label_fixture(ctx.board)

      assert {:ok, %Label{}} = Labels.delete_label(ctx.owner_scope, first)
      assert {:ok, %Label{}} = Labels.delete_label(ctx.modify_scope, second)
      assert label_count() == 0
    end

    test "returns unauthorized for read-only members and outsiders", ctx do
      label = label_fixture(ctx.board)

      for scope <- [ctx.read_only_scope, ctx.outsider_scope] do
        assert {:error, :unauthorized} = Labels.delete_label(scope, label)
      end

      assert Repo.get(Label, label.id)
    end

    test "removes the label's task_labels rows but never the tasks", ctx do
      doomed = label_fixture(ctx.board)
      kept = label_fixture(ctx.board)
      task_one = task_fixture(ctx.column)
      task_two = task_fixture(ctx.column)

      {:ok, _} = Labels.set_task_labels(ctx.owner_scope, task_one, [doomed.id, kept.id])
      {:ok, _} = Labels.set_task_labels(ctx.owner_scope, task_two, [doomed.id])

      assert {:ok, _} = Labels.delete_label(ctx.owner_scope, doomed)

      assert Repo.get(Task, task_one.id)
      assert Repo.get(Task, task_two.id)
      assert task_label_ids(task_one) == [kept.id]
      assert task_label_ids(task_two) == []
    end
  end

  describe ":labels_changed broadcast" do
    setup ctx do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")
      :ok
    end

    test "create, update and delete each broadcast the board id once they commit", ctx do
      board_id = ctx.board.id

      {:ok, label} = Labels.create_label(ctx.owner_scope, ctx.board, %{name: "Bug", color: :red})
      assert_receive {Labels, :labels_changed, ^board_id}

      {:ok, label} = Labels.update_label(ctx.modify_scope, label, %{color: :purple})
      assert_receive {Labels, :labels_changed, ^board_id}

      {:ok, _} = Labels.delete_label(ctx.owner_scope, label)
      assert_receive {Labels, :labels_changed, ^board_id}
    end

    test "an unauthorized or invalid write broadcasts nothing", ctx do
      label = label_fixture(ctx.board, %{name: "Bug"})

      assert {:error, :unauthorized} =
               Labels.create_label(ctx.read_only_scope, ctx.board, %{name: "X", color: :red})

      assert {:error, :unauthorized} =
               Labels.update_label(ctx.outsider_scope, label, %{name: "Y"})

      assert {:error, :unauthorized} = Labels.delete_label(ctx.read_only_scope, label)

      assert {:error, %Ecto.Changeset{}} =
               Labels.update_label(ctx.owner_scope, label, %{name: ""})

      Repo.delete!(label)
      assert {:error, %Ecto.Changeset{}} = Labels.delete_label(ctx.owner_scope, label)

      refute_receive {Labels, :labels_changed, _}, 50
    end

    test "a label change on another board is not broadcast on this one", ctx do
      other_scope = Scope.for_user(ctx.other_owner)

      {:ok, _} =
        Labels.create_label(other_scope, ctx.other_board, %{name: "Elsewhere", color: :red})

      refute_receive {Labels, :labels_changed, _}, 50
    end
  end

  describe "delete_label/2 on an already-deleted label" do
    test "returns an :id error instead of raising", ctx do
      label = label_fixture(ctx.board, %{name: "Bug"})
      Repo.delete!(label)

      assert {:error, changeset} = Labels.delete_label(ctx.owner_scope, label)
      assert Keyword.has_key?(changeset.errors, :id)
    end
  end

  describe "set_task_labels/3" do
    setup ctx do
      %{
        task: task_fixture(ctx.column),
        a: label_fixture(ctx.board),
        b: label_fixture(ctx.board),
        c: label_fixture(ctx.board)
      }
    end

    test "sets the task's labels and returns the task with them preloaded", ctx do
      assert {:ok, %Task{labels: labels}} =
               Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id, ctx.b.id])

      assert labels |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([ctx.a.id, ctx.b.id])
      assert task_label_ids(ctx.task) == Enum.sort([ctx.a.id, ctx.b.id])
    end

    test "replaces the existing label set", ctx do
      {:ok, _} = Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id, ctx.b.id])

      assert {:ok, _} =
               Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.b.id, ctx.c.id])

      assert task_label_ids(ctx.task) == Enum.sort([ctx.b.id, ctx.c.id])
    end

    test "an empty list clears all labels", ctx do
      {:ok, _} = Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id, ctx.b.id])

      assert {:ok, %Task{labels: []}} = Labels.set_task_labels(ctx.owner_scope, ctx.task, [])
      assert task_label_ids(ctx.task) == []
    end

    test "broadcasts :task_updated on the board topic after the write commits", ctx do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")
      task_id = ctx.task.id

      {:ok, _} = Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id])

      assert_receive {Kanban.Tasks, :task_updated, %Task{id: ^task_id, labels: [label]}}
      assert label.id == ctx.a.id
    end

    test "a rejected write broadcasts nothing", ctx do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      assert {:error, :unauthorized} =
               Labels.set_task_labels(ctx.read_only_scope, ctx.task, [ctx.a.id])

      refute_receive {Kanban.Tasks, :task_updated, _}, 50
    end

    test "collapses duplicate ids into one row", ctx do
      assert {:ok, %Task{labels: [_]}} =
               Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id, ctx.a.id])

      assert task_label_ids(ctx.task) == [ctx.a.id]
    end

    test "works for a modify member", ctx do
      assert {:ok, _} = Labels.set_task_labels(ctx.modify_scope, ctx.task, [ctx.a.id])
      assert task_label_ids(ctx.task) == [ctx.a.id]
    end

    test "rejects a label id from another board and leaves the set unchanged", ctx do
      foreign = label_fixture(ctx.other_board)
      {:ok, _} = Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id])

      assert {:error, :invalid_labels} =
               Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.b.id, foreign.id])

      assert task_label_ids(ctx.task) == [ctx.a.id]
    end

    test "a task deleted since it was loaded returns :not_found instead of raising", ctx do
      {:ok, _} = Kanban.Tasks.delete_task(ctx.task)

      assert {:error, :not_found} = Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id])
    end

    test "a label deleted since it was chosen is rejected, not raised as a foreign-key error",
         ctx do
      {:ok, _} = Labels.delete_label(ctx.owner_scope, ctx.b)

      assert {:error, :invalid_labels} =
               Labels.set_task_labels(ctx.owner_scope, ctx.task, [ctx.a.id, ctx.b.id])

      assert task_label_ids(ctx.task) == []
    end

    test "rejects nonexistent and non-integer ids with the same error", ctx do
      missing_id = ctx.c.id + 1_000_000

      assert {:error, :invalid_labels} =
               Labels.set_task_labels(ctx.owner_scope, ctx.task, [missing_id])

      assert {:error, :invalid_labels} =
               Labels.set_task_labels(ctx.owner_scope, ctx.task, [to_string(ctx.a.id)])

      assert task_label_ids(ctx.task) == []
    end

    test "returns unauthorized for read-only members, outsiders and nil scopes", ctx do
      foreign = label_fixture(ctx.other_board)

      for scope <- [ctx.read_only_scope, ctx.outsider_scope, nil],
          ids <- [[ctx.a.id], [foreign.id]] do
        assert {:error, :unauthorized} = Labels.set_task_labels(scope, ctx.task, ids)
      end

      assert task_label_ids(ctx.task) == []
    end

    test "loads the task's column when it is not preloaded", ctx do
      task = Repo.get!(Task, ctx.task.id)
      refute Ecto.assoc_loaded?(task.column)

      assert {:ok, _} = Labels.set_task_labels(ctx.owner_scope, task, [ctx.a.id])
      assert task_label_ids(task) == [ctx.a.id]
    end
  end

  describe "list_task_label_ids/2 (W2234)" do
    setup ctx do
      task = task_fixture(ctx.column)
      a = label_fixture(ctx.board)
      b = label_fixture(ctx.board)
      {:ok, _} = Labels.set_task_labels(ctx.owner_scope, task, [b.id, a.id])

      %{task: task, a: a, b: b}
    end

    test "returns the task's label ids to any board member", ctx do
      expected = Enum.sort([ctx.a.id, ctx.b.id])

      assert Labels.list_task_label_ids(ctx.owner_scope, ctx.task) == expected
      assert Labels.list_task_label_ids(ctx.modify_scope, ctx.task) == expected
      assert Labels.list_task_label_ids(ctx.read_only_scope, ctx.task) == expected
    end

    test "returns [] to a non-member, a nil scope and a scope that is not a %Scope{}", ctx do
      assert Labels.list_task_label_ids(ctx.outsider_scope, ctx.task) == []
      assert Labels.list_task_label_ids(nil, ctx.task) == []
      assert Labels.list_task_label_ids(%{user: ctx.owner}, ctx.task) == []
    end

    test "returns [] for an unlabelled task and an unsaved task", ctx do
      assert Labels.list_task_label_ids(ctx.owner_scope, task_fixture(ctx.column)) == []
      assert Labels.list_task_label_ids(ctx.owner_scope, %Task{}) == []
    end
  end

  describe "resolve_label_names/3 (W2239)" do
    test "matches trimmed names case-insensitively and returns ids in request order", ctx do
      bug = label_fixture(ctx.board, %{name: "Bug"})
      docs = label_fixture(ctx.board, %{name: "Docs"})

      assert Labels.resolve_label_names(ctx.owner_scope, ctx.board, [" docs ", "BUG"]) ==
               {:ok, [docs.id, bug.id]}
    end

    test "collapses duplicates and case variants to their first occurrence", ctx do
      bug = label_fixture(ctx.board, %{name: "Bug"})

      assert Labels.resolve_label_names(ctx.owner_scope, ctx.board, ["bug", "Bug", " BUG"]) ==
               {:ok, [bug.id]}
    end

    test "an empty list resolves to no ids", ctx do
      assert Labels.resolve_label_names(ctx.owner_scope, ctx.board, []) == {:ok, []}
    end

    test "lists every unknown name, trimmed and de-duplicated, in request order", ctx do
      label_fixture(ctx.board, %{name: "Bug"})

      assert Labels.resolve_label_names(ctx.owner_scope, ctx.board, [
               "Zed ",
               "Bug",
               "alpha",
               "zed"
             ]) == {:error, {:unknown_labels, ["Zed", "alpha"]}}
    end

    test "another board's label is reported exactly like a nonexistent one", ctx do
      label_fixture(ctx.other_board, %{name: "Secret"})

      elsewhere = Labels.resolve_label_names(ctx.owner_scope, ctx.board, ["Secret"])
      nowhere = Labels.resolve_label_names(ctx.owner_scope, ctx.board, ["Nowhere"])

      assert elsewhere == {:error, {:unknown_labels, ["Secret"]}}
      assert nowhere == {:error, {:unknown_labels, ["Nowhere"]}}
    end

    test "read-only members resolve; outsiders and nil scopes resolve nothing", ctx do
      bug = label_fixture(ctx.board, %{name: "Bug"})

      assert Labels.resolve_label_names(ctx.read_only_scope, ctx.board, ["Bug"]) ==
               {:ok, [bug.id]}

      for scope <- [ctx.outsider_scope, nil, %Scope{user: nil}] do
        assert Labels.resolve_label_names(scope, ctx.board, ["Bug"]) ==
                 {:error, {:unknown_labels, ["Bug"]}}
      end
    end

    test "prefers an exact-case match when two names fold together", ctx do
      # Postgres lower() under a "C" ctype folds only ASCII, so "Éclair" and
      # "éclair" can coexist on one board while String.downcase/1 folds both
      # to "éclair". Where the database folds them too, the second insert hits
      # the unique index and there is no collision to resolve.
      upper = label_fixture(ctx.board, %{name: "Éclair"})

      case %Label{board_id: ctx.board.id}
           |> Label.changeset(%{name: "éclair", color: :red})
           |> Repo.insert() do
        {:ok, lower} ->
          assert Labels.resolve_label_names(ctx.owner_scope, ctx.board, ["éclair"]) ==
                   {:ok, [lower.id]}

          assert Labels.resolve_label_names(ctx.owner_scope, ctx.board, ["Éclair"]) ==
                   {:ok, [upper.id]}

        {:error, _changeset} ->
          assert Labels.resolve_label_names(ctx.owner_scope, ctx.board, ["éclair"]) ==
                   {:ok, [upper.id]}
      end
    end
  end
end
