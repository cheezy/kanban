defmodule Kanban.Mobile.StringAccessorsTest do
  @moduledoc """
  The iOS app's typed accessors for the strings that take arguments (W2788).
  """
  use ExUnit.Case, async: true

  alias Kanban.Mobile.StringAccessors
  alias Kanban.Mobile.Strings

  @root Path.expand("../../..", __DIR__)
  @gettext Path.join(@root, "priv/gettext")

  defp committed, do: @root |> Path.join(StringAccessors.output_path()) |> File.read!()

  # The accessors as the generator renders them now, so a test of their shape
  # fails on the generator itself and not only through the staleness test.
  defp rendered, do: @gettext |> Strings.build!() |> StringAccessors.render()

  defp render(strings, plurals \\ %{}) do
    StringAccessors.render(%{"en" => %{"strings" => strings, "plurals" => plurals}})
  end

  test "the committed accessors match the mobile domain" do
    assert committed() == @gettext |> Strings.build!() |> StringAccessors.render(),
           "#{StringAccessors.output_path()} is stale. " <>
             "Refresh it with: MIX_ENV=test mix mobile.strings"
  end

  test "every string and plural with an argument has an accessor, and no other" do
    %{"strings" => strings, "plurals" => plurals} = Strings.build!(@gettext)["en"]
    functions = Regex.scan(~r/static func (\w+)\(/, rendered(), capture: :all_but_first)

    with_arguments =
      for {key, text} <-
            Enum.to_list(strings) ++ Enum.map(plurals, &{elem(&1, 0), elem(&1, 1)["other"]}),
          String.contains?(text, "{"),
          do: key

    assert length(functions) == length(with_arguments)
    assert rendered() =~ "static func targetRiskSlip(estimate: String, targetDate: String)"
    assert rendered() =~ "static func targetTaskProgress(done: Int, count: Int)"
    assert rendered() =~ "static func targetGoalCount(count: Int)"
  end

  test "render/1 names each argument after its placeholder, in the English order" do
    swift = render(%{"a_b" => "{target_date} then {count}", "plain" => "No arguments"})

    assert swift =~
             ~s|static func aB(targetDate: String, count: Int) -> LocalizedStringResource {\n|

    assert swift =~
             ~s|LocalizedStringResource("a_b", defaultValue: "\\(targetDate) then \\(count, specifier: "%lld")", | <>
               ~s|table: "Localizable", bundle: .main)|

    refute swift =~ "plain"
  end

  test "render/1 escapes the English text for a Swift string literal" do
    swift = render(%{"q" => ~S|Say "{name}" \ done|})

    assert swift =~ ~S|defaultValue: "Say \"\(name)\" \\ done"|
  end

  test "render/1 gives a plural the arguments of its other form" do
    swift = render(%{}, %{"n_goals" => %{"one" => "One goal", "other" => "{count} goals"}})

    assert swift =~ "/// \"{count} goals\"\n    static func nGoals(count: Int)"
  end

  test "render/1 sorts the accessors and ends in a newline" do
    swift = render(%{"b" => "{x}", "a" => "{y}"})

    assert :binary.match(swift, "func a(") < :binary.match(swift, "func b(")
    assert String.ends_with?(swift, "}\n")
    refute String.ends_with?(swift, "\n\n")
  end

  test "output_path/0 is in the app's design system" do
    assert StringAccessors.output_path() == "mobile/ios/Stride/DesignSystem/L10n.swift"
  end
end
