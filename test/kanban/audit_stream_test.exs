defmodule Kanban.AuditStreamTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.AuditStream.Reader
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Webhooks.UrlGuard

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    %{organization: organization, admin: admin, scope: Scope.for_user(admin)}
  end

  defp create!(ctx, kind, overrides \\ %{}) do
    {:ok, {destination, secret}} =
      AuditStream.create_destination(ctx.scope, destination_attrs(kind, overrides))

    {destination, secret}
  end

  defp reload(destination), do: Repo.get!(Destination, destination.id)
  defp cursor(destination), do: Repo.get!(Cursor, destination.id)

  defp events(organization_id, action) do
    from(e in AuditEvent,
      where: e.organization_id == ^organization_id and e.action == ^Atom.to_string(action),
      order_by: e.id
    )
    |> Repo.all()
  end

  defp own_txid do
    %{rows: [[txid]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    txid
  end

  defp raw_column(id, column) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM audit_stream_destinations WHERE id = $1", [id])

    value
  end

  defp count_destinations(organization_id) do
    from(d in Destination, where: d.organization_id == ^organization_id) |> Repo.aggregate(:count)
  end

  defp halt!(destination, reason) do
    destination |> Destination.status_changeset(%{halted_reason: reason}) |> Repo.update!()
  end

  defp disable!(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  describe "create_destination/3" do
    test "create of each kind stores encrypted secrets and the right cursor", ctx do
      for kind <- Destination.kinds() do
        attrs = destination_attrs(kind)
        {:ok, {destination, secret}} = AuditStream.create_destination(ctx.scope, attrs)

        stored = reload(destination)

        for field <- [:url, :credential], value = Map.get(attrs, field), value != nil do
          refute raw_column(destination.id, field) =~ value
          assert Map.fetch!(stored, field) == value
        end

        assert %Cursor{last_event_id: 0, not_before: nil} = cursor(destination)
        assert stored.organization_id == ctx.organization.id
        assert stored.created_by_id == ctx.admin.id
        assert stored.enabled

        if kind == :https do
          assert secret =~ ~r/\Aassec_[A-Za-z0-9_-]{43}\z/
          assert destination.signing_secret == nil
          assert stored.signing_secret == secret
          refute raw_column(destination.id, :signing_secret) =~ secret
        else
          assert secret == nil
          assert stored.signing_secret == nil
        end
      end
    end

    test "start points now, 24h, 7d, all and Datadog's 17h set the cursor and not_before",
         ctx do
      {now, _secret} = create!(ctx, :splunk_hec, %{start_from: "now"})
      %Cursor{last_txid: horizon, last_event_id: 0, not_before: nil} = cursor(now)
      assert horizon > 0 and horizon <= own_txid()
      # Deleted as each is checked, to stay under the destination limit.
      {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, now)

      for {kind, start_from, seconds} <- [
            {:splunk_hec, "24h", 86_400},
            {:https, "7d", 604_800},
            {:datadog, "17h", 61_200}
          ] do
        {destination, _secret} = create!(ctx, kind, %{"start_from" => start_from})
        cursor = cursor(destination)

        assert {cursor.last_txid, cursor.last_event_id} == {0, 0}
        assert_in_delta DateTime.diff(cursor.not_before, DateTime.utc_now()), -seconds, 60
        {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, destination)
      end

      {all, _secret} = create!(ctx, :https, %{start_from: :all})
      assert %Cursor{last_txid: 0, last_event_id: 0, not_before: nil} = cursor(all)
    end

    test "start_from defaults to now", ctx do
      {destination, _secret} = create!(ctx, :datadog)
      assert cursor(destination).last_txid > 0
    end

    test "Datadog refuses 24h, 7d and all, and the others refuse 17h", ctx do
      refused =
        for start_from <- ~w(24h 7d all), do: {:datadog, start_from}

      for {kind, start_from} <- refused ++ [{:splunk_hec, "17h"}, {:https, "1y"}] do
        attrs = destination_attrs(kind, %{start_from: start_from})
        assert {:error, changeset} = AuditStream.create_destination(ctx.scope, attrs)
        assert "is invalid" in errors_on(changeset).start_from
      end

      assert count_destinations(ctx.organization.id) == 0
      assert events(ctx.organization.id, :audit_stream_destination_created) == []
    end

    test "create at the limit is refused", ctx do
      max = Destination.max_destinations()
      for _n <- 1..(max - 1)//1, do: destination_fixture(ctx.organization, :datadog)

      assert {:ok, _created} =
               AuditStream.create_destination(ctx.scope, destination_attrs(:datadog))

      assert {:error, :limit_reached} =
               AuditStream.create_destination(ctx.scope, destination_attrs(:datadog))

      assert count_destinations(ctx.organization.id) == max
      assert length(events(ctx.organization.id, :audit_stream_destination_created)) == 1
    end

    test "UrlGuard-blocked URL is refused", ctx do
      for {kind, host, reason} <- [
            {:splunk_hec, "internal.example.com", :blocked_address},
            {:https, "metadata.example.com", :blocked_address},
            {:https, "nowhere.example.net", :unresolvable}
          ] do
        attrs = destination_attrs(kind, %{url: "https://#{host}/services/collector"})
        assert {:error, changeset} = AuditStream.create_destination(ctx.scope, attrs)
        assert UrlGuard.error_message(reason) in errors_on(changeset).url
      end

      assert count_destinations(ctx.organization.id) == 0
      assert events(ctx.organization.id, :audit_stream_destination_created) == []
    end

    test "a new destination is always enabled", ctx do
      {destination, _secret} = create!(ctx, :datadog, %{enabled: false})
      assert reload(destination).enabled
    end

    test "a duplicate name is refused and leaves nothing behind", ctx do
      {first, _secret} = create!(ctx, :datadog)

      assert {:error, changeset} =
               AuditStream.create_destination(
                 ctx.scope,
                 destination_attrs(:datadog, %{name: first.name})
               )

      assert errors_on(changeset).name != []
      assert count_destinations(ctx.organization.id) == 1
      assert length(events(ctx.organization.id, :audit_stream_destination_created)) == 1
    end

    test "the created event is returned by Reader.next_batch", ctx do
      {destination, _secret} = create!(ctx, :splunk_hec, %{start_from: "now"})
      cursor = cursor(destination)
      [created] = events(ctx.organization.id, :audit_stream_destination_created)

      batch =
        Reader.next_batch(ctx.organization.id, {cursor.last_txid, cursor.last_event_id},
          horizon: own_txid() + 1
        )

      assert created.id in Enum.map(batch, & &1.id)
      assert created.metadata["destination_id"] == destination.id
      assert {created.txid, created.id} > {cursor.last_txid, cursor.last_event_id}
    end
  end

  describe "authorization" do
    setup ctx do
      {destination, _secret} = create!(ctx, :https)
      %{destination: destination}
    end

    defp every_call(scope, destination),
      do: management_calls(scope, destination) ++ delivery_calls(scope, destination)

    defp management_calls(scope, destination) do
      [
        list: fn -> AuditStream.list_destinations(scope) end,
        get: fn -> AuditStream.get_destination(scope, destination.id) end,
        create: fn -> AuditStream.create_destination(scope, destination_attrs(:datadog)) end,
        update: fn -> AuditStream.update_destination(scope, destination, %{name: "Renamed"}) end,
        pause: fn -> AuditStream.pause_destination(scope, destination) end,
        resume: fn -> AuditStream.resume_destination(scope, destination) end,
        rotate: fn -> AuditStream.rotate_signing_secret(scope, destination) end,
        delete: fn -> AuditStream.delete_destination(scope, destination) end
      ]
    end

    defp delivery_calls(scope, destination) do
      [
        status: fn -> AuditStream.destination_status(scope, destination) end,
        attempts: fn -> AuditStream.list_attempts(scope, destination) end,
        gaps: fn -> AuditStream.list_gaps(scope, destination) end,
        pending: fn -> AuditStream.pending_batch_summary(scope, destination) end,
        test: fn -> AuditStream.send_test_event(scope, destination) end,
        retry: fn -> AuditStream.retry_now(scope, destination) end,
        skip: fn -> AuditStream.skip_batch(scope, destination) end
      ]
    end

    test "non-org-admin, site admin and other Organization's org-admin are refused", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member, :member)

      disabled = user_fixture()
      organization_member_fixture(ctx.organization, disabled, :org_admin)
      disable!(disabled)

      refused_scopes = [
        Scope.for_user(member),
        Scope.for_user(user_fixture()),
        Scope.for_user(disabled),
        Scope.for_user(admin_fixture()),
        nil
      ]

      for scope <- refused_scopes, {name, call} <- every_call(scope, ctx.destination) do
        assert {name, {:error, :unauthorized}} == {name, call.()}
      end

      other_organization = organization_fixture()
      other_admin = user_fixture()
      organization_member_fixture(other_organization, other_admin, :org_admin)
      other_scope = Scope.for_user(other_admin)

      for {name, call} <- every_call(other_scope, ctx.destination),
          name not in [:list, :create] do
        assert {name, {:error, :not_found}} == {name, call.()}
      end

      assert {:ok, []} = AuditStream.list_destinations(other_scope)
      assert {:ok, {created, nil}} = every_call(other_scope, ctx.destination)[:create].()
      assert created.organization_id == other_organization.id

      stored = reload(ctx.destination)
      assert stored.name == ctx.destination.name
      assert stored.enabled
    end

    test "an org-admin demoted between load and save is refused", ctx do
      {:ok, loaded} = AuditStream.get_destination(ctx.scope, ctx.destination.id)

      from(m in OrganizationMember, where: m.user_id == ^ctx.admin.id)
      |> Repo.update_all(set: [role: :member])

      assert {:error, :unauthorized} =
               AuditStream.update_destination(ctx.scope, loaded, %{name: "Renamed"})
    end

    test "a destination deleted while being edited is not found", ctx do
      {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, ctx.destination)

      assert {:error, :not_found} =
               AuditStream.update_destination(ctx.scope, ctx.destination, %{name: "Renamed"})

      assert {:error, :not_found} = AuditStream.get_destination(ctx.scope, ctx.destination.id)
    end

    test "an id that is not an integer is not found", ctx do
      assert {:error, :not_found} = AuditStream.get_destination(ctx.scope, "nope")
      assert {:error, :not_found} = AuditStream.get_destination(ctx.scope, nil)
    end

    test "list_destinations returns the Organization's destinations oldest first", ctx do
      {second, _secret} = create!(ctx, :datadog)
      assert {:ok, listed} = AuditStream.list_destinations(ctx.scope)
      assert Enum.map(listed, & &1.id) == [ctx.destination.id, second.id]
    end
  end

  test "an Organization with no destinations lists none", ctx do
    assert {:ok, []} = AuditStream.list_destinations(ctx.scope)
  end

  describe "change_destination/3" do
    test "builds the form changeset and ignores the kind of a saved destination", ctx do
      assert %Ecto.Changeset{valid?: true} =
               AuditStream.change_destination(
                 ctx.scope,
                 %Destination{},
                 destination_attrs(:datadog)
               )

      {destination, _secret} = create!(ctx, :splunk_hec)

      changeset =
        AuditStream.change_destination(ctx.scope, destination, %{kind: :https, credential: ""})

      assert changeset.changes == %{}
    end
  end

  describe "update_destination/4" do
    test "update with stale lock_version fails and blank secret keeps the old one", ctx do
      {destination, _secret} = create!(ctx, :splunk_hec)
      original = reload(destination)

      assert {:ok, renamed} =
               AuditStream.update_destination(ctx.scope, destination, %{
                 name: "Renamed",
                 url: "",
                 credential: nil
               })

      stored = reload(renamed)
      assert stored.name == "Renamed"
      assert stored.url == original.url
      assert stored.credential == original.credential

      [updated] = events(ctx.organization.id, :audit_stream_destination_updated)
      assert updated.metadata["changed"] == ["name"]

      assert {:error, changeset} =
               AuditStream.update_destination(ctx.scope, destination, %{name: "Again"})

      assert "is stale" in errors_on(changeset).id
      assert reload(destination).name == "Renamed"
    end

    test "a stale save that changes nothing is refused too", ctx do
      {destination, _secret} = create!(ctx, :datadog)
      {:ok, renamed} = AuditStream.update_destination(ctx.scope, destination, %{name: "Renamed"})

      for attrs <- [%{}, %{name: "Renamed"}] do
        assert {:error, changeset} = AuditStream.update_destination(ctx.scope, destination, attrs)
        assert "is stale" in errors_on(changeset).id
      end

      assert {:ok, unchanged} = AuditStream.update_destination(ctx.scope, renamed, %{})
      assert unchanged.lock_version == reload(destination).lock_version
      assert [_one] = events(ctx.organization.id, :audit_stream_destination_updated)
    end

    test "the kind and enabled are not changed by an update", ctx do
      {destination, _secret} = create!(ctx, :https)

      assert {:ok, _updated} =
               AuditStream.update_destination(ctx.scope, destination, %{
                 "kind" => "datadog",
                 "enabled" => false,
                 "name" => "Renamed"
               })

      stored = reload(destination)
      assert {stored.kind, stored.enabled, stored.name} == {:https, true, "Renamed"}
    end

    test "a changed URL is checked and clears a blocked_address halt", ctx do
      {destination, _secret} = create!(ctx, :https)
      halt!(destination, :blocked_address)

      assert {:ok, renamed} = AuditStream.update_destination(ctx.scope, destination, %{name: "N"})
      assert reload(renamed).halted_reason == :blocked_address

      assert {:error, changeset} =
               AuditStream.update_destination(ctx.scope, renamed, %{
                 url: "https://internal.example.com/services/collector"
               })

      assert UrlGuard.error_message(:blocked_address) in errors_on(changeset).url

      assert {:ok, moved} =
               AuditStream.update_destination(ctx.scope, renamed, %{
                 url: "https://collector.example.com/services/collector"
               })

      stored = reload(moved)
      assert stored.halted_reason == nil
      assert stored.url_host == "collector.example.com"
    end

    test "changing excluded_actions bumps filter_version once; an unchanged save does not",
         ctx do
      [first, second | _rest] = Destination.excludable_actions()
      {destination, _secret} = create!(ctx, :datadog)
      assert destination.filter_version == 1

      {:ok, d} =
        AuditStream.update_destination(ctx.scope, destination, %{
          excluded_actions: [first, second]
        })

      assert d.filter_version == 2

      {:ok, d} =
        AuditStream.update_destination(ctx.scope, d, %{excluded_actions: [first, second]})

      assert d.filter_version == 2

      {:ok, d} =
        AuditStream.update_destination(ctx.scope, d, %{excluded_actions: [second, first]})

      assert d.filter_version == 2

      {:ok, d} = AuditStream.update_destination(ctx.scope, d, %{name: "Renamed"})
      assert d.filter_version == 2
      assert reload(d).filter_version == 2

      changed =
        for e <- events(ctx.organization.id, :audit_stream_destination_updated),
            do: e.metadata["changed"]

      assert changed == [["excluded_actions"], ["name"]]
    end

    test "toggling include_personal_data bumps filter_version", ctx do
      [action | _rest] = Destination.excludable_actions()
      {destination, _secret} = create!(ctx, :datadog)

      {:ok, d} =
        AuditStream.update_destination(ctx.scope, destination, %{include_personal_data: false})

      assert d.filter_version == 2

      {:ok, d} =
        AuditStream.update_destination(ctx.scope, d, %{
          include_personal_data: true,
          excluded_actions: [action]
        })

      assert reload(d).filter_version == 3

      [_first, both] = events(ctx.organization.id, :audit_stream_destination_updated)
      assert both.metadata["changed"] == ["include_personal_data", "excluded_actions"]
    end

    test "two org-admins saving filter changes at once: the second is stale", ctx do
      [action | _rest] = Destination.excludable_actions()
      other = user_fixture()
      organization_member_fixture(ctx.organization, other, :org_admin)
      {destination, _secret} = create!(ctx, :datadog)

      assert {:ok, _saved} =
               AuditStream.update_destination(ctx.scope, destination, %{
                 excluded_actions: [action]
               })

      assert {:error, changeset} =
               other
               |> Scope.for_user()
               |> AuditStream.update_destination(destination, %{
                 include_personal_data: false
               })

      assert "is stale" in errors_on(changeset).id
      stored = reload(destination)
      assert {stored.filter_version, stored.include_personal_data} == {2, true}
    end

    test "a save that changes nothing records no event", ctx do
      {destination, _secret} = create!(ctx, :datadog)

      assert {:ok, _same} =
               AuditStream.update_destination(ctx.scope, destination, %{name: destination.name})

      assert events(ctx.organization.id, :audit_stream_destination_updated) == []
    end

    test "update refuses to keep an unreadable credential and accepts a new value, clearing a credentials_unreadable halt",
         ctx do
      {destination, _secret} = create!(ctx, :splunk_hec)
      make_unreadable!(destination, :credential)
      halt!(destination, :credentials_unreadable)

      for attrs <- [%{name: "Renamed"}, %{credential: "  "}] do
        assert {:error, changeset} = AuditStream.update_destination(ctx.scope, destination, attrs)
        assert "can't be blank" in errors_on(changeset).credential
      end

      assert {:ok, updated} =
               AuditStream.update_destination(ctx.scope, destination, %{
                 credential: "a-brand-new-hec-token-1234"
               })

      stored = reload(updated)
      assert stored.credential == "a-brand-new-hec-token-1234"
      assert stored.halted_reason == nil
    end

    test "re-entering only one of two unreadable secrets still fails; both clears the halt",
         ctx do
      {destination, _secret} = create!(ctx, :splunk_hec)
      make_unreadable!(destination, :url)
      make_unreadable!(destination, :credential)
      halt!(destination, :credentials_unreadable)
      url = "https://collector.example.com/services/collector/event"

      assert {:error, changeset} =
               AuditStream.update_destination(ctx.scope, destination, %{url: url})

      assert changeset |> errors_on() |> Map.keys() == [:credential]

      assert {:ok, updated} =
               AuditStream.update_destination(ctx.scope, destination, %{
                 url: url,
                 credential: "a-brand-new-hec-token-5678"
               })

      assert reload(updated).halted_reason == nil
    end

    test "an unreadable signing secret keeps the halt until rotation", ctx do
      {destination, _secret} = create!(ctx, :https)
      make_unreadable!(destination, :signing_secret)
      halt!(destination, :credentials_unreadable)

      assert {:ok, renamed} = AuditStream.update_destination(ctx.scope, destination, %{name: "N"})
      assert reload(renamed).halted_reason == :credentials_unreadable
    end
  end

  describe "rejected_batch halts" do
    setup ctx do
      {destination, _secret} = create!(ctx, :splunk_hec)

      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(
        set: [
          pending_batch_id: Ecto.UUID.generate(),
          pending_first_txid: 5,
          pending_first_id: 1,
          pending_last_txid: 5,
          pending_last_id: 1,
          pending_attempts: 3,
          pending_filter_version: 1
        ]
      )

      %{destination: destination}
    end

    defp dispatch_jobs(destination),
      do: all_enqueued(worker: DispatchWorker, args: %{destination_id: destination.id})

    test "skip_batch is refused while a dispatch run holds the destination's lease", ctx do
      halt!(ctx.destination, :rejected_batch)
      token = Ecto.UUID.generate()
      leased_until = DateTime.add(DateTime.utc_now(), 40, :second)

      from(c in Cursor, where: c.destination_id == ^ctx.destination.id)
      |> Repo.update_all(set: [lease_token: token, leased_until: leased_until])

      before = cursor(ctx.destination)

      assert {:error, :busy} = AuditStream.skip_batch(ctx.scope, ctx.destination)
      assert {:error, :busy} = AuditStream.retry_now(ctx.scope, ctx.destination)

      # Neither moved the cursor nor touched the run's lease.
      assert cursor(ctx.destination) == before
      assert reload(ctx.destination).halted_reason == :rejected_batch
      assert events(ctx.organization.id, :audit_stream_batch_skipped) == []
      assert dispatch_jobs(ctx.destination) == []
    end

    test "a filter change clears a rejected_batch halt and enqueues a dispatch job", ctx do
      [action | _rest] = Destination.excludable_actions()

      for {attrs, version} <- [
            {%{excluded_actions: [action]}, 2},
            {%{include_personal_data: false}, 3}
          ] do
        halt!(ctx.destination, :rejected_batch)
        destination = reload(ctx.destination)

        assert {:ok, updated} = AuditStream.update_destination(ctx.scope, destination, attrs)
        assert {updated.halted_reason, updated.filter_version} == {nil, version}
        assert [_job] = dispatch_jobs(ctx.destination)
      end

      # Still audited: it is not a silent Skip this batch.
      changed =
        for e <- events(ctx.organization.id, :audit_stream_destination_updated),
            do: e.metadata["changed"]

      assert changed == [["excluded_actions"], ["include_personal_data"]]
    end

    test "a filter change leaves a txid_reset halt in place", ctx do
      # credentials_unreadable is left out: a save that leaves every secret
      # readable clears it, whatever it changes.
      for reason <- [:txid_reset, :blocked_address] do
        halt!(ctx.destination, reason)
        destination = reload(ctx.destination)
        personal = not destination.include_personal_data

        assert {:ok, updated} =
                 AuditStream.update_destination(ctx.scope, destination, %{
                   include_personal_data: personal
                 })

        assert {reason, updated.halted_reason} == {reason, reason}
      end

      assert dispatch_jobs(ctx.destination) == []
    end

    test "a change to anything but the filters keeps a rejected_batch halt", ctx do
      halt!(ctx.destination, :rejected_batch)

      assert {:ok, renamed} =
               AuditStream.update_destination(ctx.scope, ctx.destination, %{name: "Renamed"})

      assert renamed.halted_reason == :rejected_batch
      assert cursor(ctx.destination).pending_attempts == 3
      assert dispatch_jobs(ctx.destination) == []
    end
  end

  describe "pause, resume and delete" do
    test "pause and resume toggle enabled and record every call", ctx do
      {destination, _secret} = create!(ctx, :datadog)

      assert {:ok, %Destination{enabled: false}} =
               AuditStream.pause_destination(ctx.scope, destination)

      assert {:ok, %Destination{enabled: false}} =
               AuditStream.pause_destination(ctx.scope, destination)

      assert {:ok, %Destination{enabled: true}} =
               AuditStream.resume_destination(ctx.scope, destination)

      assert length(events(ctx.organization.id, :audit_stream_destination_paused)) == 2
      assert length(events(ctx.organization.id, :audit_stream_destination_resumed)) == 1
      assert reload(destination).enabled
    end

    test "delete cascades to cursor, attempts and gaps", ctx do
      {destination, _secret} = create!(ctx, :https)
      now = DateTime.utc_now()

      %Attempt{}
      |> Attempt.changeset(%{
        destination_id: destination.id,
        batch_id: Ecto.UUID.generate(),
        started_at: now,
        outcome: :delivered
      })
      |> Repo.insert!()

      %Gap{}
      |> Gap.changeset(%{
        destination_id: destination.id,
        reason: :too_old,
        first_occurred_at: now,
        last_occurred_at: now,
        opened_at: now,
        last_extended_at: now
      })
      |> Repo.insert!()

      assert {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, destination)

      assert Repo.get(Destination, destination.id) == nil
      assert Repo.get(Cursor, destination.id) == nil
      refute from(a in Attempt, where: a.destination_id == ^destination.id) |> Repo.exists?()
      refute from(g in Gap, where: g.destination_id == ^destination.id) |> Repo.exists?()

      [deleted] = events(ctx.organization.id, :audit_stream_destination_deleted)
      assert deleted.metadata["destination_id"] == destination.id
    end
  end

  describe "rotate_signing_secret/2" do
    test "no result but create's and rotate's carries a signing secret", ctx do
      {destination, secret} = create!(ctx, :https)
      {:ok, {rotated, new_secret}} = AuditStream.rotate_signing_secret(ctx.scope, destination)

      assert {reload(rotated).signing_secret, reload(rotated).previous_signing_secret} ==
               {new_secret, secret}

      {:ok, [listed]} = AuditStream.list_destinations(ctx.scope)
      {:ok, got} = AuditStream.get_destination(ctx.scope, destination.id)
      {:ok, updated} = AuditStream.update_destination(ctx.scope, rotated, %{name: "Renamed"})
      {:error, stale} = AuditStream.update_destination(ctx.scope, rotated, %{name: "Stale"})
      {:error, stale_rotate} = AuditStream.rotate_signing_secret(ctx.scope, rotated)
      {:ok, paused} = AuditStream.pause_destination(ctx.scope, updated)
      {:ok, resumed} = AuditStream.resume_destination(ctx.scope, paused)
      {:ok, deleted} = AuditStream.delete_destination(ctx.scope, resumed)

      for returned <-
            [destination, rotated, listed, got, updated, paused, resumed, deleted] ++
              [stale.data, stale_rotate.data] do
        assert {returned.signing_secret, returned.previous_signing_secret} == {nil, nil}
      end

      for changeset <- [stale, stale_rotate] do
        assert Map.take(changeset.changes, [:signing_secret, :previous_signing_secret]) == %{}
        params = Map.values(changeset.params || %{})
        refute secret in params or new_secret in params
      end
    end

    test "an unreadable signing secret is still reported as unreadable", ctx do
      {destination, _secret} = create!(ctx, :https)
      make_unreadable!(destination, :signing_secret)

      assert {:ok, got} = AuditStream.get_destination(ctx.scope, destination.id)
      assert got.signing_secret == :unreadable
      assert :signing_secret in Destination.unreadable_secrets(got)
    end

    test "rotate keeps the previous secret for 24 hours", ctx do
      {destination, old_secret} = create!(ctx, :https)

      assert {:ok, {rotated, new_secret}} =
               AuditStream.rotate_signing_secret(ctx.scope, destination)

      assert new_secret =~ ~r/\Aassec_[A-Za-z0-9_-]{43}\z/
      assert new_secret != old_secret
      assert rotated.signing_secret == nil
      assert rotated.previous_signing_secret == nil

      stored = reload(rotated)
      assert stored.signing_secret == new_secret
      assert stored.previous_signing_secret == old_secret

      assert_in_delta DateTime.diff(stored.previous_secret_expires_at, DateTime.utc_now()),
                      86_400,
                      60

      assert {:error, changeset} = AuditStream.rotate_signing_secret(ctx.scope, destination)
      assert "is stale" in errors_on(changeset).id
      assert reload(rotated).signing_secret == new_secret
    end

    test "rotate on a Splunk destination is refused", ctx do
      {destination, _secret} = create!(ctx, :splunk_hec)
      assert {:error, :not_https} = AuditStream.rotate_signing_secret(ctx.scope, destination)
      assert events(ctx.organization.id, :audit_stream_signing_secret_rotated) == []
    end

    test "rotate_secret with an unreadable signing secret leaves no previous secret and clears the halt",
         ctx do
      {destination, _secret} = create!(ctx, :https)
      make_unreadable!(destination, :signing_secret)
      halt!(destination, :credentials_unreadable)

      assert {:ok, {rotated, new_secret}} =
               AuditStream.rotate_signing_secret(ctx.scope, destination)

      stored = reload(rotated)
      assert stored.signing_secret == new_secret
      assert stored.previous_signing_secret == nil
      assert stored.previous_secret_expires_at == nil
      assert stored.halted_reason == nil
    end

    test "rotate drops an unreadable previous secret", ctx do
      {destination, first} = create!(ctx, :https)
      {:ok, {rotated, second}} = AuditStream.rotate_signing_secret(ctx.scope, destination)
      make_unreadable!(rotated, :previous_signing_secret)

      assert {:ok, {again, _third}} =
               AuditStream.rotate_signing_secret(ctx.scope, reload(rotated))

      stored = reload(again)
      assert stored.previous_signing_secret == second
      refute stored.previous_signing_secret == first
    end
  end

  describe "audit metadata" do
    test "each operation records its audit event with no secret in metadata", ctx do
      {https, first_secret} = create!(ctx, :https)
      {splunk, nil} = create!(ctx, :splunk_hec)
      stored_splunk = reload(splunk)

      {:ok, https} =
        AuditStream.update_destination(ctx.scope, https, %{
          url: "https://siem.example.org/ingest/changed?path-token=efgh"
        })

      {:ok, {https, second_secret}} = AuditStream.rotate_signing_secret(ctx.scope, https)
      {:ok, https} = AuditStream.pause_destination(ctx.scope, https)
      {:ok, https} = AuditStream.resume_destination(ctx.scope, https)
      {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, https)

      secrets = [
        first_secret,
        second_secret,
        stored_splunk.url,
        stored_splunk.credential,
        "path-token"
      ]

      expected = %{
        audit_stream_destination_created:
          ~w(destination_id destination_name include_personal_data kind organization_id start_from url_host user_id),
        audit_stream_destination_updated:
          ~w(changed destination_id destination_name kind organization_id url_host user_id),
        audit_stream_destination_paused:
          ~w(destination_id destination_name kind organization_id user_id),
        audit_stream_destination_resumed:
          ~w(destination_id destination_name kind organization_id user_id),
        audit_stream_destination_deleted:
          ~w(destination_id destination_name kind organization_id user_id),
        audit_stream_signing_secret_rotated: ~w(destination_id organization_id user_id)
      }

      for {action, keys} <- expected do
        [event | _rest] = events(ctx.organization.id, action)
        assert {action, event.metadata |> Map.keys() |> Enum.sort()} == {action, keys}
        assert event.metadata["user_id"] == ctx.admin.id
        assert event.metadata["destination_id"] == https.id

        encoded = Jason.encode!(event.metadata)
        for secret <- secrets, do: refute(encoded =~ secret)
      end

      [created_https, created_splunk] =
        events(ctx.organization.id, :audit_stream_destination_created)

      assert created_https.metadata["url_host"] == "siem.example.org"
      assert created_https.metadata["start_from"] == "now"
      assert created_splunk.metadata["url_host"] == "collector.example.com"

      [updated] = events(ctx.organization.id, :audit_stream_destination_updated)
      assert updated.metadata["changed"] == ["url"]
    end
  end
end

defmodule Kanban.AuditStreamLimitRaceTest do
  @moduledoc """
  Shows, using a second, real Postgres session, that
  `Kanban.AuditStream.create_destination/3` counts an Organization's
  destinations under a row lock that a concurrent create really contends
  with, and that every write checks its caller's rights again under that
  lock, so a revocation committed while the write waits refuses it.

  The sandbox never commits, so this module checks out unsandboxed
  connections and commits its fixtures for real, which is why it is not
  async. The fixtures are inserted straight through `Repo`, so they write no
  audit row, and `on_exit` deletes them. The create under test runs in a
  transaction the test rolls back, so it commits nothing either: not even the
  undeletable audit row a regression that let it through would write.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Destination
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @hold_ms 300

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    admin =
      Repo.insert!(%User{
        email: "audit-stream-race-#{System.unique_integer([:positive])}@example.com",
        type: :user
      })

    organization = organization_fixture()
    organization_member_fixture(organization, admin, :org_admin)

    on_exit(fn -> delete_committed(organization.id, admin.id) end)

    for _n <- 1..(Destination.max_destinations() - 1)//1,
        do: destination_fixture(organization, :datadog)

    %{organization: organization, admin: admin, scope: Scope.for_user(admin)}
  end

  test "two concurrent creates at limit minus one leave exactly the limit", ctx do
    competitor = hold_competing_create(ctx.organization)

    {elapsed_ms, result} =
      timed(fn ->
        Repo.transaction(fn ->
          Repo.rollback(AuditStream.create_destination(ctx.scope, destination_attrs(:datadog)))
        end)
      end)

    assert {:ok, :committed} = Task.await(competitor)

    # Without the Organization lock the count would miss the competitor's
    # uncommitted destination and the create would pass the limit.
    assert result == {:error, {:error, :limit_reached}}
    assert elapsed_ms >= @hold_ms - 50

    count =
      from(d in Destination, where: d.organization_id == ^ctx.organization.id)
      |> Repo.aggregate(:count)

    assert count == Destination.max_destinations()
  end

  # Each write passes authorize/1, then waits on the Organization lock held by
  # a revocation that commits while it waits. Checked again under that lock,
  # the write is refused and changes nothing.
  for {verb, revocation} <- [
        update: :demoted,
        update: :disabled,
        update: :removed,
        pause: :disabled,
        resume: :removed,
        delete: :removed,
        rotate: :disabled,
        rotate: :demoted,
        create: :demoted
      ] do
    test "#{verb} by an org-admin #{revocation} while it waits on the lock is refused", ctx do
      destination = destination_fixture(ctx.organization, :https)
      competitor = hold_revocation(ctx.organization, ctx.admin, unquote(revocation))

      {elapsed_ms, result} =
        timed(fn ->
          Repo.transaction(fn ->
            Repo.rollback(write(unquote(verb), ctx.scope, destination))
          end)
        end)

      assert {:ok, :committed} = Task.await(competitor)
      assert result == {:error, {:error, :unauthorized}}
      # It waited on the lock, so it had already passed authorize/1.
      assert elapsed_ms >= @hold_ms - 50

      assert %Destination{lock_version: lock_version, enabled: true, name: name} =
               Repo.get(Destination, destination.id)

      assert {lock_version, name} == {destination.lock_version, destination.name}

      assert from(d in Destination, where: d.organization_id == ^ctx.organization.id)
             |> Repo.aggregate(:count) == Destination.max_destinations()
    end
  end

  # The same, with the revocation holding the destination's row instead of
  # the Organization's: the rights are read again after that lock too.
  for {verb, revocation} <- [rotate: :disabled, update: :demoted, delete: :removed] do
    test "#{verb} by an org-admin #{revocation} while it waits on the destination row is refused",
         ctx do
      destination = destination_fixture(ctx.organization, :https)

      competitor =
        hold_lock(from(d in Destination, where: d.id == ^destination.id, select: d.id), fn ->
          revoke(unquote(revocation), ctx.organization, ctx.admin)
        end)

      {elapsed_ms, result} =
        timed(fn ->
          Repo.transaction(fn ->
            Repo.rollback(write(unquote(verb), ctx.scope, destination))
          end)
        end)

      assert {:ok, :committed} = Task.await(competitor)
      assert result == {:error, {:error, :unauthorized}}
      assert elapsed_ms >= @hold_ms - 50

      assert %Destination{lock_version: lock_version, name: name} =
               Repo.get(Destination, destination.id)

      assert {lock_version, name} == {destination.lock_version, destination.name}
    end
  end

  defp write(:update, scope, destination),
    do: AuditStream.update_destination(scope, destination, %{name: "Revoked rename"})

  defp write(:pause, scope, destination), do: AuditStream.pause_destination(scope, destination)
  defp write(:resume, scope, destination), do: AuditStream.resume_destination(scope, destination)
  defp write(:delete, scope, destination), do: AuditStream.delete_destination(scope, destination)

  defp write(:rotate, scope, destination),
    do: AuditStream.rotate_signing_secret(scope, destination)

  # The fixture destination fills the last slot, so this one is removed
  # first; with the limit unreached, only the revocation can refuse it.
  defp write(:create, scope, destination) do
    Repo.delete!(destination)
    AuditStream.create_destination(scope, destination_attrs(:datadog))
  end

  # A revocation in its own session: locks the Organization row as every
  # membership write does, demotes, disables or removes `admin`, and holds
  # the transaction open for @hold_ms before committing.
  defp hold_revocation(organization, admin, revocation) do
    hold_organization_lock(organization, fn -> revoke(revocation, organization, admin) end)
  end

  defp revoke(:demoted, organization, admin) do
    from(m in OrganizationMember,
      where: m.organization_id == ^organization.id and m.user_id == ^admin.id
    )
    |> Repo.update_all(set: [role: :member])
  end

  defp revoke(:disabled, _organization, admin) do
    from(u in User, where: u.id == ^admin.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])
  end

  defp revoke(:removed, organization, admin) do
    from(m in OrganizationMember,
      where: m.organization_id == ^organization.id and m.user_id == ^admin.id
    )
    |> Repo.delete_all()
  end

  # A competing create in its own session: locks the Organization row as
  # create_destination/3 does, inserts the destination that reaches the limit
  # and holds the transaction open for @hold_ms before committing.
  defp hold_competing_create(organization) do
    hold_organization_lock(organization, fn -> destination_fixture(organization, :datadog) end)
  end

  defp hold_organization_lock(organization, fun) do
    from(o in Organization, where: o.id == ^organization.id, select: o.id)
    |> hold_lock(fun)
  end

  # Locks the row `query` selects in its own session, runs `fun` and holds
  # the transaction open for @hold_ms before committing.
  defp hold_lock(query, fun) do
    test_pid = self()

    competitor =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        {:ok, result} =
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL lock_timeout = '5s'")

            query |> lock("FOR UPDATE") |> Repo.one!()
            fun.()
            send(test_pid, :competitor_holding)
            Process.sleep(@hold_ms)
            :committed
          end)

        {:ok, result}
      end)

    assert_receive :competitor_holding, 5_000
    competitor
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # on_exit runs in its own process, which needs its own connection.
  defp delete_committed(organization_id, user_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(d in Destination, where: d.organization_id == ^organization_id) |> Repo.delete_all()

    from(m in OrganizationMember, where: m.organization_id == ^organization_id)
    |> Repo.delete_all()

    from(o in Organization, where: o.id == ^organization_id) |> Repo.delete_all()
    from(u in User, where: u.id == ^user_id) |> Repo.delete_all()
  end
end
