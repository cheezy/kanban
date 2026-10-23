defmodule Kanban.ReadmePlanClaimsTest do
  @moduledoc """
  Guards the README's claims that hold only while paid plans are enforced
  (W2424).

  `Kanban.Plans` gates its paid features and drops its locked task fields only
  when `STRIDE_PLANS_ENFORCED=true`. A README sentence about either must say
  so, or it describes a deployment that does not exist. These tests read the
  README and fail when such a sentence loses its qualifier, or when a field
  `Kanban.Plans.locked_task_fields/0` locks is no longer described as locked.
  The paid-features paragraph must also keep the features that always need an
  Organization (W2435) apart from the ones gated only by enforcement.
  """
  use ExUnit.Case, async: true

  @readme Path.expand("../../README.md", __DIR__)

  setup_all do
    %{readme: File.read!(@readme)}
  end

  describe "the paid-features paragraph" do
    test "names the variable that turns enforcement on", %{readme: readme} do
      paragraph = paragraph_containing(readme, "plan's paid features are")

      assert paragraph =~ "STRIDE_PLANS_ENFORCED=true"
      assert paragraph =~ "open to everyone until"
    end

    # W2435: workspaces, single sign-on and the audit log belong to an
    # Organization, so they need one whether or not plans are enforced; only
    # the other paid features are open to everyone until enforcement is on.
    test "says which features need an Organization in either mode", %{readme: readme} do
      paragraph =
        readme |> paragraph_containing("plan's paid features are") |> String.replace("\n", " ")

      [always, _gated] = String.split(paragraph, "The others are open to", parts: 2)
      always = always |> String.split("MCP server.", parts: 2) |> List.last()

      assert always =~ "always need an Organization"

      for feature <- ["Workspaces", "single sign-on", "audit log"] do
        assert always =~ feature, "README.md does not say #{feature} always needs an Organization"
      end
    end
  end

  describe "the locked task fields" do
    test "every field Kanban.Plans locks is described as stored only while plans are enforced",
         %{readme: readme} do
      note = list_item_containing(readme, "While paid plans are\n  enforced")

      fields = Kanban.Plans.locked_task_fields()
      assert fields != []

      for field <- fields do
        assert note =~ "`#{field}`",
               "README's locked-field note does not name `#{field}`"
      end
    end
  end

  defp paragraph_containing(text, marker),
    do: find_chunk(String.split(text, ~r/\n\s*\n/), marker, "paragraph")

  # One top-level list item: the text from a line starting "- " up to the next.
  defp list_item_containing(text, marker),
    do: find_chunk(String.split(text, ~r/\n(?=- )/), marker, "list item")

  defp find_chunk(chunks, marker, kind) do
    case Enum.find(chunks, &String.contains?(&1, marker)) do
      nil -> flunk("README.md has no #{kind} containing #{inspect(marker)}")
      chunk -> chunk
    end
  end
end
