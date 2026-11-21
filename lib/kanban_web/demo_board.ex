defmodule KanbanWeb.DemoBoard do
  @moduledoc """
  The sample board and move script behind the public `/demo` replay
  (`KanbanWeb.DemoBoardLive`).

  Everything here is static: there is no database, no real board and no
  real user. The board is a map of column atoms to card identifiers, and
  the script is an ordered list of moves, each made by a named agent and
  reporting the result of the hook that move runs. `advance/1` applies the
  next move and, after the last one, starts the replay again from
  `initial_board/0`.

  One card is a goal. Five of the cards, four work tasks and a defect, are
  its children, two of them already done when the replay starts. The goal
  is placed by the rule a real board uses: it sits in the leftmost column
  that holds one of its children, and in Done once they all are, so it
  changes column in the same move as the child that drives it. `goals/1`
  gives the goals strip its progress.

  The data holds no display text, only atoms and identifiers. Card titles,
  column names and event sentences are translated at render time by the
  functions below, so a visitor sees them in their own locale. Agent names
  are product names and hook names are the `.stride.md` section names, so
  neither is translated.

  `docs/demo-board.md` explains how to change the script.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @columns [:backlog, :ready, :doing, :review, :done]

  @agents %{
    claude: %{kind: :agent, name: "Claude", palette: "agent-claude"},
    cursor: %{kind: :agent, name: "Cursor", palette: "agent-cursor"},
    codex: %{kind: :agent, name: "Codex", palette: "agent-codex"}
  }

  # The person who wrote the Backlog card. A made-up first name, never a
  # real account.
  @author %{kind: :human, name: "Alex", palette: "human-blue"}

  @cards %{
    "W100" => %{priority: :medium, key_files: 2, acceptance: 3, files_changed: 3},
    "W101" => %{priority: :high, key_files: 3, acceptance: 4, files_changed: 4},
    "W102" => %{priority: :medium, key_files: 2, acceptance: 3, files_changed: 2},
    "W103" => %{priority: :low, key_files: 1, acceptance: 2, files_changed: 1},
    "W104" => %{priority: :critical, key_files: 2, acceptance: 3, files_changed: 2},
    "W105" => %{priority: :low, key_files: 1, acceptance: 2, files_changed: 1},
    "D106" => %{type: :defect, priority: :medium, key_files: 1, acceptance: 2, files_changed: 2}
  }

  # The goal cards, each with its children. A goal is a card on the board
  # like any other, but no move names it: `apply_step/2` places it after
  # every move.
  @goals %{
    "G10" => %{priority: :high, children: ["W100", "D106", "W101", "W102", "W104"]}
  }

  # The violet goal palette `KanbanWeb.GoalCard` and `KanbanWeb.GoalsStrip`
  # default to, shared by the goal chip on each child card.
  @goal_color "var(--stride-violet)"
  @goal_ink "var(--stride-violet-ink)"

  @initial_board %{
    columns: %{
      backlog: ["W105"],
      ready: ["G10", "W101", "W103"],
      doing: ["W104", "W102"],
      review: [],
      done: ["W100", "D106"]
    },
    agents: %{"W104" => :cursor, "W102" => :codex, "W100" => :claude, "D106" => :codex}
  }

  # Each move: which agent acts on which card, what kind of move it is, the
  # column the card ends in, and the hook the move runs with its result.
  # The goal G10 follows its children: to Doing on the first move, to Review
  # on the fifth and to Done on the ninth.
  @script [
    %{
      card: "W101",
      agent: :claude,
      event: :claim,
      to: :doing,
      hook: "before_doing",
      result: :passed
    },
    %{
      card: "W104",
      agent: :cursor,
      event: :submit,
      to: :review,
      hook: "after_doing",
      result: :passed
    },
    %{
      card: "W102",
      agent: :codex,
      event: :submit,
      to: :review,
      hook: "after_doing",
      result: :passed
    },
    %{
      card: "W101",
      agent: :claude,
      event: :hook_failed,
      to: :doing,
      hook: "after_doing",
      result: :failed
    },
    %{
      card: "W101",
      agent: :claude,
      event: :submit,
      to: :review,
      hook: "after_doing",
      result: :passed
    },
    %{
      card: "W104",
      agent: :cursor,
      event: :finish,
      to: :done,
      hook: "after_review",
      result: :passed
    },
    %{
      card: "W103",
      agent: :cursor,
      event: :claim,
      to: :doing,
      hook: "before_doing",
      result: :passed
    },
    %{
      card: "W102",
      agent: :codex,
      event: :finish,
      to: :done,
      hook: "after_review",
      result: :passed
    },
    %{
      card: "W101",
      agent: :claude,
      event: :finish,
      to: :done,
      hook: "after_review",
      result: :passed
    },
    %{
      card: "W103",
      agent: :cursor,
      event: :submit,
      to: :review,
      hook: "after_doing",
      result: :passed
    }
  ]

  # How many applied moves the activity feed keeps.
  @feed_length 4

  @typedoc "A column of the sample board."
  @type column :: :backlog | :ready | :doing | :review | :done

  @typedoc "The board: card identifiers per column, and which agent holds each card."
  @type board :: %{columns: %{column() => [String.t()]}, agents: %{String.t() => atom()}}

  @typedoc "The replay: the index of the next move, the board, and the moves applied so far."
  @type replay :: %{index: non_neg_integer(), board: board(), events: [map()]}

  @doc "The columns of the sample board, in board order."
  @spec columns() :: [column()]
  def columns, do: @columns

  @doc "The ordered list of moves the replay makes before it starts again."
  @spec script() :: [map()]
  def script, do: @script

  @doc "The board as it stands before the first move."
  @spec initial_board() :: board()
  def initial_board, do: @initial_board

  @doc "The replay before its first move."
  @spec new() :: replay()
  def new, do: %{index: 0, board: initial_board(), events: []}

  @doc """
  Applies the next move of the script. After the last move the replay starts
  again: the board returns to `initial_board/0` and the feed is emptied.
  """
  @spec advance(replay()) :: replay()
  def advance(%{index: index}) when index >= length(@script), do: new()

  def advance(%{index: index, board: board, events: events}) do
    step = Enum.at(@script, index)

    %{
      index: index + 1,
      board: apply_step(board, step),
      events: Enum.take([step | events], @feed_length)
    }
  end

  @doc """
  Moves the step's card to the head of the step's column and records the
  step's agent against it. A step whose column is the one the card is
  already in (a failing hook) leaves the card where it is.

  Then it places every goal in the column `goal_column/2` picks, at the head
  of that column when the goal moves.
  """
  @spec apply_step(board(), map()) :: board()
  def apply_step(%{columns: columns, agents: agents}, %{card: card, agent: agent, to: to}) do
    columns = columns |> move_card(card, to) |> place_goals()
    %{columns: columns, agents: Map.put(agents, card, agent)}
  end

  defp place_goals(columns) do
    @goals
    |> Map.keys()
    |> Enum.reduce(columns, &move_card(&2, &1, goal_column(&2, &1)))
  end

  defp move_card(columns, card, to) do
    if card in Map.fetch!(columns, to) do
      columns
    else
      columns
      |> Map.new(fn {column, cards} -> {column, List.delete(cards, card)} end)
      |> Map.update!(to, &[card | &1])
    end
  end

  @doc """
  The column a goal belongs in, given where its children are: the leftmost
  column that holds one of them. Done is the last column, so that is Done
  once every child is done. A real board places a goal by the same rule.
  """
  @spec goal_column(%{column() => [String.t()]}, String.t()) :: column()
  def goal_column(columns, goal) do
    goal
    |> children()
    |> Enum.map(&column_of(columns, &1))
    |> Enum.min_by(&column_position/1)
  end

  @doc """
  How many of a goal's children sit in each column, plus their total, in the
  `:flow` shape `KanbanWeb.GoalsStrip` and `KanbanWeb.SegmentedProgressBar`
  read.
  """
  @spec goal_flow(board(), String.t()) :: %{atom() => non_neg_integer()}
  def goal_flow(%{columns: columns}, goal) do
    children = children(goal)
    counts = children |> Enum.map(&column_of(columns, &1)) |> Enum.frequencies()

    @columns
    |> Map.new(&{&1, Map.get(counts, &1, 0)})
    |> Map.put(:total, length(children))
  end

  @doc """
  The goals for the strip above the columns, as the maps
  `KanbanWeb.GoalsStrip.goals_strip/1` renders. Each is marked promoted, so
  the strip shows no "unpromoted" badge.
  """
  @spec goals(board()) :: [map()]
  def goals(board) do
    for goal <- @goals |> Map.keys() |> Enum.sort() do
      %{
        identifier: goal,
        name: card_title(goal),
        color: @goal_color,
        ink: @goal_ink,
        flow: goal_flow(board, goal),
        promoted: true
      }
    end
  end

  defp children(goal), do: @goals |> Map.fetch!(goal) |> Map.fetch!(:children)

  defp column_of(columns, card) do
    Enum.find_value(@columns, &(card in Map.fetch!(columns, &1) && &1))
  end

  defp column_position(column), do: Enum.find_index(@columns, &(&1 == column))

  defp goal_of(card) do
    Enum.find_value(@goals, fn {goal, %{children: children}} -> card in children && goal end)
  end

  @doc """
  The cards in a column, as the maps `KanbanWeb.TaskCard.task_card/1`
  renders. The agent appears as the claimant while the card is in Doing and
  as the one who completed it in Review and Done. A goal carries its
  children's progress, and a child carries the chip of its goal.
  """
  @spec cards_in(board(), column()) :: [map()]
  def cards_in(%{columns: columns, agents: agents} = board, column) do
    columns
    |> Map.fetch!(column)
    |> Enum.map(&card(board, &1, column, agent(Map.get(agents, &1))))
  end

  defp card(board, identifier, _column, _agent) when is_map_key(@goals, identifier) do
    flow = goal_flow(board, identifier)

    %{
      identifier: identifier,
      type: :goal,
      priority: @goals |> Map.fetch!(identifier) |> Map.fetch!(:priority),
      title: card_title(identifier),
      author: @author,
      children: Map.take(flow, [:done, :review, :doing, :ready, :total]),
      promoted: true
    }
  end

  defp card(_board, identifier, column, agent) do
    data = Map.fetch!(@cards, identifier)

    %{
      identifier: identifier,
      type: Map.get(data, :type, :work),
      priority: data.priority,
      title: card_title(identifier),
      author: @author,
      claimed_by: if(column == :doing, do: agent),
      completed_by: if(column in [:review, :done], do: agent),
      key_files_count: data.key_files,
      acceptance_count: data.acceptance,
      files_changed_count: if(column in [:review, :done], do: data.files_changed),
      goal: goal_chip(goal_of(identifier))
    }
  end

  defp goal_chip(nil), do: nil

  defp goal_chip(goal),
    do: %{identifier: goal, short: card_title(goal), color: @goal_color, ink: @goal_ink}

  @doc "The avatar map for an agent key, or `nil` for none."
  @spec agent(atom() | nil) :: map() | nil
  def agent(nil), do: nil
  def agent(key), do: Map.fetch!(@agents, key)

  @doc """
  The number of task cards in a column, which a column header shows. A goal
  card is left out, as a real board counts only work tasks and defects.
  """
  @spec task_count(board(), column()) :: non_neg_integer()
  def task_count(%{columns: columns}, column),
    do: columns |> Map.fetch!(column) |> Enum.count(&(not is_map_key(@goals, &1)))

  @doc """
  The translated name of a column. The names have their own `demo column`
  context, so each locale can give the five columns five distinct names.
  """
  @spec column_name(column()) :: String.t()
  def column_name(:backlog), do: pgettext("demo column", "Backlog")
  def column_name(:ready), do: pgettext("demo column", "Ready")
  def column_name(:doing), do: pgettext("demo column", "Doing")
  def column_name(:review), do: pgettext("demo column", "Review")
  def column_name(:done), do: pgettext("demo column", "Done")

  @doc "The translated title of a sample card."
  @spec card_title(String.t()) :: String.t()
  def card_title("W100"), do: gettext("Set up the project README")
  def card_title("W101"), do: gettext("Add a dark mode toggle to settings")
  def card_title("W102"), do: gettext("Write tests for the export endpoint")
  def card_title("W103"), do: gettext("Fix the time zone on the weekly report")
  def card_title("W104"), do: gettext("Cache the board summary query")
  def card_title("W105"), do: gettext("Translate the onboarding emails")
  def card_title("D106"), do: gettext("Fix the broken link in the release checklist")
  def card_title("G10"), do: gettext("Get the app ready for launch")

  @doc "The translated sentence the activity feed shows for a move."
  @spec describe(map()) :: String.t()
  def describe(%{event: event, card: card, agent: agent}) do
    bindings = [agent: agent(agent).name, card: card]

    case event do
      :claim -> claimed(bindings)
      :submit -> submitted(bindings)
      :finish -> finished(bindings)
      :hook_failed -> hook_failed(bindings)
    end
  end

  # One function per sentence: gettext needs each msgid as a literal.
  defp claimed(bindings), do: gettext("%{agent} claimed %{card}", bindings)
  defp submitted(bindings), do: gettext("%{agent} sent %{card} to Review", bindings)
  defp finished(bindings), do: gettext("%{agent} moved %{card} to Done", bindings)

  defp hook_failed(bindings),
    do: gettext("%{agent} hit a failing hook on %{card} and is fixing it", bindings)

  @doc "The translated label for a hook result."
  @spec result_label(:passed | :failed) :: String.t()
  def result_label(:passed), do: pgettext("hook result", "passed")
  def result_label(:failed), do: pgettext("hook result", "failed")
end
