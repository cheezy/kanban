defmodule KanbanWeb.DemoBoardTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.DemoBoard

  defp all_cards(board), do: board.columns |> Map.values() |> List.flatten()

  describe "script/0 and initial_board/0" do
    test "the script is not empty and every step names a known card, agent and column" do
      cards = DemoBoard.initial_board() |> all_cards()

      refute Enum.empty?(DemoBoard.script())

      for step <- DemoBoard.script() do
        assert step.card in cards
        assert step.to in DemoBoard.columns()
        assert %{kind: :agent} = DemoBoard.agent(step.agent)
        assert step.result in [:passed, :failed]
        assert step.hook in ["before_doing", "after_doing", "after_review"]
      end
    end

    test "the initial board holds each card exactly once" do
      cards = DemoBoard.initial_board() |> all_cards()

      assert Enum.sort(cards) == cards |> Enum.sort() |> Enum.uniq()

      assert Map.keys(DemoBoard.initial_board().columns) |> Enum.sort() ==
               Enum.sort(DemoBoard.columns())
    end

    test "new/0 starts at the first step with an empty feed" do
      assert DemoBoard.new() == %{index: 0, board: DemoBoard.initial_board(), events: []}
    end
  end

  describe "apply_step/2" do
    test "moves the card to the head of the target column and records the agent" do
      # W103 is not a goal's child, so no goal moves with it.
      board =
        DemoBoard.apply_step(DemoBoard.initial_board(), %{
          card: "W103",
          agent: :cursor,
          to: :doing
        })

      assert board.columns.doing == ["W103", "W104", "W102"]
      refute "W103" in board.columns.ready
      assert board.agents["W103"] == :cursor
    end

    test "leaves a card in place when the step's column is the one it is in" do
      # W103 joins Doing ahead of W104, so W104 is not at the head: a move
      # would reorder the column, staying put leaves it as it is.
      board =
        DemoBoard.apply_step(DemoBoard.initial_board(), %{
          card: "W103",
          agent: :cursor,
          to: :doing
        })

      after_step = DemoBoard.apply_step(board, %{card: "W104", agent: :cursor, to: :doing})

      assert board.columns.doing == ["W103", "W104", "W102"]
      assert after_step.columns == board.columns
    end
  end

  describe "advance/1" do
    test "applies the steps in order, keeping every card on the board exactly once" do
      count = length(DemoBoard.script())

      final =
        Enum.reduce(1..count, DemoBoard.new(), fn _, replay ->
          next = DemoBoard.advance(replay)
          cards = all_cards(next.board)
          assert length(cards) == length(Enum.uniq(cards))
          assert length(cards) == length(all_cards(DemoBoard.initial_board()))
          next
        end)

      assert final.index == count
      assert hd(final.events) == List.last(DemoBoard.script())
      assert length(final.events) == 4
    end

    test "after the last step the replay starts again from the initial board" do
      count = length(DemoBoard.script())
      last = Enum.reduce(1..count, DemoBoard.new(), fn _, replay -> DemoBoard.advance(replay) end)

      assert DemoBoard.advance(last) == DemoBoard.new()
    end
  end

  describe "cards_in/2" do
    test "shows the agent as the claimant in Doing and as the completer in Done" do
      board = DemoBoard.initial_board()

      assert [
               %{identifier: "W104", claimed_by: %{name: "Cursor"}, completed_by: nil},
               %{identifier: "W102", claimed_by: %{name: "Codex"}, completed_by: nil}
             ] = DemoBoard.cards_in(board, :doing)

      assert [
               %{identifier: "W100", claimed_by: nil, completed_by: %{name: "Claude"}} = done,
               %{identifier: "D106", type: :defect, completed_by: %{name: "Codex"}}
             ] = DemoBoard.cards_in(board, :done)

      assert done.files_changed_count == 3
      assert done.type == :work
    end

    test "task_count/2 counts the task cards in a column and leaves out the goal" do
      board = DemoBoard.initial_board()

      assert "G10" in board.columns.ready
      assert DemoBoard.task_count(board, :ready) == 2
      assert DemoBoard.task_count(board, :backlog) == 1
      assert DemoBoard.task_count(board, :done) == 2
    end

    test "a card no agent has touched carries only its author" do
      assert [%{author: %{kind: :human}, claimed_by: nil, completed_by: nil}] =
               DemoBoard.cards_in(DemoBoard.initial_board(), :backlog)
    end
  end

  describe "the goal" do
    defp column_of(board, card),
      do: Enum.find(DemoBoard.columns(), &(card in board.columns[&1]))

    test "starts in the column of its leftmost child, two of its five children done" do
      board = DemoBoard.initial_board()

      assert column_of(board, "G10") == :ready
      assert DemoBoard.goal_column(board.columns, "G10") == :ready
      assert hd(board.columns.ready) == "G10"

      assert DemoBoard.goal_flow(board, "G10") ==
               %{backlog: 0, ready: 1, doing: 2, review: 0, done: 2, total: 5}
    end

    test "changes column in the same move as the child that drives it" do
      # The goal's column after each move of the script, and the move number.
      columns =
        DemoBoard.script()
        |> Enum.scan(DemoBoard.initial_board(), &DemoBoard.apply_step(&2, &1))
        |> Enum.map(&column_of(&1, "G10"))

      assert columns ==
               [:doing, :doing, :doing, :doing, :review, :review, :review, :review, :done, :done]

      assert Enum.at(DemoBoard.script(), 0).card == "W101"
      assert Enum.at(DemoBoard.script(), 4).card == "W101"
      assert Enum.at(DemoBoard.script(), 8).card == "W101"
    end

    test "moves to the head of its new column, and only when it moves" do
      board =
        DemoBoard.apply_step(DemoBoard.initial_board(), %{
          card: "W101",
          agent: :claude,
          to: :doing
        })

      assert board.columns.doing == ["G10", "W101", "W104", "W102"]
      refute "G10" in board.columns.ready

      # W104 moving to Review leaves the goal in Doing, where it already is.
      after_step = DemoBoard.apply_step(board, %{card: "W104", agent: :cursor, to: :review})
      assert after_step.columns.doing == ["G10", "W101", "W102"]
    end

    test "the strip's flow follows the replay and resets with it" do
      flow = fn replay -> replay.board |> DemoBoard.goals() |> hd() |> Map.fetch!(:flow) end
      start = DemoBoard.new()

      assert flow.(start) == %{backlog: 0, ready: 1, doing: 2, review: 0, done: 2, total: 5}

      assert start |> DemoBoard.advance() |> flow.() ==
               %{backlog: 0, ready: 0, doing: 3, review: 0, done: 2, total: 5}

      last =
        Enum.reduce(DemoBoard.script(), start, fn _, replay -> DemoBoard.advance(replay) end)

      assert flow.(last) == %{backlog: 0, ready: 0, doing: 0, review: 0, done: 5, total: 5}
      assert last |> DemoBoard.advance() |> flow.() == flow.(start)
    end

    test "goals/1 gives the strip a promoted goal with a translated name" do
      assert [%{identifier: "G10", promoted: true, name: name}] =
               DemoBoard.goals(DemoBoard.initial_board())

      assert name == DemoBoard.card_title("G10")

      Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
        assert [%{name: translated}] = DemoBoard.goals(DemoBoard.initial_board())
        refute translated == name
      end)
    end

    test "the goal card carries its children's progress and no promote button" do
      assert [goal | _] = DemoBoard.cards_in(DemoBoard.initial_board(), :ready)

      assert %{identifier: "G10", type: :goal, promoted: true} = goal
      assert goal.children == %{done: 2, review: 0, doing: 2, ready: 1, total: 5}
    end

    test "a child carries its goal's chip and any other card carries none" do
      board = DemoBoard.initial_board()
      cards = Enum.flat_map(DemoBoard.columns(), &DemoBoard.cards_in(board, &1))
      by_id = Map.new(cards, &{&1.identifier, &1})

      for child <- ~w(W100 W101 W102 W104 D106) do
        assert %{identifier: "G10", short: short} = by_id[child].goal
        assert short == DemoBoard.card_title("G10")
      end

      assert by_id["W103"].goal == nil
      assert by_id["W105"].goal == nil
    end
  end

  describe "text" do
    test "every column and card has a name, and every event a sentence" do
      for column <- DemoBoard.columns(), do: assert(DemoBoard.column_name(column) != "")

      for card <- DemoBoard.initial_board() |> all_cards(),
          do: assert(DemoBoard.card_title(card) != "")

      for step <- DemoBoard.script() do
        assert DemoBoard.card_title(step.card) != ""
        assert DemoBoard.describe(step) =~ step.card
        assert DemoBoard.describe(step) =~ DemoBoard.agent(step.agent).name
      end
    end

    test "each event kind reads differently" do
      sentences =
        for event <- [:claim, :submit, :finish, :hook_failed],
            do: DemoBoard.describe(%{event: event, card: "W101", agent: :claude})

      assert length(Enum.uniq(sentences)) == 4
    end

    test "hook results are labelled" do
      assert DemoBoard.result_label(:passed) == "passed"
      assert DemoBoard.result_label(:failed) == "failed"
    end

    test "an absent agent is nil" do
      assert DemoBoard.agent(nil) == nil
    end

    test "every locale gives the five columns five distinct names" do
      for locale <- ~w(de en es fr ja pt zh) do
        names =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            Enum.map(DemoBoard.columns(), &DemoBoard.column_name/1)
          end)

        assert length(Enum.uniq(names)) == 5, "#{locale}: #{inspect(names)}"
        if locale not in ~w(en de fr), do: refute("Ready" in names, locale)
      end
    end

    test "text follows the current locale" do
      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        refute DemoBoard.card_title("W101") == "Add a dark mode toggle to settings"
        refute DemoBoard.column_name(:done) == "Done"
      end)
    end
  end
end
