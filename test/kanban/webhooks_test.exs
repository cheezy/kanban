defmodule Kanban.WebhooksTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.WebhooksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Integrations.SecretBox
  alias Kanban.Repo
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.Endpoint

  @public [{93, 184, 216, 34}]
  @opts [resolver: &__MODULE__.public_resolver/1, allow_http: false]
  @valid %{"url" => "https://hooks.example.com/stride", "event_types" => ["task.created"]}

  def public_resolver(_host), do: {:ok, @public}

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    modifier = user_fixture()
    reader = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

    %{
      owner: owner,
      board: board,
      other_board: board_fixture(user_fixture()),
      owner_scope: Scope.for_user(owner),
      non_owner_scopes: [
        Scope.for_user(modifier),
        Scope.for_user(reader),
        Scope.for_user(user_fixture()),
        nil
      ]
    }
  end

  describe "create_endpoint/4" do
    test "the owner gets the plaintext secret once; it is stored only encrypted", ctx do
      assert {:ok, {endpoint, secret}} =
               Webhooks.create_endpoint(ctx.owner_scope, ctx.board, @valid, @opts)

      assert "whsec_" <> _ = secret
      assert endpoint.secret == nil
      assert endpoint.board_id == ctx.board.id
      assert endpoint.created_by_id == ctx.owner.id
      assert endpoint.kind == :generic

      stored = Repo.get!(Endpoint, endpoint.id)
      assert stored.secret == nil
      refute stored.encrypted_secret =~ secret
      assert SecretBox.decrypt(stored.encrypted_secret) == {:ok, secret}
      assert Webhooks.signing_secret(stored) == {:ok, secret}
    end

    test "the URL is stored encrypted and redacted from inspect", ctx do
      url = "https://hooks.example.com/services/T000/B000/XXXX"

      {:ok, {endpoint, _secret}} =
        Webhooks.create_endpoint(ctx.owner_scope, ctx.board, Map.put(@valid, "url", url), @opts)

      %{rows: [[stored_url]]} =
        Repo.query!("SELECT url FROM webhook_endpoints WHERE id = $1", [endpoint.id])

      refute stored_url =~ "hooks.example.com"
      assert SecretBox.decrypt(stored_url) == {:ok, url}
      assert Repo.get!(Endpoint, endpoint.id).url == url
      refute inspect(endpoint) =~ "hooks.example.com"
    end

    test "a slack endpoint can be created", ctx do
      attrs = Map.put(@valid, "kind", "slack")

      assert {:ok, {%Endpoint{kind: :slack}, _}} =
               Webhooks.create_endpoint(ctx.owner_scope, ctx.board, attrs, @opts)
    end

    test "every non-owner is :unauthorized and nothing is written", ctx do
      for scope <- ctx.non_owner_scopes do
        assert Webhooks.create_endpoint(scope, ctx.board, @valid, @opts) ==
                 {:error, :unauthorized}
      end

      assert Repo.aggregate(Endpoint, :count) == 0
    end

    test "board_id and created_by_id cannot be set from params", ctx do
      attrs = Map.merge(@valid, %{"board_id" => ctx.other_board.id, "created_by_id" => 0})

      assert {:ok, {endpoint, _}} =
               Webhooks.create_endpoint(ctx.owner_scope, ctx.board, attrs, @opts)

      assert endpoint.board_id == ctx.board.id
      assert endpoint.created_by_id == ctx.owner.id
    end

    test "a host resolving to a private address is an error on :url", ctx do
      opts = Keyword.put(@opts, :resolver, fn _ -> {:ok, [{10, 0, 0, 1}]} end)

      assert {:error, changeset} =
               Webhooks.create_endpoint(ctx.owner_scope, ctx.board, @valid, opts)

      assert {_message, [reason: :blocked_address]} = changeset.errors[:url]
      assert Repo.aggregate(Endpoint, :count) == 0
    end

    test "an invalid changeset never resolves the host", ctx do
      opts = Keyword.put(@opts, :resolver, fn _ -> flunk("must not resolve") end)
      attrs = Map.put(@valid, "event_types", [])

      assert {:error, changeset} =
               Webhooks.create_endpoint(ctx.owner_scope, ctx.board, attrs, opts)

      assert %{event_types: [_]} = errors_on(changeset)
    end
  end

  describe "list_endpoints/2 and get_endpoint/3" do
    test "the owner sees the board's endpoints, oldest first, without secrets", ctx do
      first = webhook_endpoint_fixture(ctx.board)
      second = webhook_endpoint_fixture(ctx.board)
      webhook_endpoint_fixture(ctx.other_board)

      listed = Webhooks.list_endpoints(ctx.owner_scope, ctx.board)
      assert Enum.map(listed, & &1.id) == [first.id, second.id]
      assert Enum.all?(listed, &is_nil(&1.secret))

      assert {:ok, %Endpoint{id: id, secret: nil}} =
               Webhooks.get_endpoint(ctx.owner_scope, ctx.board, to_string(first.id))

      assert id == first.id
    end

    test "non-owners get [] and :not_found", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)

      for scope <- ctx.non_owner_scopes do
        assert Webhooks.list_endpoints(scope, ctx.board) == []
        assert Webhooks.get_endpoint(scope, ctx.board, endpoint.id) == {:error, :not_found}
      end
    end

    test "another board's endpoint, a missing id and a malformed id are :not_found", ctx do
      foreign = webhook_endpoint_fixture(ctx.other_board)

      for id <- [foreign.id, -1, "abc", nil] do
        assert Webhooks.get_endpoint(ctx.owner_scope, ctx.board, id) == {:error, :not_found}
      end
    end
  end

  describe "update_endpoint/4" do
    test "the owner updates the editable fields", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      attrs = %{"enabled" => false, "event_types" => ["task.moved", "task.moved"]}

      assert {:ok, updated} = Webhooks.update_endpoint(ctx.owner_scope, endpoint, attrs, @opts)
      refute updated.enabled
      assert updated.event_types == ["task.moved"]
    end

    test "only a changed URL is resolved again", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      private = Keyword.put(@opts, :resolver, fn _ -> {:ok, [{192, 168, 1, 1}]} end)

      assert {:ok, _} =
               Webhooks.update_endpoint(ctx.owner_scope, endpoint, %{"enabled" => false}, private)

      assert {:error, changeset} =
               Webhooks.update_endpoint(
                 ctx.owner_scope,
                 endpoint,
                 %{"url" => "https://new.example.com/"},
                 private
               )

      assert {_message, [reason: :blocked_address]} = changeset.errors[:url]
    end

    test "non-owners are :unauthorized", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)

      for scope <- ctx.non_owner_scopes do
        assert Webhooks.update_endpoint(scope, endpoint, %{"enabled" => false}, @opts) ==
                 {:error, :unauthorized}
      end

      assert Repo.get!(Endpoint, endpoint.id).enabled
    end

    test "an endpoint deleted since it was loaded is an error on :id", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      Repo.delete!(endpoint)

      assert {:error, changeset} =
               Webhooks.update_endpoint(ctx.owner_scope, endpoint, %{"enabled" => false}, @opts)

      assert changeset.errors[:id]
    end
  end

  describe "rotate_secret/2" do
    test "returns a new secret and the old one can no longer be recovered", ctx do
      {:ok, {endpoint, old_secret}} =
        Webhooks.create_endpoint(ctx.owner_scope, ctx.board, @valid, @opts)

      old_ciphertext = Repo.get!(Endpoint, endpoint.id).encrypted_secret

      assert {:ok, {rotated, new_secret}} = Webhooks.rotate_secret(ctx.owner_scope, endpoint)
      assert rotated.secret == nil
      refute new_secret == old_secret

      stored = Repo.get!(Endpoint, endpoint.id)
      refute stored.encrypted_secret == old_ciphertext
      assert Webhooks.signing_secret(stored) == {:ok, new_secret}
    end

    test "rotating an endpoint loaded before another rotation is an error on :id", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)

      assert {:ok, {_rotated, kept}} = Webhooks.rotate_secret(ctx.owner_scope, endpoint)
      assert {:error, changeset} = Webhooks.rotate_secret(ctx.owner_scope, endpoint)
      assert changeset.errors[:id]

      stored = Repo.get!(Endpoint, endpoint.id)
      assert Webhooks.signing_secret(stored) == {:ok, kept}
    end

    test "non-owners are :unauthorized and the secret is unchanged", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)

      for scope <- ctx.non_owner_scopes do
        assert Webhooks.rotate_secret(scope, endpoint) == {:error, :unauthorized}
      end

      assert Repo.get!(Endpoint, endpoint.id).encrypted_secret == endpoint.encrypted_secret
    end
  end

  describe "delete_endpoint/2" do
    test "the owner deletes an endpoint and its deliveries go with it", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      delivery = delivery_fixture(endpoint)

      assert {:ok, _} = Webhooks.delete_endpoint(ctx.owner_scope, endpoint)
      refute Repo.get(Endpoint, endpoint.id)
      refute Repo.get(Delivery, delivery.id)
    end

    test "non-owners are :unauthorized", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)

      for scope <- ctx.non_owner_scopes do
        assert Webhooks.delete_endpoint(scope, endpoint) == {:error, :unauthorized}
      end

      assert Repo.get(Endpoint, endpoint.id)
    end

    test "an endpoint already deleted is an error on :id", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      Repo.delete!(endpoint)

      assert {:error, changeset} = Webhooks.delete_endpoint(ctx.owner_scope, endpoint)
      assert changeset.errors[:id]
    end
  end

  test "deleting the board removes its endpoints and their deliveries", ctx do
    endpoint = webhook_endpoint_fixture(ctx.board)
    delivery = delivery_fixture(endpoint)

    {:ok, _} = Boards.delete_board(ctx.board, ctx.owner)

    refute Repo.get(Endpoint, endpoint.id)
    refute Repo.get(Delivery, delivery.id)
  end

  test "deleting the creator keeps the endpoint and clears created_by_id", ctx do
    creator = user_fixture()
    endpoint = webhook_endpoint_fixture(ctx.board, created_by_id: creator.id)

    Repo.delete!(creator)

    assert Repo.get!(Endpoint, endpoint.id).created_by_id == nil
  end

  test "change_endpoint/2 returns a changeset" do
    assert %Ecto.Changeset{} = Webhooks.change_endpoint()
    assert %Ecto.Changeset{valid?: false} = Webhooks.change_endpoint(%Endpoint{}, %{"url" => ""})
  end

  describe "Endpoint.changeset/3" do
    defp endpoint_errors(attrs) do
      %Endpoint{} |> Endpoint.changeset(attrs, allow_http: false) |> errors_on()
    end

    test "requires a URL and at least one known event type" do
      assert %{url: ["can't be blank"], event_types: [_]} =
               endpoint_errors(%{"event_types" => []})

      assert %{event_types: ["has an invalid entry"]} =
               endpoint_errors(Map.put(@valid, "event_types", ["task.exploded"]))
    end

    test "rejects an unknown kind" do
      assert %{kind: ["is invalid"]} = endpoint_errors(Map.put(@valid, "kind", "teams"))
    end

    test "refuses a URL the guard refuses, with the guard's reason" do
      assert %{url: ["must not contain a username or password"]} =
               endpoint_errors(Map.put(@valid, "url", "https://u:p@hooks.example.com/"))

      assert %{url: ["points to a private or reserved network address"]} =
               endpoint_errors(Map.put(@valid, "url", "https://10.0.0.1/"))
    end

    test "a URL over 2048 characters gets only the length error" do
      url = "https://hooks.example.com/" <> String.duplicate("a", 2048)

      assert %{url: ["should be at most 2048 character(s)"]} =
               endpoint_errors(Map.put(@valid, "url", url))
    end

    test "event_types are de-duplicated" do
      changeset =
        Endpoint.changeset(
          %Endpoint{},
          Map.put(@valid, "event_types", ["task.moved", "task.moved"])
        )

      assert Ecto.Changeset.get_change(changeset, :event_types) == ["task.moved"]
    end

    test "event_types/0 and kinds/0 list the public values" do
      assert "task.created" in Endpoint.event_types()
      assert Endpoint.kinds() == [:generic, :slack]
    end
  end

  describe "Delivery.changeset/2" do
    test "accepts a ping or a known event and checks attempt and response_status" do
      assert %{valid?: true} =
               Delivery.changeset(%Delivery{}, %{event: "ping", payload: %{}, attempt: 1})

      errors =
        %Delivery{}
        |> Delivery.changeset(%{event: "nope", payload: %{}, attempt: -1, response_status: 42})
        |> errors_on()

      assert %{event: [_], attempt: [_], response_status: [_]} = errors
    end
  end
end
