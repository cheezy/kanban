defmodule Kanban.AuditStream.PayloadTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream.Payload

  @organization %{id: 210, name: "Northwind Studio"}
  @inserted_at ~U[2026-11-09 14:02:11.482913Z]

  defp event(overrides \\ %{}) do
    struct!(
      %AuditEvent{
        id: 1_849_230,
        action: "login_failed",
        inserted_at: @inserted_at,
        actor_user_id: 1153,
        actor_user: %User{id: 1153, email: "alex@northwind.example"},
        actor_in_organization: true,
        ip: "203.0.113.24",
        metadata: %{"user_id" => 1153, "organization_id" => 210, "ip" => "203.0.113.24"}
      },
      overrides
    )
  end

  defp build(overrides), do: overrides |> event() |> Payload.build(@organization)

  describe "build/3" do
    test "builds the §6 shape for a member actor" do
      assert Payload.build(event(), @organization, instance: "stride.test") == %{
               "id" => "1849230",
               "schema" => "stride.audit.v1",
               "occurred_at" => "2026-11-09T14:02:11.482913Z",
               "action" => "login_failed",
               "action_label" => "Sign-in failed",
               "organization" => %{"id" => 210, "name" => "Northwind Studio"},
               "actor" => %{
                 "user_id" => 1153,
                 "email" => "alex@northwind.example",
                 "in_organization" => true
               },
               "ip" => "203.0.113.24",
               "metadata" => %{
                 "user_id" => 1153,
                 "organization_id" => 210,
                 "ip" => "203.0.113.24"
               },
               "instance" => "stride.test"
             }
    end

    test "the id is a string, so a 64-bit id survives JavaScript tools" do
      payload = build(%{id: 9_007_199_254_740_993})

      assert payload["id"] == "9007199254740993"
    end

    test "redacted actor has null identity and in_organization false" do
      # What Kanban.AuditLog.OrganizationScope leaves; identity values that
      # survived upstream are still nulled here.
      redacted =
        event(%{
          actor_user_id: nil,
          actor_user: nil,
          ip: "203.0.113.24",
          metadata: %{"organization_id" => 210, "user_id" => 1153},
          actor_redacted: true
        })

      payload = Payload.build(redacted, @organization, instance: "stride.test")

      assert payload["actor"] == %{"user_id" => nil, "email" => nil, "in_organization" => false}
      assert payload["ip"] == nil
    end

    test "a redacted actor is never in the Organization, whatever the stored flag" do
      payload = build(%{actor_redacted: true})

      assert payload["actor"] == %{"user_id" => nil, "email" => nil, "in_organization" => false}
    end

    test "action_label is English under a ja locale" do
      assert Gettext.with_locale(KanbanWeb.Gettext, "ja", fn ->
               KanbanWeb.AuditLogActions.action_label("login_failed")
             end) != "Sign-in failed"

      payload =
        Gettext.with_locale(KanbanWeb.Gettext, "ja", fn ->
          Payload.build(event(), @organization)
        end)

      assert payload["action_label"] == "Sign-in failed"
    end

    test "the active locale is left as it was" do
      Gettext.with_locale(KanbanWeb.Gettext, "ja", fn ->
        Payload.build(event(), @organization)
        assert Gettext.get_locale(KanbanWeb.Gettext) == "ja"
      end)
    end

    test "an action with no label passes through as its raw string" do
      payload = build(%{action: "recorded_by_an_older_release"})

      assert payload["action_label"] == "recorded_by_an_older_release"
    end

    test "deleted actor falls back to metadata user_id with null email" do
      deleted = event(%{actor_user_id: nil, actor_user: nil})

      payload = Payload.build(deleted, @organization)

      assert payload["actor"] == %{"user_id" => 1153, "email" => nil, "in_organization" => true}
    end

    test "in_organization is the stored flag when there is one" do
      payload = build(%{actor_in_organization: false})

      assert payload["actor"]["in_organization"] == false
    end

    test "a row from before the flag existed is a current member when the Reader left it unredacted" do
      payload = build(%{actor_in_organization: nil})

      assert payload["actor"]["in_organization"] == true
    end

    test "an event with no actor is not in the Organization" do
      no_actor =
        event(%{
          actor_user_id: nil,
          actor_user: nil,
          actor_in_organization: nil,
          metadata: %{"organization_id" => 210}
        })

      assert Payload.build(no_actor, @organization)["actor"] == %{
               "user_id" => nil,
               "email" => nil,
               "in_organization" => false
             }
    end

    test "in_organization is always a boolean" do
      for flag <- [true, false, nil], redacted <- [true, false], actor <- [1153, nil] do
        metadata = if actor, do: %{"user_id" => actor}, else: %{}

        payload =
          build(%{
            actor_in_organization: flag,
            actor_redacted: redacted,
            actor_user_id: actor,
            metadata: metadata
          })

        assert is_boolean(payload["actor"]["in_organization"])
      end
    end

    test "event metadata empty map, or nil, is sent as an empty map" do
      assert build(%{metadata: %{}})["metadata"] == %{}
      assert build(%{metadata: nil})["metadata"] == %{}
    end

    test "organization renamed: current name is sent" do
      renamed = %{@organization | name: "Northwind Studio Ltd"}

      assert Payload.build(event(), renamed)["organization"] == %{
               "id" => 210,
               "name" => "Northwind Studio Ltd"
             }
    end

    test "the instance defaults to the endpoint host" do
      assert Payload.build(event(), @organization)["instance"] == KanbanWeb.Endpoint.host()
    end

    test "the payload encodes as JSON and decodes to itself" do
      payload = Payload.build(event(), @organization)

      assert payload |> Jason.encode!() |> Jason.decode!() == payload
    end
  end

  test "schema/0 names the version" do
    assert Payload.schema() == "stride.audit.v1"
  end

  test "organization/1 keeps only the id and name" do
    assert Payload.organization(%{id: 7, name: "Acme", slug: "acme"}) == %{
             "id" => 7,
             "name" => "Acme"
           }
  end
end
