defmodule Kanban.Devices.NoncesTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.Nonce
  alias Kanban.Devices.Nonces
  alias Kanban.Devices.NonceSweepWorker
  alias Kanban.Tasks.Task

  @now ~U[2026-11-19 12:00:00Z]
  @key "0b6f3c1e-8d5a-4f1b-9a2e-7c4d6e8f0a1b"

  setup do
    scope = Scope.for_user(user_fixture())
    phone = device_fixture(scope, %{device_class: :phone})

    tablet =
      device_fixture(scope, %{
        platform: :android,
        client_id: "stride-android",
        device_class: :tablet
      })

    %{phone: phone, tablet: tablet}
  end

  defp render(%Task{} = task),
    do: %{data: %{task_id: task.id, review_status: "approved", reviewed_at: task.reviewed_at}}

  defp key(device, action \\ :approve, task_id \\ 42, key \\ @key),
    do: Nonces.idempotency_key(device, action, task_id, key, &render/1)

  defp decided, do: %Task{id: 42, reviewed_at: ~U[2026-11-19 11:59:30Z]}

  # What a decision does: claim, decide, record, in one transaction.
  defp store!(key, now \\ @now) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        :ok = Nonces.claim(key, now)
        Nonces.record(key, decided())
      end)

    :ok
  end

  defp insert_row!(device, key_hash, kind, expires_at) do
    Repo.insert!(%Nonce{
      device_id: device.id,
      kind: kind,
      key_hash: key_hash,
      response_status: 200,
      response_body: %{},
      expires_at: expires_at
    })
  end

  defp nonce_ids, do: Nonce |> order_by(:id) |> select([n], n.id) |> Repo.all()

  describe "claim/2, record/2 and find_replay/2" do
    test "stores the first result and replays it for the same key", ctx do
      key = key(ctx.phone)
      assert Nonces.find_replay(key, @now) == :none

      assert store!(key) == :ok

      expected = %{
        "data" => %{
          "task_id" => 42,
          "review_status" => "approved",
          "reviewed_at" => "2026-11-19T11:59:30Z"
        }
      }

      assert {:ok, %Nonce{response_status: 200, response_body: ^expected} = stored} =
               Nonces.find_replay(key, @now)

      assert stored.kind == :idempotency
      assert stored.expires_at == DateTime.add(@now, Nonces.ttl_seconds(), :second)

      # A second claim of the same key is told to replay the first result.
      assert {:error, {:replay, %Nonce{response_status: 200, response_body: ^expected}}} =
               Nonces.claim(key, DateTime.add(@now, 60, :second))

      assert length(nonce_ids()) == 1
    end

    test "the same key from another device is a different row", ctx do
      phone_key = key(ctx.phone)
      tablet_key = key(ctx.tablet)

      assert store!(phone_key) == :ok
      assert Nonces.find_replay(tablet_key, @now) == :none
      assert store!(tablet_key) == :ok

      assert Nonce |> select([n], n.device_id) |> Repo.all() |> Enum.sort() ==
               Enum.sort([ctx.phone.id, ctx.tablet.id])
    end

    test "a key reused for another task or the other action is a different row", ctx do
      assert store!(key(ctx.phone)) == :ok

      other_task = key(ctx.phone, :approve, 43)
      other_action = key(ctx.phone, :request_changes, 42)

      assert Nonces.find_replay(other_task, @now) == :none
      assert Nonces.find_replay(other_action, @now) == :none
      assert Nonces.claim(other_task, @now) == :ok
      assert Nonces.claim(other_action, @now) == :ok
    end

    test "only a hash of the key is stored, and inspect shows no hash", ctx do
      key = key(ctx.phone)
      assert store!(key) == :ok

      assert [%Nonce{key_hash: hash}] = Repo.all(Nonce)
      refute hash =~ @key
      request_hash = DeviceToken.hash_token("")
      assert hash == DeviceToken.hash_token("idempotency:v1:approve:42:#{request_hash}:#{@key}")
      refute inspect(key) =~ hash
      refute inspect(key) =~ @key
    end

    test "the same key sent with another request is a different row", ctx do
      bound = fn request ->
        Nonces.idempotency_key(ctx.phone, :request_changes, 42, @key, &render/1, request)
      end

      first = bound.(~s(["2026-11-18T09:30:00Z","Fix the table"]))
      same = bound.(~s(["2026-11-18T09:30:00Z","Fix the table"]))
      other_notes = bound.(~s(["2026-11-18T09:30:00Z","Other notes"]))
      other_stamp = bound.(~s(["2026-11-18T10:00:00Z","Fix the table"]))

      assert store!(first) == :ok
      assert {:ok, _stored} = Nonces.find_replay(same, @now)
      assert Nonces.find_replay(other_notes, @now) == :none
      assert Nonces.find_replay(other_stamp, @now) == :none
    end

    test "a result stored at a fraction of a second is replayed for at least 24 hours", ctx do
      key = key(ctx.phone)
      first = DateTime.add(@now, 600_000, :microsecond)
      assert store!(key, first) == :ok

      assert [%Nonce{expires_at: expires_at}] = Repo.all(Nonce)
      assert expires_at == DateTime.add(@now, Nonces.ttl_seconds() + 1, :second)

      just_inside = DateTime.add(first, Nonces.ttl_seconds() * 1_000_000 - 1, :microsecond)
      assert {:ok, _stored} = Nonces.find_replay(key, just_inside)

      assert {:ok, {:error, {:replay, _stored}}} =
               Repo.transaction(fn -> Nonces.claim(key, just_inside) end)
    end

    test "after 24 hours the same key is taken over and acts anew", ctx do
      key = key(ctx.phone)
      assert store!(key) == :ok

      later = DateTime.add(@now, Nonces.ttl_seconds(), :second)
      assert Nonces.find_replay(key, later) == :none

      {:ok, :ok} = Repo.transaction(fn -> Nonces.claim(key, later) end)

      assert [%Nonce{response_status: nil, response_body: nil, expires_at: expires_at}] =
               Repo.all(Nonce)

      assert expires_at == DateTime.add(later, Nonces.ttl_seconds(), :second)
    end

    test "no key sent: claim and record are no-ops and nothing replays" do
      assert Nonces.claim(nil, @now) == :ok
      assert Nonces.record(nil, decided()) == :ok
      assert Nonces.find_replay(nil) == :none
      assert nonce_ids() == []
    end
  end

  describe "valid_key?/1" do
    test "accepts 1 to 255 visible ASCII characters only" do
      assert Nonces.valid_key?(@key)
      assert Nonces.valid_key?("a")
      longest = String.duplicate("k", 255)
      assert Nonces.valid_key?(longest)

      refute Nonces.valid_key?("")
      refute Nonces.valid_key?(longest <> "k")
      refute Nonces.valid_key?("has space")
      refute Nonces.valid_key?("ключ")
      refute Nonces.valid_key?("line\nbreak")
      refute Nonces.valid_key?(nil)
    end
  end

  describe "sweep_expired/2 and NonceSweepWorker" do
    test "the sweep deletes expired rows only", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      key = key(ctx.phone)

      # A key used two days ago, now expired.
      assert store!(key, DateTime.add(now, -2 * Nonces.ttl_seconds(), :second)) == :ok
      at_now = insert_row!(ctx.phone, "b", :socket_token, now)
      live = insert_row!(ctx.phone, "c", :idempotency, DateTime.add(now, 3600, :second))
      live_socket = insert_row!(ctx.tablet, "d", :socket_token, DateTime.add(now, 60, :second))

      assert Nonces.sweep_expired(now, 1) == 2
      assert nonce_ids() == Enum.sort([live.id, live_socket.id])
      refute Repo.get(Nonce, at_now.id)

      # The swept key acts anew: nothing replays and it can be claimed again.
      assert Nonces.find_replay(key, now) == :none
      assert store!(key, now) == :ok

      # The worker sweeps the same way and leaves live rows alone.
      assert :ok = perform_job(NonceSweepWorker, %{})
      assert length(nonce_ids()) == 3
      assert NonceSweepWorker.__opts__()[:queue] == :maintenance
    end

    test "is scheduled hourly in the Oban crontab" do
      crontab =
        Application.fetch_env!(:kanban, Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
          _plugin -> nil
        end)

      assert {"37 * * * *", NonceSweepWorker} in crontab
    end
  end
end
