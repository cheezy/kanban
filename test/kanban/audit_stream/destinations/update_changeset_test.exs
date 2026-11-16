defmodule Kanban.AuditStream.Destinations.UpdateChangesetTest do
  use Kanban.DataCase, async: true

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Ecto.Changeset
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Destinations.UpdateChangeset
  alias Kanban.Repo

  setup do
    %{fresh: destination_fixture(organization_fixture(), :splunk_hec)}
  end

  defp unreadable(destination, fields) do
    Enum.each(fields, &make_unreadable!(destination, &1))
    Repo.get!(Destination, destination.id)
  end

  defp build(fresh, attrs), do: UpdateChangeset.build(fresh, fresh.lock_version, attrs, nil)

  describe "attrs/1" do
    test "drops kind, enabled and start_from (atom and string keys) and a blank url or credential" do
      attrs = %{
        :kind => :https,
        :enabled => false,
        :start_from => "now",
        "kind" => "datadog",
        "enabled" => "false",
        "start_from" => "beginning",
        :url => "",
        "credential" => "   ",
        :name => "Renamed"
      }

      assert UpdateChangeset.attrs(attrs) == %{name: "Renamed"}
    end

    test "keeps a nil or blank non-secret field and accepts a keyword list" do
      assert UpdateChangeset.attrs(name: "", url: nil, settings: %{}) == %{
               name: "",
               settings: %{}
             }

      assert UpdateChangeset.attrs(%{"url" => "https://a.invalid/x"}) == %{
               "url" => "https://a.invalid/x"
             }
    end
  end

  describe "build/4" do
    test "an unchanged save at the current lock_version is valid and changes nothing", ctx do
      changeset = build(ctx.fresh, %{})

      assert changeset.valid?
      assert changeset.changes == %{}
    end

    test "with an older lock_version marks the changeset stale even when nothing changes", ctx do
      fresh = %{ctx.fresh | lock_version: 2}
      changeset = UpdateChangeset.build(fresh, 1, %{}, nil)

      refute changeset.valid?
      assert {"is stale", [stale: true]} = changeset.errors[:id]
    end

    test "an unreadable url or credential not re-entered is a can't be blank error", ctx do
      fresh = unreadable(ctx.fresh, [:url, :credential])
      changeset = build(fresh, %{name: "Renamed"})

      refute changeset.valid?

      for field <- [:url, :credential] do
        assert {"can't be blank", [validation: :unreadable]} = changeset.errors[field]
      end

      changeset = build(fresh, %{credential: "splunk-hec-token-new-wxyz"})
      refute Keyword.has_key?(changeset.errors, :credential)
      assert Keyword.has_key?(changeset.errors, :url)
    end

    test "the same excluded_actions in another order is no change and does not bump filter_version",
         ctx do
      [a, b | _rest] = Destination.excludable_actions()
      {:ok, fresh} = ctx.fresh |> Changeset.change(excluded_actions: [a, b]) |> Repo.update()

      changeset = build(fresh, %{excluded_actions: [b, a]})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :excluded_actions)
      refute Map.has_key?(changeset.changes, :filter_version)
    end

    test "changing include_personal_data or excluded_actions bumps filter_version by one", ctx do
      [action | _rest] = Destination.excludable_actions()
      expected = ctx.fresh.filter_version + 1

      for attrs <- [%{include_personal_data: false}, %{excluded_actions: [action]}] do
        assert ctx.fresh |> build(attrs) |> Changeset.get_change(:filter_version) == expected
      end

      refute Map.has_key?(build(ctx.fresh, %{name: "Renamed"}).changes, :filter_version)

      invalid = build(ctx.fresh, %{excluded_actions: ["not_an_action"]})
      refute invalid.valid?
      refute Map.has_key?(invalid.changes, :filter_version)
    end

    test "a url change clears a blocked_address halt", ctx do
      fresh = %{ctx.fresh | halted_reason: :blocked_address}
      changeset = build(fresh, %{url: "https://siem.example.org/services/collector/event"})

      assert {:ok, nil} = Changeset.fetch_change(changeset, :halted_reason)
    end
  end

  describe "clear_halt/2" do
    test "clears blocked_address on a url change, rejected_batch on a filter change and credentials_unreadable once no needed secret is unreadable",
         ctx do
      blocked = %{ctx.fresh | halted_reason: :blocked_address}
      rejected = %{ctx.fresh | halted_reason: :rejected_batch}
      unreadable = %{ctx.fresh | halted_reason: :credentials_unreadable}

      assert cleared?(blocked, url: "https://collector.example.com/x")
      refute cleared?(blocked, name: "Renamed")

      assert cleared?(rejected, include_personal_data: false)
      refute cleared?(rejected, url: "https://collector.example.com/x")

      assert cleared?(unreadable, name: "Renamed")
    end

    test "keeps credentials_unreadable while a needed secret stays unreadable", ctx do
      fresh = %{
        unreadable(ctx.fresh, [:url, :credential])
        | halted_reason: :credentials_unreadable
      }

      refute cleared?(fresh, credential: "splunk-hec-token-new-wxyz")

      assert cleared?(fresh,
               credential: "splunk-hec-token-new-wxyz",
               url: "https://collector.example.com/x"
             )
    end

    test "ignores an unreadable previous signing secret" do
      https = destination_fixture(organization_fixture(), :https)

      {:ok, https} =
        https |> Changeset.change(previous_signing_secret: "assec_previous-1") |> Repo.update()

      fresh = %{
        unreadable(https, [:previous_signing_secret])
        | halted_reason: :credentials_unreadable
      }

      assert cleared?(fresh, name: "Renamed")
    end

    test "never clears txid_reset and leaves an invalid changeset alone", ctx do
      refute cleared?(%{ctx.fresh | halted_reason: :txid_reset},
               url: "https://collector.example.com/x"
             )

      blocked = %{ctx.fresh | halted_reason: :blocked_address}

      invalid =
        blocked
        |> Changeset.change(url: "https://collector.example.com/x")
        |> Changeset.add_error(:name, "is invalid")

      assert UpdateChangeset.clear_halt(invalid, blocked) == invalid
    end
  end

  describe "changed_fields/1" do
    test "lists the changed editable fields in the order the updated event lists them", ctx do
      [action | _rest] = Destination.excludable_actions()
      changeset = Changeset.change(ctx.fresh, excluded_actions: [action], name: "Renamed")

      assert UpdateChangeset.changed_fields(changeset) == [:name, :excluded_actions]
    end

    test "is empty when only non-editable fields change", ctx do
      changeset = Changeset.change(ctx.fresh, filter_version: 9, halted_reason: nil)

      assert UpdateChangeset.changed_fields(changeset) == []
    end
  end

  defp cleared?(fresh, changes) do
    fresh
    |> Changeset.change(changes)
    |> UpdateChangeset.clear_halt(fresh)
    |> Changeset.fetch_change(:halted_reason)
    |> Kernel.==({:ok, nil})
  end
end
