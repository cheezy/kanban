defmodule KanbanWeb.LocalTimeUsageTest do
  @moduledoc """
  W2735: every absolute date or time a page, email or export shows goes
  through `KanbanWeb.LocalTime`, which shifts it to the viewer's zone and
  renders it in the viewer's language. A bare `Calendar.strftime/3`,
  `DateTime.to_string/1` or `NaiveDateTime.to_string/1` renders UTC with an
  English pattern instead, which is the bug the W2727–W2734 sweeps removed.

  This test reads every `.ex` and `.heex` file under `lib/kanban_web` and fails
  on any such call outside the files in `@allowed`, naming the file and line.
  It matches calls (`Calendar.strftime(`) wherever they sit, including at the
  end of a pipe split over several lines or inside a string interpolation, and
  captures (`&Calendar.strftime/3`). A prose mention such as
  `Calendar.strftime/3` in a moduledoc is not a call, and a call after a `#`
  that starts a comment, on its own line or at the end of one, is skipped. A
  `#` that opens an interpolation (`\#{`) is not a comment. ISO 8601
  serialisation (`DateTime.to_iso8601/1`) and `Date.to_string/1` are not
  matched: they are machine formats, not display text.

  `docs/dates-and-times.md` explains the rule and the allow-list.
  """
  use ExUnit.Case, async: true

  @source_root "lib/kanban_web"

  # Each entry names one file and why it may format a timestamp itself. Never
  # list a directory. An entry must exist and must still make a matching call,
  # so the list cannot go stale.
  @allowed %{
    "lib/kanban_web/local_time.ex" =>
      "The formatter itself: its private strftime/2 is the one sanctioned Calendar.strftime call.",
    "lib/kanban_web/emails/audit_stream_email.ex" =>
      "The audit-gap email has no viewer zone, so its sentence prints the gap in UTC and says so."
  }

  # A call (`Calendar.strftime(`, after a pipe, a newline or anything else) or a
  # capture (`&Calendar.strftime/3`). A bare `Calendar.strftime/3` is prose.
  # `mix format` always writes the parentheses, so a paren-less call cannot
  # land.
  @names "Calendar\\.strftime|NaiveDateTime\\.to_string|DateTime\\.to_string"
  @call_re Regex.compile!("(?<![\\w.])(#{@names})\\s*\\(|&\\s*(#{@names})/\\d")

  describe "raw timestamp formatting in lib/kanban_web" do
    test "no raw timestamp formatting outside LocalTime" do
      sources = sources()

      # Guards against a vacuous pass: a glob or regex that stopped matching
      # would report no offenders because it read nothing.
      assert length(sources) > 100
      assert Enum.any?(sources, fn {path, source} -> violations(path, source) != [] end)

      offenders = offenders(sources)

      assert offenders == [],
             """
             raw timestamp formatting outside KanbanWeb.LocalTime. Use \
             KanbanWeb.LocalTime.format/2 or <.local_time> instead, or add the \
             file to @allowed with a reason (docs/dates-and-times.md):
             """ <> Enum.join(offenders, "\n")
    end

    test "every allow-list entry exists and still makes a matching call" do
      for {path, reason} <- @allowed do
        assert File.regular?(path), "#{path} is allow-listed but does not exist"
        assert String.trim(reason) != "", "#{path} is allow-listed without a reason"

        assert violations(path, File.read!(path)) != [],
               "#{path} is allow-listed but no longer formats a timestamp; remove its entry"
      end
    end

    test "catches a piped strftime" do
      source = """
      defmodule Fake do
        def label(task) do
          task.inserted_at
          |> DateTime.shift_zone!("Etc/UTC")
          |> Calendar.strftime(
            "%H:%M"
          )
        end
      end
      """

      assert [{"lib/kanban_web/fake.ex", 5, "Calendar.strftime"}] =
               violations("lib/kanban_web/fake.ex", source)
    end

    test "catches a call inside a string interpolation" do
      source = ~S|def f(dt), do: "at #{Calendar.strftime(dt, "%H:%M")}"| <> "\n"

      assert [{"lib/kanban_web/fake.ex", 1, "Calendar.strftime"}] =
               violations("lib/kanban_web/fake.ex", source)
    end

    test "reports file and line" do
      source = """
      defmodule Fake do
        def a(dt), do: Calendar.strftime(dt, "%H:%M")
        def b(dt), do: DateTime.to_string(dt)
        def c(ndt), do: NaiveDateTime.to_string(ndt)
        def d, do: &Calendar.strftime/2
      end
      """

      assert offenders([{"lib/kanban_web/fake.ex", source}]) == [
               "lib/kanban_web/fake.ex:2 Calendar.strftime",
               "lib/kanban_web/fake.ex:3 DateTime.to_string",
               "lib/kanban_web/fake.ex:4 NaiveDateTime.to_string",
               "lib/kanban_web/fake.ex:5 Calendar.strftime"
             ]
    end

    test "skips allow-listed files" do
      source = ~s|def f(dt), do: Calendar.strftime(dt, "%H:%M")\n|

      assert offenders([
               {"lib/kanban_web/local_time.ex", source},
               {"lib/kanban_web/emails/audit_stream_email.ex", source},
               {"lib/kanban_web/fake.ex", source}
             ]) == ["lib/kanban_web/fake.ex:1 Calendar.strftime"]
    end

    test "ignores machine formats, prose mentions and comments" do
      source = """
      defmodule Fake do
        @moduledoc "Names in the shape `Calendar.strftime/3` expects."
        # Calendar.strftime(dt, "%H:%M") was the old fallback.
        def e(dt), do: LocalTime.format(dt, :time) # was Calendar.strftime(dt, "%H")
        def a(dt), do: DateTime.to_iso8601(dt)
        def b(ndt), do: NaiveDateTime.to_iso8601(ndt)
        def c(date), do: Date.to_string(date)
        def d(dt), do: MyApp.DateTime.to_string(dt)
      end
      """

      assert violations("lib/kanban_web/fake.ex", source) == []
    end
  end

  defp sources do
    [@source_root, "**", "*.{ex,heex}"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp offenders(sources) do
    for {path, source} <- sources,
        not Map.has_key?(@allowed, path),
        {^path, line, call} <- violations(path, source),
        do: "#{path}:#{line} #{call}"
  end

  # Scans the whole file rather than line by line, so a call split across
  # lines is still one match. The line is the one holding the function name.
  defp violations(path, source) do
    for [_whole | groups] <- Regex.scan(@call_re, source, return: :index),
        {offset, length} = matched_name(groups),
        {line, before} = locate(source, offset),
        not commented?(before),
        do: {path, line, binary_part(source, offset, length)}
  end

  # The call and the capture branches each capture the name; the branch that
  # did not match reports an offset of -1.
  defp matched_name(groups), do: Enum.find(groups, fn {offset, _} -> offset >= 0 end)

  # The match's line number, and the text before it on that line.
  defp locate(source, offset) do
    lines = source |> binary_part(0, offset) |> String.split("\n")
    {length(lines), List.last(lines)}
  end

  # A `#` earlier on the line starts a comment unless it opens an
  # interpolation. A `#` inside a string literal before the call would also
  # read as a comment; that shape does not occur in lib/kanban_web.
  defp commented?(before), do: Regex.match?(~r/#(?!\{)/, before)
end
