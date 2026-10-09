defmodule KanbanWeb.API.TaskListParamsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.TaskListParams

  @page_keys ~w(limit cursor status type priority assigned_to_id parent updated_since)

  describe "paginated?/1" do
    test "is false with no params" do
      refute TaskListParams.paginated?(%{})
    end

    test "is false for column_id and response_view alone" do
      refute TaskListParams.paginated?(%{"column_id" => "1"})
      refute TaskListParams.paginated?(%{"response_view" => "slim"})
      refute TaskListParams.paginated?(%{"column_id" => "1", "response_view" => "slim"})
    end

    test "is true for each page key, even when its value is blank" do
      for key <- @page_keys do
        assert TaskListParams.paginated?(%{key => "x"}), "#{key} should opt in"
        assert TaskListParams.paginated?(%{key => ""}), "blank #{key} should opt in"
      end
    end
  end

  describe "parse/1 accepts" do
    test "no page keys, defaulting limit to 50 and every filter to nil" do
      assert {:ok, page} = TaskListParams.parse(%{})
      assert page.limit == 50
      assert page.cursor == nil
      assert TaskListParams.filters(page) == %{}
    end

    test "limit at both bounds" do
      assert {:ok, %{limit: 1}} = TaskListParams.parse(%{"limit" => "1"})
      assert {:ok, %{limit: 200}} = TaskListParams.parse(%{"limit" => "200"})
    end

    test "a cursor produced by encode_cursor/1" do
      cursor = TaskListParams.encode_cursor(42)
      assert {:ok, %{cursor: 42}} = TaskListParams.parse(%{"cursor" => cursor})
    end

    test "every status value as its atom" do
      for {string, atom} <- [
            {"open", :open},
            {"in_progress", :in_progress},
            {"completed", :completed},
            {"blocked", :blocked}
          ] do
        assert {:ok, %{status: ^atom}} = TaskListParams.parse(%{"status" => string})
      end
    end

    test "every type value as its atom" do
      for {string, atom} <- [{"work", :work}, {"defect", :defect}, {"goal", :goal}] do
        assert {:ok, %{type: ^atom}} = TaskListParams.parse(%{"type" => string})
      end
    end

    test "every priority value as its atom" do
      for {string, atom} <- [
            {"low", :low},
            {"medium", :medium},
            {"high", :high},
            {"critical", :critical}
          ] do
        assert {:ok, %{priority: ^atom}} = TaskListParams.parse(%{"priority" => string})
      end
    end

    test "a positive assigned_to_id" do
      assert {:ok, %{assigned_to_id: 7}} = TaskListParams.parse(%{"assigned_to_id" => "7"})
    end

    test "any non-empty parent identifier, kept verbatim" do
      assert {:ok, %{parent: "G12"}} = TaskListParams.parse(%{"parent" => "G12"})
      # A non-goal identifier is not a 400: it resolves to an empty page.
      assert {:ok, %{parent: "W5"}} = TaskListParams.parse(%{"parent" => "W5"})
    end

    test "updated_since with a Z offset" do
      assert {:ok, %{updated_since: ~N[2026-01-31 12:00:00]}} =
               TaskListParams.parse(%{"updated_since" => "2026-01-31T12:00:00Z"})
    end

    test "updated_since with a non-UTC offset, shifted to UTC" do
      assert {:ok, %{updated_since: ~N[2026-01-31 10:00:00]}} =
               TaskListParams.parse(%{"updated_since" => "2026-01-31T12:00:00+02:00"})
    end

    test "updated_since with a fractional second, floored to the whole second" do
      for value <- [
            "2026-01-31T12:00:00.000001Z",
            "2026-01-31T12:00:00.5Z",
            "2026-01-31T12:00:00.999999+00:00",
            "2026-01-31T12:00:00.5",
            "2026-01-31T12:00:00.000Z"
          ] do
        assert {:ok, %{updated_since: since}} =
                 TaskListParams.parse(%{"updated_since" => value})

        # Whole-second value AND whole-second precision: no fraction survives.
        assert since == ~N[2026-01-31 12:00:00], "#{value} should floor"
        assert since.microsecond == {0, 0}
      end
    end

    test "updated_since without an offset, taken as UTC" do
      assert {:ok, %{updated_since: ~N[2026-01-31 12:00:00]}} =
               TaskListParams.parse(%{"updated_since" => "2026-01-31T12:00:00"})
    end

    test "several keys together, ignoring non-page keys" do
      params = %{
        "limit" => "3",
        "status" => "open",
        "type" => "work",
        "column_id" => "9",
        "response_view" => "slim"
      }

      assert {:ok, page} = TaskListParams.parse(params)
      assert page.limit == 3
      assert TaskListParams.filters(page) == %{status: :open, type: :work}
    end
  end

  describe "parse_limit/1" do
    test "defaults to 50 when absent and accepts 1..200" do
      assert TaskListParams.parse_limit(nil) == {:ok, 50}
      assert TaskListParams.parse_limit("1") == {:ok, 1}
      assert TaskListParams.parse_limit("200") == {:ok, 200}
    end

    test "rejects what parse/1 rejects for limit" do
      for value <- ["0", "201", "-1", "abc", "1.5", "", ["1"]] do
        assert {:error, "Invalid limit: must be an integer between 1 and 200"} =
                 TaskListParams.parse_limit(value),
               "limit #{inspect(value)} should be rejected"
      end
    end
  end

  describe "parse/1 rejects" do
    test "a limit outside 1..200 or not an integer" do
      for value <- ["0", "201", "-1", "abc", "1.5", "", " 5", ["1"], %{"a" => "1"}] do
        assert {:error, "Invalid limit: must be an integer between 1 and 200"} =
                 TaskListParams.parse(%{"limit" => value}),
               "limit #{inspect(value)} should be rejected"
      end
    end

    test "a malformed cursor" do
      bigint_overflow = Base.url_encode64("9223372036854775808", padding: false)

      for value <- [
            "!!!",
            "",
            Base.url_encode64("abc", padding: false),
            Base.url_encode64("0", padding: false),
            Base.url_encode64("-3", padding: false),
            Base.url_encode64("42", padding: true) <> "==",
            bigint_overflow,
            # Over the 32-byte cap although it decodes to the valid id 42.
            Base.url_encode64(String.duplicate("0", 24) <> "42", padding: false),
            ["MQ"]
          ] do
        assert {:error, "Invalid cursor" <> _} = TaskListParams.parse(%{"cursor" => value}),
               "cursor #{inspect(value)} should be rejected"
      end
    end

    test "an unknown or wrongly-cased status, type or priority" do
      assert {:error, "Invalid status: must be one of open, in_progress, completed, blocked"} =
               TaskListParams.parse(%{"status" => "review"})

      assert {:error, "Invalid status" <> _} = TaskListParams.parse(%{"status" => "OPEN"})
      assert {:error, "Invalid status" <> _} = TaskListParams.parse(%{"status" => ["open"]})

      assert {:error, "Invalid type: must be one of work, defect, goal"} =
               TaskListParams.parse(%{"type" => "task"})

      assert {:error, "Invalid priority: must be one of low, medium, high, critical"} =
               TaskListParams.parse(%{"priority" => "urgent"})
    end

    test "a non-positive or non-integer assigned_to_id" do
      for value <- ["0", "-1", "x", "", "9223372036854775808"] do
        assert {:error, "Invalid assigned_to_id: must be a positive integer"} =
                 TaskListParams.parse(%{"assigned_to_id" => value})
      end
    end

    test "a blank, oversized or non-string parent" do
      for value <- ["", String.duplicate("G", 256), ["G1"]] do
        assert {:error, "Invalid parent: must be a goal identifier such as G12"} =
                 TaskListParams.parse(%{"parent" => value})
      end
    end

    test "an updated_since that is not an ISO 8601 datetime" do
      for value <- ["yesterday", "2026-10-05", "", "1759600000", ["2026-01-01T00:00:00Z"]] do
        assert {:error, "Invalid updated_since: must be an ISO 8601 datetime" <> _} =
                 TaskListParams.parse(%{"updated_since" => value}),
               "updated_since #{inspect(value)} should be rejected"
      end
    end

    test "reports the first invalid key in a fixed order" do
      assert {:error, "Invalid limit" <> _} =
               TaskListParams.parse(%{"status" => "bogus", "limit" => "0"})
    end
  end

  describe "filters/1" do
    test "drops nil filters and never includes limit or cursor" do
      {:ok, page} =
        TaskListParams.parse(%{
          "limit" => "5",
          "cursor" => TaskListParams.encode_cursor(3),
          "priority" => "high",
          "parent" => "G1"
        })

      assert TaskListParams.filters(page) == %{priority: :high, parent: "G1"}
    end
  end

  describe "encode_cursor/1" do
    test "returns nil when there is no further page" do
      assert TaskListParams.encode_cursor(nil) == nil
    end

    test "returns an unpadded URL-safe string" do
      cursor = TaskListParams.encode_cursor(1_000_000)
      refute cursor =~ "="
      assert cursor =~ ~r/\A[A-Za-z0-9_-]+\z/
    end
  end

  describe "parse_label/1 (W2239)" do
    test "is nil when label is absent" do
      assert TaskListParams.parse_label(%{}) == {:ok, nil}
      assert TaskListParams.parse_label(%{"column_id" => "1"}) == {:ok, nil}
    end

    test "accepts a label name of 1 to 40 characters, trimmed" do
      assert TaskListParams.parse_label(%{"label" => "Bug"}) == {:ok, "Bug"}
      assert TaskListParams.parse_label(%{"label" => "  needs review "}) == {:ok, "needs review"}

      forty = String.duplicate("é", 40)
      assert TaskListParams.parse_label(%{"label" => forty}) == {:ok, forty}
    end

    test "rejects blank, over-long, non-string and invalid UTF-8 values" do
      for value <- ["", "   ", String.duplicate("x", 41), ["Bug"], %{"k" => "Bug"}, 7, <<255>>] do
        assert TaskListParams.parse_label(%{"label" => value}) ==
                 {:error, "Invalid label: must be a label name of 1 to 40 characters"},
               inspect(value)
      end
    end

    test "label is not a page key" do
      refute TaskListParams.paginated?(%{"label" => "Bug"})
      refute TaskListParams.paginated?(%{"label" => ""})
    end
  end
end
