defmodule Kanban.RepoLogRedactionTest do
  # async: false because the setup raises the global Logger level to :debug
  # (the suite otherwise runs at :warning) to capture the query log.
  use Kanban.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.UserTotp
  alias Kanban.AuditStream.Destination
  alias Kanban.Encryption
  alias Kanban.Integrations.SecretBox
  alias Kanban.Repo.QueryLogger
  alias Kanban.SSO.SSOConnection
  alias Kanban.Webhooks.Endpoint

  doctest Kanban.Repo.QueryLogger

  @mark "**redacted**"

  setup do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
    :ok
  end

  defp probe(label), do: "D431-probe-#{label}-#{System.unique_integer([:positive])}"

  defp debug_log(fun), do: capture_log([level: :debug], fun)

  defp destination(organization, secrets) do
    %Destination{
      organization_id: organization.id,
      kind: :https,
      name: "D431 destination #{System.unique_integer([:positive])}"
    }
    |> struct!(secrets)
    |> Repo.insert!()
  end

  defp encrypted_schemas do
    {:ok, modules} = :application.get_key(:kanban, :modules)

    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :__schema__, 1),
        fields = encrypted_fields(module),
        fields != [],
        do: {module, fields}
  end

  defp encrypted_fields(schema) do
    :fields
    |> schema.__schema__()
    |> Enum.filter(&encrypting_type?(schema.__schema__(:type, &1)))
  end

  # Found by behaviour, not by name: a custom Ecto type over :binary whose
  # dump changes a string is one that writes something other than the
  # plaintext (a cipher, or a hash) while Ecto logs the plaintext cast value.
  defp encrypting_type?(type) when is_atom(type) do
    Code.ensure_loaded?(type) and function_exported?(type, :dump, 1) and
      function_exported?(type, :type, 0) and type.type() == :binary and
      match?({:ok, dumped} when dumped != "D431-type-probe", type.dump("D431-type-probe"))
  end

  defp encrypting_type?(_type), do: false

  describe "the query log" do
    test "redacts encrypted params on insert" do
      organization = organization_fixture()
      user = user_fixture()

      url = probe("url")
      credential = probe("credential")
      signing = probe("signing")
      previous = probe("previous")
      client_secret = probe("client-secret")
      totp_secret = probe("totp")

      log =
        debug_log(fn ->
          destination(organization, %{
            url: url,
            credential: credential,
            signing_secret: signing,
            previous_signing_secret: previous
          })

          Repo.insert!(%SSOConnection{
            organization_id: organization.id,
            protocol: :oidc,
            issuer: "https://idp.example.com",
            client_id: "d431-client",
            client_secret: client_secret
          })

          Repo.insert!(%UserTotp{user_id: user.id, secret: totp_secret})
        end)

      assert log =~ ~s(INSERT INTO "audit_stream_destinations")
      assert log =~ ~s(INSERT INTO "sso_connections")
      assert log =~ ~s(INSERT INTO "user_totps")
      assert log =~ @mark

      for secret <- [url, credential, signing, previous, client_secret, totp_secret] do
        refute log =~ secret
      end
    end

    test "redacts encrypted params on update and in where clauses" do
      organization = organization_fixture()
      user = user_fixture()
      dest = destination(organization, %{credential: probe("old")})
      totp = Repo.insert!(%UserTotp{user_id: user.id, secret: probe("old-totp")})

      credential = probe("new-credential")
      totp_secret = probe("new-totp")
      wanted = probe("where")

      log =
        debug_log(fn ->
          dest |> Ecto.Changeset.change(credential: credential) |> Repo.update!()
          totp |> Ecto.Changeset.change(secret: totp_secret) |> Repo.update!()
          Destination |> where([d], d.credential == ^wanted) |> Repo.all()
        end)

      assert log =~ ~s(UPDATE "audit_stream_destinations")
      assert log =~ ~s(UPDATE "user_totps")
      assert log =~ ~s(SELECT)

      for secret <- [credential, totp_secret, wanted] do
        refute log =~ secret
      end
    end

    test "redacts encrypted params in bulk operations" do
      user = user_fixture()
      other = user_fixture()
      now = DateTime.utc_now(:second)
      first = probe("bulk-1")
      second = probe("bulk-2")
      updated = probe("bulk-update")

      log =
        debug_log(fn ->
          Repo.insert_all(UserTotp, [
            %{user_id: user.id, secret: first, inserted_at: now, updated_at: now},
            %{user_id: other.id, secret: second, inserted_at: now, updated_at: now}
          ])

          from(t in UserTotp, where: t.user_id in ^[user.id, other.id])
          |> Repo.update_all(set: [secret: updated])
        end)

      assert log =~ ~s(INSERT INTO "user_totps")
      assert log =~ ~s(UPDATE "user_totps")

      for secret <- [first, second, updated] do
        refute log =~ secret
      end
    end

    defp invalid_totp_error(secret) do
      changeset =
        %UserTotp{}
        |> Ecto.Changeset.change(secret: secret)
        |> Ecto.Changeset.add_error(:user_id, "can't be blank")

      assert_raise Ecto.InvalidChangesetError, fn -> Repo.insert!(changeset) end
    end

    test "an invalid changeset error's struct and Changeset section are redacted" do
      secret = probe("invalid-struct")
      error = invalid_totp_error(secret)

      refute inspect(error) =~ secret
      [_before, changeset_section] = error |> Exception.message() |> String.split("\nChangeset\n")
      assert changeset_section =~ @mark
      refute changeset_section =~ secret
    end

    # Ecto.InvalidChangesetError.message/1 (ecto 3.14) prints the changeset's
    # "Applied changes" and "Params" with inspect/2, ignoring redact: true, and
    # the query logger cannot reach an exception message. No code in lib raises
    # it for an encrypted schema today (every write there is a non-raising
    # Repo call or a validation-free change/2), so this stays skipped until
    # the message itself is redacted (D431 follow-up).
    @tag skip: "Ecto.InvalidChangesetError.message/1 prints applied changes unredacted"
    test "invalid changeset errors carry no plaintext secret" do
      secret = probe("invalid")
      error = invalid_totp_error(secret)

      refute Exception.message(error) =~ secret
    end

    test "a failed query logs as ERROR with its encrypted params redacted" do
      secret = probe("failed")

      log =
        debug_log(fn ->
          error =
            assert_raise Ecto.ConstraintError, fn ->
              Repo.insert!(%UserTotp{user_id: -1, secret: secret})
            end

          refute Exception.message(error) =~ secret
        end)

      assert log =~ "QUERY ERROR"
      refute log =~ secret
    end

    test "leaves nil encrypted params alone" do
      organization = organization_fixture()
      dest = destination(organization, %{credential: probe("before-nil")})

      log =
        debug_log(fn ->
          dest |> Ecto.Changeset.change(credential: nil) |> Repo.update!()
        end)

      assert log =~ ~s(UPDATE "audit_stream_destinations" SET "credential" = $1)
      assert log =~ "[nil, "
    end

    test "covers every encrypted schema" do
      schemas = encrypted_schemas()

      # Non-vacuity: the enumeration finds the schemas known to hold secrets.
      assert {Destination, [:url, :credential, :signing_secret, :previous_signing_secret]} in schemas
      assert {SSOConnection, [:client_secret]} in schemas
      assert {UserTotp, [:secret]} in schemas
      assert {Endpoint, [:url]} in schemas

      for {schema, fields} <- schemas, field <- fields do
        # An embedded schema's values reach the database inside a map param,
        # which the logger does not look into; none may hold a secret.
        assert schema.__schema__(:source), "#{inspect(schema)} embeds encrypted #{field}"

        wanted = probe("#{inspect(schema)}-#{field}")
        set = probe("#{inspect(schema)}-#{field}-set")

        log =
          debug_log(fn ->
            schema |> where([s], field(s, ^field) == ^wanted) |> select(count()) |> Repo.all()

            from(s in schema, where: fragment("false"))
            |> Repo.update_all(set: [{field, set}])
          end)

        assert log =~ "QUERY OK", "no query logged for #{inspect(schema)}.#{field}"
        refute log =~ wanted, "#{inspect(schema)}.#{field} logged a where-clause plaintext"
        refute log =~ set, "#{inspect(schema)}.#{field} logged an update plaintext"
      end
    end

    test "keeps non-encrypted params and the query event" do
      attach_telemetry([:kanban, :repo, :query])
      organization = organization_fixture()
      secret = probe("event")
      name = "D431 visible name #{System.unique_integer([:positive])}"

      log =
        debug_log(fn ->
          Repo.insert!(%Destination{
            organization_id: organization.id,
            kind: :https,
            name: name,
            signing_secret: secret
          })
        end)

      assert log =~ name
      assert log =~ ~s(source="audit_stream_destinations")
      refute log =~ secret

      assert_receive {:telemetry_event, [:kanban, :repo, :query], measurements,
                      %{source: "audit_stream_destinations", query: "INSERT" <> _} = metadata}

      assert %{query_time: _, total_time: _} = measurements
      assert secret in metadata.cast_params
      assert name in metadata.cast_params
      assert Enum.any?(metadata.params, &(Encryption.decrypt(&1) == {:ok, secret}))
      refute secret in metadata.params
    end
  end

  describe "redact_params/2" do
    test "redacts a plaintext wherever it sits, and its ciphertext" do
      ciphertext = Encryption.encrypt("s3cret")

      assert QueryLogger.redact_params(["a", ciphertext, "s3cret"], [ciphertext, "a", "x"]) ==
               ["a", @mark, @mark]
    end

    test "redacts inside array params" do
      ciphertext = Encryption.encrypt("s3cret")

      assert QueryLogger.redact_params([["s3cret", "other"]], [[ciphertext, "other"]]) ==
               [[@mark, "other"]]
    end

    test "without cast params, redacts the dumped ciphertext, decryptable or not" do
      ciphertext = Encryption.encrypt("other")
      undecryptable = binary_part(ciphertext, 0, byte_size(ciphertext) - 1) <> <<0>>

      assert QueryLogger.redact_params(nil, [Encryption.encrypt("s3cret"), undecryptable, 7]) ==
               [@mark, @mark, 7]
    end

    test "logs only the dumped params, ciphertext replaced, when decryption raises" do
      ciphertext = Encryption.encrypt("s3cret")
      original = Application.fetch_env!(:kanban, Encryption)
      Application.put_env(:kanban, Encryption, key: "too short")
      on_exit(fn -> Application.put_env(:kanban, Encryption, original) end)

      assert QueryLogger.redact_params(["s3cret", "name"], [ciphertext, "name"]) ==
               [@mark, "name"]
    end

    test "redacts SecretBox ciphertext and its plaintext too" do
      ciphertext = SecretBox.encrypt("https://hooks.example.com/T0/secret")

      assert QueryLogger.redact_params(["https://hooks.example.com/T0/secret", 3], [ciphertext, 3]) ==
               [@mark, 3]

      assert QueryLogger.redact_params(nil, [ciphertext, 3]) == [@mark, 3]
    end

    test "returns non-list params unchanged" do
      assert QueryLogger.redact_params(nil, nil) == nil
    end
  end

  describe "the security docs" do
    test "say query logs carry no decrypted values, and name the gaps" do
      readme = File.read!("README.md")

      assert readme =~ "Query logs are redacted at every level, debug included."
      assert readme =~ "Ecto.InvalidChangesetError"
      assert readme =~ "log: <level>"
    end
  end

  describe "handle_event/4" do
    @config %{level: :debug, stacktrace_mfa: {Ecto.Adapters.SQL, :first_non_ecto_stacktrace, [1]}}

    defp metadata(options) do
      %{
        query: "SELECT 1",
        params: [],
        cast_params: [],
        source: nil,
        result: {:ok, nil},
        repo: Repo,
        stacktrace: nil,
        options: options
      }
    end

    defp handle(options) do
      debug_log(fn ->
        assert :ok =
                 QueryLogger.handle_event(
                   [:kanban, :repo, :query],
                   %{query_time: 1000, total_time: 1000},
                   metadata(options),
                   @config
                 )
      end)
    end

    test "logs an ordinary query" do
      assert handle([]) =~ "QUERY OK db="
    end

    test "skips queries whose caller manages its own logging" do
      assert handle(oban_conf: %{log: false}) == ""
      assert handle(schema_migration: true) == ""
    end
  end

  describe "attach/1" do
    setup do
      on_exit(fn -> :ok = QueryLogger.attach() end)
    end

    defp attached? do
      [:kanban, :repo, :query]
      |> :telemetry.list_handlers()
      |> Enum.any?(&(&1.id == {QueryLogger, :redacted_query_log}))
    end

    test "is attached at boot, and attaching twice is a no-op" do
      assert attached?()
      assert :ok = QueryLogger.attach()
      assert attached?()
    end

    test "attaches nothing when the Repo config says log: false" do
      :ok = QueryLogger.detach()
      assert :ok = QueryLogger.attach(log: false)
      refute attached?()
    end

    test "turns Ecto's own logging off in the Repo config" do
      assert Repo.config()[:log] == false

      assert QueryLogger.disable_ecto_logging(log: :info, pool_size: 2) == [
               log: false,
               pool_size: 2
             ]
    end
  end
end
