defmodule Kanban.Tasks.CompletionValidation.FieldsTest do
  @moduledoc """
  Direct unit tests for the shared field primitives (W1953).

  These were private to `CompletionValidation` before the split, so their
  behaviour was only ever observed through whichever enum happened to call
  them. Now that `check_enum/6` is a named primitive taking an allow-list as a
  *parameter*, its three decode verdicts and its atom-safety guarantee deserve
  to be pinned directly rather than incidentally.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionValidation.Fields

  describe "check_enum/6 — decode verdicts" do
    test "a member of the allow-list adds no error" do
      assert Fields.check_enum([], %{"status" => "passed"}, "status", [:passed, :failed], :f, "p") ==
               []
    end

    test "an atom member is accepted as well as its string form" do
      assert Fields.check_enum([], %{"status" => :passed}, "status", [:passed, :failed], :f, "p") ==
               []
    end

    test "an absent key reports the missing message with the entry prefix" do
      assert Fields.check_enum([], %{}, "status", [:passed, :failed], :f, "issues[0]") ==
               [{:f, "issues[0] is missing status"}]
    end

    test "a value outside the allow-list reports the allow-list verbatim" do
      assert Fields.check_enum([], %{"s" => "nope"}, "s", [:passed, :failed], :f, "issues[0]") ==
               [{:f, "issues[0] s must be one of: passed, failed"}]
    end

    test "a non-string, non-atom value is invalid rather than raising" do
      assert Fields.check_enum([], %{"s" => 42}, "s", [:passed], :f, "p") ==
               [{:f, "p s must be one of: passed"}]
    end

    test "errors are prepended to the accumulator, which is left unreversed" do
      assert Fields.check_enum([{:earlier, "first"}], %{}, "s", [:passed], :f, "p") ==
               [{:f, "p is missing s"}, {:earlier, "first"}]
    end
  end

  describe "check_enum/6 — atom safety" do
    test "an unknown string is rejected without minting an atom" do
      # The whole point of String.to_existing_atom/1 + rescue: a payload can
      # name anything it likes and the atom table must not grow.
      unknown = "definitely_not_an_existing_atom_#{System.unique_integer([:positive])}"

      assert Fields.check_enum([], %{"s" => unknown}, "s", [:passed], :f, "p") ==
               [{:f, "p s must be one of: passed"}]

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  describe "check_section_status/4" do
    test "accepts every section verdict" do
      for status <- ["passed", "failed", "not_assessed"] do
        assert Fields.check_section_status([], %{"status" => status}, :f, "testing_strategy") ==
                 []
      end
    end

    test "reports the section-status allow-list verbatim" do
      assert Fields.check_section_status([], %{"status" => "maybe"}, :f, "testing_strategy") ==
               [{:f, "testing_strategy status must be one of: passed, failed, not_assessed"}]
    end
  end

  describe "check_section_notes/3" do
    test "absent notes are accepted" do
      assert Fields.check_section_notes([], %{}, "patterns") == []
    end

    test "a string is accepted" do
      assert Fields.check_section_notes([], %{"notes" => "ok"}, "patterns") == []
    end

    test "a non-string is rejected, naming the section key" do
      assert Fields.check_section_notes([], %{"notes" => 1}, "patterns") ==
               [{:notes, "patterns.notes must be a string"}]
    end
  end
end
