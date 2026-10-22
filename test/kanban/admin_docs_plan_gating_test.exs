defmodule Kanban.AdminDocsPlanGatingTest do
  @moduledoc """
  Guards how the Organization admin docs describe paid access (W2431).

  `Kanban.Plans` refuses a paid feature only while `:plans_enforced` is on, so
  a doc that says single sign-on "checks paid access" without saying when it
  refuses misleads an org-admin on a deployment with enforcement off. Single
  sign-on is the only paid feature of the three admin docs; SCIM and the
  security policy page never call `Kanban.Plans`, so their docs must not
  describe a paid gate.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  describe "docs/single-sign-on.md" do
    test "the paid-access section says the refusal applies only while plans are enforced" do
      section = section(read("docs/single-sign-on.md"), "## Paid access and rate limits")

      assert section =~ "`:plans_enforced`"
      assert section =~ "only while paid plans\nare enforced"
      assert section =~ "With\nenforcement off, nothing is refused."
    end
  end

  describe "the SCIM and security policy docs" do
    test "describe no paid gate, because neither feature checks Kanban.Plans" do
      for doc <- ["docs/scim-provisioning.md", "docs/organization-security-policies.md"] do
        text = read(doc)

        refute text =~ "Kanban.Plans", "#{doc} names Kanban.Plans"
        refute text =~ ~r/paid (feature|access|plan)/i, "#{doc} describes a paid gate"
      end
    end
  end

  defp read(relative), do: @root |> Path.join(relative) |> File.read!()

  # The text from `heading` up to the next level-two heading.
  defp section(text, heading) do
    [_, rest] = String.split(text, heading <> "\n", parts: 2)
    rest |> String.split(~r/^## /m, parts: 2) |> hd()
  end
end
