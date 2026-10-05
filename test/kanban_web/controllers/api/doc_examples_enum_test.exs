defmodule KanbanWeb.API.DocExamplesEnumTest do
  @moduledoc """
  Drift guard for the enum values shown in the docs' JSON examples (D358).

  Agents copy request and response examples straight out of `docs/api/*.md`
  and the top-level `docs/*.md` guides. Before D358 several of them still
  showed retired values: `"type": "task"` (only `work`, `defect` and `goal`
  exist, and since D352 `POST /api/tasks` rejects anything else with a 422),
  and complexity values `trivial`, `low`, `high` and `very_high` from an old
  five-level scale that the `small`/`medium`/`large` enum replaced.

  This test scans every `"type"`, `"complexity"`, `"actual_complexity"` and
  `"priority"` key/value pair in those files, including backslash-escaped JSON
  inside shell `-d` bodies, and fails with the file and line of any value the
  `Kanban.Tasks.Task` schema would reject. The valid sets come from the
  schema's `Ecto.Enum` fields, never from literals duplicated here. The rules
  are written down in `docs/doc-example-enum-contract.md`.

  Out of scope on purpose:

    * `docs/multi-agent-instructions/` holds deliberate "DON'T" anti-examples
      that show `"type": "task"` as the wrong value, so it is never scanned
      (only top-level `docs/*.md` files are, not subdirectories).
    * `status` is not scanned: reviewer, hook and verification payloads in the
      same docs legitimately use non-task statuses such as `failed`, `success`
      and `met`.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Task

  @root Path.expand("../../../..", __DIR__)

  @scanned_globs ["docs/api/*.md", "docs/*.md"]
  @anti_example_dir "docs/multi-agent-instructions"

  # Each scanned key and the Task field whose enum it must match.
  @enum_fields %{
    "type" => :type,
    "complexity" => :complexity,
    "actual_complexity" => :actual_complexity,
    "priority" => :priority
  }

  # The one legitimate non-task "type" in the docs: the OpenAPI securityScheme
  # in docs/api/get_openapi_json.md (`"bearerAuth": { "type": "http", ... }`).
  @extra_allowed %{"type" => ["http"]}

  # `"key": "value"`, where either quote may be backslash-escaped, as in a
  # double-quoted shell `-d "{ \"type\": \"work\" }"` body. The key must be the
  # whole quoted key, so `"step_type"` and `"review_status"` never match.
  # A null or numeric value is not quoted and so never matches.
  @pair ~r/\\?"(type|complexity|actual_complexity|priority)\\?"\s*:\s*\\?"([^"\\]*)\\?"/

  defp scanned_files do
    @scanned_globs
    |> Enum.flat_map(&(@root |> Path.join(&1) |> Path.wildcard()))
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp valid_values(key) do
    field = Map.fetch!(@enum_fields, key)
    Task |> Ecto.Enum.values(field) |> Enum.map(&to_string/1)
  end

  defp allowed_values(key), do: valid_values(key) ++ Map.get(@extra_allowed, key, [])

  # Every scanned pair in `contents` as {line_number, key, value}.
  defp pairs(contents) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      @pair
      |> Regex.scan(line, capture: :all_but_first)
      |> Enum.map(fn [key, value] -> {number, key, value} end)
    end)
  end

  # One message per out-of-enum value, naming `label` (the file) and the line.
  defp violations(contents, label) do
    for {number, key, value} <- pairs(contents), value not in allowed_values(key) do
      ~s(#{label}:#{number}: "#{key}": "#{value}" is not one of ) <>
        (key |> valid_values() |> Enum.join(", "))
    end
  end

  defp read(path), do: @root |> Path.join(path) |> File.read!()

  describe "the real docs" do
    test "docs examples use only valid enum values" do
      files = scanned_files()
      problems = Enum.flat_map(files, &violations(read(&1), &1))

      assert problems == [],
             "docs JSON examples use values the Task schema rejects " <>
               "(see docs/doc-example-enum-contract.md):\n" <> Enum.join(problems, "\n")

      # Non-vacuity: the pattern really does see the docs' examples.
      scanned_pairs = files |> Enum.flat_map(&pairs(read(&1))) |> length()
      assert scanned_pairs > 100, "expected to scan over 100 pairs, saw #{scanned_pairs}"
    end

    test "scans every api doc and skips the anti-example directory" do
      files = scanned_files()

      api_docs =
        @root
        |> Path.join("docs/api")
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&"docs/api/#{&1}")

      assert api_docs != []
      assert api_docs -- files == [], "api docs not scanned: #{inspect(api_docs -- files)}"
      assert "docs/ESTIMATION-FEEDBACK.md" in files
      assert "docs/api/README.md" in files

      refute Enum.any?(files, &String.starts_with?(&1, @anti_example_dir <> "/")),
             ~s(#{@anti_example_dir} must not be scanned: its "type": "task" lines are ) <>
               "deliberate anti-examples"

      # The exclusion matters: the anti-examples really do carry the bad value.
      anti_examples =
        @root
        |> Path.join(@anti_example_dir <> "/**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&violations(File.read!(&1), &1))

      assert Enum.any?(anti_examples, &(&1 =~ ~s("type": "task")))
    end
  end

  describe "the scanner" do
    test "valid sets derive from Task enums" do
      for {key, field} <- @enum_fields do
        assert valid_values(key) == Task |> Ecto.Enum.values(field) |> Enum.map(&to_string/1)

        # Every value the guard accepts is one the API changeset accepts too.
        for value <- valid_values(key) do
          changeset = Task.api_create_changeset(%Task{}, %{field => value})
          refute Keyword.has_key?(changeset.errors, field), "#{key} #{value} rejected"
        end
      end

      assert valid_values("type") == ~w(work defect goal)
      assert valid_values("complexity") == ~w(small medium large)
      assert valid_values("actual_complexity") == ~w(small medium large)
      assert valid_values("priority") == ~w(low medium high critical)
    end

    test "scanner accepts every enum value and rejects near misses" do
      for {key, _field} <- @enum_fields, value <- valid_values(key) do
        assert violations(~s({"#{key}": "#{value}"}), "x.md") == []
      end

      near_misses = [
        {"type", "Work"},
        {"type", "task"},
        {"type", "goals"},
        {"complexity", "very_high"},
        {"complexity", "trivial"},
        {"complexity", "low"},
        {"complexity", "Small"},
        {"actual_complexity", "high"},
        {"priority", "urgent"},
        {"priority", "High"},
        {"priority", ""}
      ]

      for {key, value} <- near_misses do
        assert [message] = violations(~s(  "#{key}": "#{value}",), "x.md"),
               "#{key} #{inspect(value)} was not flagged"

        assert message =~ ~s(x.md:1: "#{key}": "#{value}" is not one of)
      end
    end

    test "scanner flags type task with file and line" do
      doc = """
      ```json
      {
        "type": "task",
        "complexity": "medium"
      }
      ```
      """

      assert violations(doc, "docs/api/example.md") == [
               ~s(docs/api/example.md:3: "type": "task" is not one of work, defect, goal)
             ]
    end

    test "scanner reads backslash-escaped JSON and several pairs per line" do
      doc = ~S"""
        -d "{\"title\": \"x\", \"actual_complexity\": \"high\"}"
      {"type": "work", "priority": "urgent", "complexity": "very_high"}
      """

      assert violations(doc, "d.md") == [
               ~s(d.md:1: "actual_complexity": "high" is not one of small, medium, large),
               ~s(d.md:2: "priority": "urgent" is not one of low, medium, high, critical),
               ~s(d.md:2: "complexity": "very_high" is not one of small, medium, large)
             ]
    end

    test "scanner ignores null values and the http type" do
      doc = """
      "complexity": null,
      "actual_complexity": null,
      "securitySchemes": { "bearerAuth": { "type": "http", "scheme": "bearer" } },
      "step_type": "command",
      "review_status": "approved",
      "status": "failed",
      "complexity_note": "low"
      """

      assert violations(doc, "n.md") == []
      assert [{3, "type", "http"}] = pairs(doc)
    end
  end
end
