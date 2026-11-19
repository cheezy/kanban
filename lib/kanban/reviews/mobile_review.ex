defmodule Kanban.Reviews.MobileReview do
  @moduledoc """
  Builds what the app's review screen shows for one pending review
  (`GET /api/me/reviews/:task_id`, W2751;
  `docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §6.4, §7.5).

  `build/3` takes the task, the tasks that depend on it and the requesting
  device's class, and returns:

    * the summary: the task's `completion_summary`;
    * the verdicts: one per review section, each with its status and note.
      They are resolved by the same functions the `/review` verdict cells use
      (`KanbanWeb.ReviewReportHelpers.section_status/2`,
      `KanbanWeb.ReviewAcceptance.acceptance_passed/1`), so the app and the web
      never show one task with different verdicts. A task with no review
      verdicts at all returns `[]`;
    * the acceptance criteria, the security considerations, the security
      findings by severity, the project checks and the behaviour matrix the
      reviewer echoed;
    * the exploratory count, which is always `nil` today: no structured
      exploratory block is stored, and `completion_notes` is free text that is
      never parsed (the app says "see notes on the web");
    * the files, flagged first (`flag/2` below), each with its additions,
      deletions and whether its diff was cut at the cap;
    * the size and `approvable_here`, both from `Kanban.Reviews.MobileGuard`,
      so the screen and the approve route apply one rule;
    * `review_requested_at`, `waiting_since` and `holds_up`: the dependent
      tasks that are not yet completed.

  A file is flagged when a `reviewer_result` issue's `file` names its path
  (reason `:issue`, or `:security` for a security issue), or when the
  security section names it: the text of a consideration whose status is
  not `mitigated` or `not_applicable` (so `partial`, `unmitigated` or none),
  or the section note when the section failed (reason `:security`). Paths are
  compared after `normalize_file/1`: `./path`, `path:12`, `path:12:3`,
  `path:12-15`, `path#L12`, `lib\\a.ex` and `lib//a.ex` all name the same file,
  and so does an issue path that ends in `/` plus the listed path, such as a
  `b/`-prefixed diff path or an absolute one; an issue names only the
  longest listed path it matches (`issue_path/2`). Security text may name a file
  as `path` or `./path`. Two stored entries that normalize to one path are
  one file. An issue that names no listed file flags nothing, and an older
  `reviewer_result` whose issues carry no `file` leaves every file unflagged,
  in diff order.

  `size` counts every stored diff, an entry with no usable path included, so
  the phone limit never misses a diff; `files` lists only the entries with a
  path, so its counts can sum to less than `size.changed_lines`. A security
  issue whose severity is not `critical`, `important` or `minor` counts as
  `minor` in `security_findings`, as `/review` groups it. A criterion whose
  text is a number keeps it as a string, and one with no usable text keeps its
  status with a `nil` criterion rather than being dropped.

  Pure: it reads only what it is given and never touches the database.
  Everything in a `reviewer_result` is agent-supplied, so nothing here raises
  on an unexpected shape or turns a stored value into an atom.
  """

  alias Kanban.Reviews
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Reviews.MobileReviewFile
  alias Kanban.Tasks.Task
  alias KanbanWeb.ReviewAcceptance
  alias KanbanWeb.ReviewBehaviourMatrix
  alias KanbanWeb.ReviewReportHelpers

  @sections [:testing_strategy, :patterns, :pitfalls, :security_considerations]
  @severities ~w(critical important minor)
  @check_statuses ~w(met not_met not_applicable)

  @type t :: %{
          task: Task.t(),
          summary: String.t() | nil,
          verdicts: [map()],
          acceptance_criteria: [map()],
          security_considerations: [map()],
          security_findings: %{String.t() => non_neg_integer()},
          project_checks: %{String.t() => non_neg_integer()},
          exploratory: %{count: non_neg_integer() | nil, note: String.t() | nil},
          behaviour_matrix: [map()],
          files: [map()],
          size: map(),
          approvable_here: boolean(),
          approvable_here_reason: atom() | nil,
          review_requested_at: DateTime.t() | nil,
          waiting_since: DateTime.t() | nil,
          holds_up: [Task.t()]
        }

  @doc """
  The review screen's data for `task`, as described in the moduledoc.
  `dependents` are the tasks whose `dependencies` name it, and
  `device_class` is the requesting device's (`:phone`, `:tablet`, or `nil`
  for the web).
  """
  @spec build(Task.t(), [Task.t()], MobileGuard.device_class()) :: t()
  def build(%Task{} = task, dependents, device_class) when is_list(dependents) do
    task
    |> review_details()
    |> Map.merge(change_details(task, device_class))
    |> Map.merge(%{
      review_requested_at: task.review_requested_at,
      waiting_since: Reviews.waiting_since(task),
      holds_up: holds_up(dependents)
    })
  end

  defp review_details(%Task{} = task) do
    %{
      task: task,
      summary: blank_to_nil(task.completion_summary),
      verdicts: verdicts(task),
      acceptance_criteria: acceptance_criteria(task),
      security_considerations: security_considerations(task),
      security_findings: security_findings(task),
      project_checks: project_checks(task),
      exploratory: exploratory(task),
      behaviour_matrix: ReviewBehaviourMatrix.rows(task)
    }
  end

  defp change_details(%Task{} = task, device_class) do
    size = MobileGuard.size(task)
    {approvable, reason} = approval(size, device_class)

    %{
      files: files(task),
      size: Map.put(size, :large_change, MobileGuard.large_change?(size)),
      approvable_here: approvable,
      approvable_here_reason: reason
    }
  end

  defp approval(size, device_class) do
    case MobileGuard.check(size, device_class) do
      :ok -> {true, nil}
      {:error, reason} -> {false, reason}
    end
  end

  @doc """
  The verdict of each review section, in a fixed order: acceptance criteria,
  testing strategy, patterns, pitfalls and security considerations. Each is
  `%{section:, status:, note:}` with a status of `"passed"`, `"failed"`,
  `"not_assessed"` or `nil`. Returns `[]` when no section has a status or a
  note, as for a task that was never reviewed.
  """
  @spec verdicts(Task.t()) :: [map()]
  def verdicts(%Task{} = task) do
    acceptance = %{
      section: :acceptance_criteria,
      status: task |> ReviewAcceptance.acceptance_passed() |> passed_status(),
      note: nil
    }

    sections =
      Enum.map(@sections, fn section ->
        %{
          section: section,
          status: ReviewReportHelpers.section_status(task, section),
          note: ReviewReportHelpers.section_note(task, section)
        }
      end)

    verdicts = [acceptance | sections]

    if Enum.all?(verdicts, &(is_nil(&1.status) and is_nil(&1.note))), do: [], else: verdicts
  end

  @doc """
  The files the task changed, flagged first and otherwise in diff order.

  Each is `%{index:, path:, additions:, deletions:, truncated:, flagged:,
  flag_reason:}`. `index` is the file's first position in `changed_files`.
  A path listed twice is one file, as `MobileGuard.size/1` counts it, with
  its diffs' counts summed. When `changed_files` is empty the files come from
  `actual_files_changed`, with no index and no counts.
  """
  @spec files(Task.t()) :: [map()]
  def files(%Task{} = task) do
    rows = file_rows(task)
    mentions = mentions(task, Enum.map(rows, & &1.path))

    rows
    |> Enum.map(&Map.merge(&1, flag(&1.path, mentions)))
    |> Enum.sort_by(&(not &1.flagged))
  end

  @doc """
  One file's highlighted diff and its inline notes, for the flagged-file
  screen (`GET /api/me/reviews/:task_id/files/:index`, W2753), or
  `{:error, :not_found}`. `highlight` is called as `DiffHighlighter.highlight/4`
  is; `Kanban.Reviews.MobileReviewFile.build/3` documents the rest.
  """
  @spec file(Task.t(), non_neg_integer(), MobileReviewFile.highlight()) ::
          {:ok, MobileReviewFile.t()} | {:error, :not_found}
  defdelegate file(task, index, highlight), to: MobileReviewFile, as: :build

  # --- Verdict details ------------------------------------------------------

  defp acceptance_criteria(%Task{} = task) do
    case task |> ReviewAcceptance.structured_acceptance() |> Enum.flat_map(&criterion/1) do
      [] -> criteria_from_lines(task)
      criteria -> criteria
    end
  end

  # The reviewer's entry is kept even when its text is unusable, so a
  # `not_met` never vanishes while the verdict shows failed.
  defp criterion(entry) when is_map(entry) do
    [
      %{
        criterion: criterion_text(entry["criterion"]),
        status: string_or_nil(entry["status"]),
        evidence: text_of(entry)
      }
    ]
  end

  defp criterion(_entry), do: []

  defp criterion_text(text) when is_binary(text), do: blank_to_nil(text)
  defp criterion_text(number) when is_number(number), do: to_string(number)
  defp criterion_text(_text), do: nil

  defp criteria_from_lines(%Task{acceptance_criteria: text} = task) when is_binary(text) do
    checked = ReviewAcceptance.acceptance_checked(task)
    failed = ReviewAcceptance.acceptance_failed(task)

    text
    |> criterion_lines()
    |> Enum.map(fn {criterion, index} ->
      %{criterion: criterion, status: line_status(index, checked, failed), evidence: nil}
    end)
  end

  defp criteria_from_lines(_task), do: []

  defp criterion_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index()
  end

  defp line_status(index, checked, failed) do
    cond do
      Map.has_key?(failed, index) -> "not_met"
      Map.has_key?(checked, index) -> "met"
      true -> nil
    end
  end

  defp security_considerations(%Task{} = task) do
    case ReviewReportHelpers.security_considerations_breakdown(task) do
      [] ->
        (task.security_considerations || [])
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&%{consideration: &1, status: nil, detail: nil})

      breakdown ->
        breakdown
    end
  end

  defp security_findings(%Task{} = task) do
    task
    |> issues()
    |> Enum.filter(&(&1["category"] == "security"))
    |> Enum.map(&severity_key(&1["severity"]))
    |> tally(@severities)
  end

  # As `/review` groups them: a severity outside the three counts as minor.
  defp severity_key(severity) when severity in @severities, do: severity
  defp severity_key(_severity), do: "minor"

  defp project_checks(%Task{} = task) do
    task
    |> result_list("project_checks")
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["status"])
    |> Enum.filter(&(&1 in @check_statuses))
    |> tally(@check_statuses)
  end

  # Counts each value, starting every key in `keys` at zero.
  defp tally(values, keys) do
    Enum.reduce(values, Map.new(keys, &{&1, 0}), fn value, counts ->
      Map.update!(counts, value, &(&1 + 1))
    end)
  end

  # No structured exploratory block is stored yet. When one is, its count
  # goes here; the free-text completion_notes are never parsed for it.
  defp exploratory(%Task{}), do: %{count: nil, note: "see_notes_on_web"}

  defp holds_up(dependents) do
    dependents
    |> Enum.filter(&(match?(%Task{}, &1) and &1.status != :completed))
    |> Enum.sort_by(& &1.id)
  end

  # --- Files and flags --------------------------------------------------------

  defp file_rows(%Task{changed_files: [_ | _] = entries}) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} -> entry_row(entry, index) end)
    |> Enum.reduce({[], %{}}, &merge_row/2)
    |> ordered_rows()
  end

  defp file_rows(%Task{actual_files_changed: text}) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.map(&normalize_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&%{index: nil, path: &1, additions: nil, deletions: nil, truncated: false})
  end

  defp file_rows(%Task{}), do: []

  defp ordered_rows({paths, rows}) do
    paths
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(rows, &1))
  end

  defp entry_row(entry, index) when is_map(entry) do
    case entry_path(entry) do
      nil -> []
      path -> [Map.merge(%{index: index, path: path}, entry_stats(entry))]
    end
  end

  defp entry_row(_entry, _index), do: []

  defp entry_path(%{"path" => path}), do: normalize_file(path)
  defp entry_path(%{path: path}), do: normalize_file(path)
  defp entry_path(_entry), do: nil

  defp entry_stats(entry) do
    case Map.get(entry, "diff") || Map.get(entry, :diff) do
      diff when is_binary(diff) -> MobileGuard.diff_stats(diff)
      _ -> %{additions: nil, deletions: nil, truncated: false}
    end
  end

  # A path listed twice keeps its first index and sums the counts.
  defp merge_row(row, {paths, rows}) do
    case Map.fetch(rows, row.path) do
      :error ->
        {[row.path | paths], Map.put(rows, row.path, row)}

      {:ok, seen} ->
        merged = %{
          seen
          | additions: add(seen.additions, row.additions),
            deletions: add(seen.deletions, row.deletions),
            truncated: seen.truncated or row.truncated
        }

        {paths, Map.put(rows, row.path, merged)}
    end
  end

  defp add(nil, nil), do: nil
  defp add(a, b), do: (a || 0) + (b || 0)

  # Everything that can flag a file: the issues' files, and the security
  # section's text.
  # Each issue flags only the listed path it names (`issue_path/2`).
  defp mentions(%Task{} = task, paths) do
    issue_files =
      task
      |> issues()
      |> Enum.flat_map(fn issue ->
        case issue["file"] |> normalize_file() |> issue_path(paths) do
          nil -> []
          path -> [{path, issue_reason(issue)}]
        end
      end)

    %{issue_files: issue_files, security_text: security_text(task)}
  end

  defp issue_reason(%{"category" => "security"}), do: :security
  defp issue_reason(_issue), do: :issue

  defp security_text(%Task{} = task) do
    Enum.filter(open_consideration_text(task) ++ failed_security_note(task), &is_binary/1)
  end

  defp open_consideration_text(%Task{} = task) do
    task
    |> ReviewReportHelpers.security_considerations_breakdown()
    |> Enum.reject(&(&1.status in ["mitigated", "not_applicable"]))
    |> Enum.flat_map(&[&1.consideration, &1.detail])
  end

  defp failed_security_note(%Task{} = task) do
    if ReviewReportHelpers.section_status(task, :security_considerations) == "failed",
      do: [ReviewReportHelpers.security_considerations_note(task)],
      else: []
  end

  defp flag(path, %{issue_files: issue_files, security_text: security_text}) do
    reasons =
      for {file, reason} <- issue_files, file == path, do: reason

    reasons =
      if Enum.any?(security_text, &names_path?(&1, path)),
        do: [:security | reasons],
        else: reasons

    cond do
      :security in reasons -> %{flagged: true, flag_reason: :security}
      reasons != [] -> %{flagged: true, flag_reason: :issue}
      true -> %{flagged: false, flag_reason: nil}
    end
  end

  @doc """
  Whether an issue's normalized `file` names the listed `path`: exactly, or
  by a longer path that ends in "/" plus it, such as a `b/`-prefixed diff
  path or an absolute one.
  """
  @spec same_file?(String.t(), String.t()) :: boolean()
  def same_file?(file, path), do: file == path or String.ends_with?(file, "/" <> path)

  @doc """
  The one listed path in `paths` that an issue's normalized `file` names:
  the path it equals, else the longest path it ends in after a "/" (so
  `test/lib/a.ex` names `test/lib/a.ex`, never `lib/a.ex` as well), else
  `nil`.
  """
  @spec issue_path(String.t() | nil, [String.t()]) :: String.t() | nil
  def issue_path(file, paths) when is_binary(file) and is_list(paths) do
    if file in paths,
      do: file,
      else:
        paths
        |> Enum.filter(&same_file?(file, &1))
        |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  def issue_path(_file, _paths), do: nil

  defp names_path?(text, path) do
    Regex.match?(~r/(?<![\w\/.-])(?:\.\/)?#{Regex.escape(path)}(?![\w\/-]|\.\w)/, text)
  end

  @doc """
  One spelling per file: backslashes become slashes, `//` and `/./`
  collapse, leading `./` and trailing `/` go, and a trailing location
  (`:12`, `:12:3`, `:12-15`, `#L12`, a bare `:`) is dropped. A blank or
  non-string is `nil`.
  """
  @spec normalize_file(term()) :: String.t() | nil
  def normalize_file(file) when is_binary(file) do
    file
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.replace(~r"/(\./)+", "/")
    |> String.replace(~r"/{2,}", "/")
    |> String.replace(~r"\A(\./)+", "")
    |> String.replace(~r"/+\z", "")
    |> String.replace(~r/(#L\d.*|:[\d:-]*)\z/, "")
    |> blank_to_nil()
  end

  def normalize_file(_file), do: nil

  # --- reviewer_result reads ----------------------------------------------

  @doc "The `reviewer_result` issues that are maps; `[]` when there are none."
  @spec issues(Task.t()) :: [map()]
  def issues(%Task{} = task), do: task |> result_list("issues") |> Enum.filter(&is_map/1)

  defp result_list(%Task{reviewer_result: %{} = result}, key) do
    case Map.get(result, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp result_list(%Task{}, _key), do: []

  defp text_of(entry), do: blank_to_nil(entry["evidence"]) || blank_to_nil(entry["note"])

  defp string_or_nil(value) when is_binary(value), do: blank_to_nil(value)
  defp string_or_nil(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp passed_status(true), do: "passed"
  defp passed_status(false), do: "failed"
  defp passed_status(nil), do: nil
end
