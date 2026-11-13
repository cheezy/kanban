defmodule Kanban.AuditStream.SchemasTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Gap
  alias Kanban.Encryption

  @splunk_url "https://collector.example.com:8088/services/collector"
  @splunk_token "splunk-hec-token-wxyz"
  @datadog_key "datadog-api-key-9876"
  @https_url "https://siem.example.org/ingest?token=secret-path-token-5555"

  setup do
    organization = organization_fixture()
    user = user_fixture()
    %{organization: organization, user: user}
  end

  defp new_destination(%{organization: organization, user: user}) do
    %Destination{organization_id: organization.id, created_by_id: user.id}
  end

  defp attrs(:splunk_hec) do
    %{
      kind: :splunk_hec,
      name: "Splunk",
      url: @splunk_url,
      credential: @splunk_token,
      settings: %{"index" => "main", "source_type" => "stride:audit"}
    }
  end

  defp attrs(:datadog) do
    %{
      kind: :datadog,
      name: "Datadog",
      credential: @datadog_key,
      settings: %{"site" => "datadoghq.eu", "service" => "stride", "tags" => ["env:prod"]}
    }
  end

  defp attrs(:https) do
    %{
      kind: "https",
      name: "Generic",
      url: @https_url,
      credential: "https-header-value-0123456789",
      settings: %{"format" => "ndjson", "header_name" => "X-Api-Key"}
    }
  end

  defp changeset(ctx, attrs), do: ctx |> new_destination() |> Destination.changeset(attrs)

  # A changeset of `kind`'s valid attributes merged with `extra`.
  defp changeset(ctx, kind, extra), do: changeset(ctx, kind |> attrs() |> Map.merge(extra))

  # A changeset of `kind`'s valid attributes without `field`.
  defp changeset_without(ctx, kind, field),
    do: changeset(ctx, kind |> attrs() |> Map.delete(field))

  defp insert!(ctx, kind, extra \\ %{}) do
    ctx |> changeset(kind, extra) |> Repo.insert!()
  end

  defp errors_on_field(changeset, field), do: changeset |> errors_on() |> Map.get(field, [])

  defp validations(changeset, field) do
    for {^field, {_message, opts}} <- changeset.errors, do: opts[:validation]
  end

  defp raw_columns(id, columns) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT #{Enum.join(columns, ", ")} FROM audit_stream_destinations WHERE id = $1",
        [id]
      )

    row
  end

  defp tamper!(id, column) do
    [ciphertext] = raw_columns(id, [column])
    last = :binary.last(ciphertext)
    tampered = binary_part(ciphertext, 0, byte_size(ciphertext) - 1) <> <<Bitwise.bxor(last, 1)>>

    Repo.query!("UPDATE audit_stream_destinations SET #{column} = $1 WHERE id = $2", [
      tampered,
      id
    ])
  end

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type, is_nullable, column_default
        FROM information_schema.columns WHERE table_name = $1
        """,
        [table]
      )

    Map.new(rows, fn [name, type, nullable, default] -> {name, {type, nullable, default}} end)
  end

  describe "the migration" do
    test "creates every column of the four tables" do
      assert columns("audit_stream_destinations") |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(
                 id organization_id kind name enabled url url_host url_hint settings
                 credential credential_hint signing_secret previous_signing_secret
                 previous_secret_expires_at include_personal_data excluded_actions
                 filter_version schema_version state state_reason halted_reason
                 failing_since consecutive_failures last_success_at failing_emailed_at
                 recovered_emailed_at created_by_id lock_version inserted_at updated_at
               ))

      assert columns("audit_stream_cursors") |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(
                 destination_id last_txid last_event_id last_inserted_at not_before
                 pending_batch_id pending_first_txid pending_first_id pending_last_txid
                 pending_last_id pending_attempts pending_filter_version next_attempt_at
                 leased_until lease_token restored_max_event_id restored_min_txid updated_at
               ))

      assert columns("audit_stream_attempts") |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(
                 id destination_id batch_id started_at duration_ms event_count bytes
                 first_event_id last_event_id http_status outcome error
               ))

      assert columns("audit_stream_gaps") |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(
                 id destination_id reason events first_occurred_at last_occurred_at
                 opened_at last_extended_at emailed_at audited_at dismissed_at
                 dismissed_by_id
               ))
    end

    test "filter_version is a not-null integer defaulting to 1, pending_filter_version a nullable integer" do
      assert {"integer", "NO", "1"} = columns("audit_stream_destinations")["filter_version"]
      assert {"integer", "YES", nil} = columns("audit_stream_cursors")["pending_filter_version"]
    end

    test "secrets are bytea columns and the cursor columns are not on the destination" do
      destination_columns = columns("audit_stream_destinations")

      for column <- ~w(url credential signing_secret previous_signing_secret) do
        assert {"bytea", "YES", nil} = destination_columns[column]
      end

      refute Map.has_key?(destination_columns, "last_txid")
      refute Map.has_key?(destination_columns, "pending_batch_id")
    end
  end

  describe "Destination.changeset/2 kinds" do
    test "accepts a valid row of each kind and stores the defaults", ctx do
      for kind <- [:splunk_hec, :datadog, :https] do
        destination = insert!(ctx, kind) |> then(&Repo.get!(Destination, &1.id))

        assert destination.kind == kind
        assert destination.enabled
        assert destination.include_personal_data
        assert destination.excluded_actions == []
        assert destination.filter_version == 1
        assert destination.schema_version == 1
        assert destination.lock_version == 1
        assert destination.state == :healthy
        assert destination.consecutive_failures == 0
        assert destination.halted_reason == nil
      end
    end

    test "a Datadog destination has no url, host or url hint", ctx do
      destination = insert!(ctx, :datadog) |> then(&Repo.get!(Destination, &1.id))

      assert destination.url == nil
      assert destination.url_host == nil
      assert destination.url_hint == nil
      assert Destination.unreadable_secrets(destination) == []
    end

    test "refuses nil for enabled and include_personal_data", ctx do
      for field <- [:enabled, :include_personal_data] do
        assert "can't be blank" in errors_on_field(changeset(ctx, :https, %{field => nil}), field)
      end
    end

    test "refuses a kind outside splunk_hec, datadog and https", ctx do
      changeset = changeset(ctx, %{attrs(:https) | kind: "webhook"})

      assert "is invalid" in errors_on_field(changeset, :kind)
    end

    test "refuses a Datadog destination with a url", ctx do
      changeset = changeset(ctx, :datadog, %{url: @https_url})

      assert :kind in validations(changeset, :url)
    end

    test "requires the secrets each kind needs", ctx do
      assert "can't be blank" in errors_on_field(
               changeset_without(ctx, :splunk_hec, :credential),
               :credential
             )

      assert "can't be blank" in errors_on_field(
               changeset_without(ctx, :splunk_hec, :url),
               :url
             )

      assert "can't be blank" in errors_on_field(
               changeset_without(ctx, :datadog, :credential),
               :credential
             )

      assert "can't be blank" in errors_on_field(
               changeset_without(ctx, :https, :url),
               :url
             )

      assert changeset(ctx, attrs(:https)).valid?
    end

    test "does not cast the Organization or creator", ctx do
      other = organization_fixture()

      changeset =
        changeset(ctx, :https, %{organization_id: other.id, created_by_id: nil})

      assert Ecto.Changeset.get_field(changeset, :organization_id) == ctx.organization.id
      assert Ecto.Changeset.get_field(changeset, :created_by_id) == ctx.user.id
    end
  end

  describe "Destination.changeset/2 name" do
    test "accepts 1 to 80 characters, counting Unicode characters", ctx do
      assert changeset(ctx, %{attrs(:https) | name: "a"}).valid?

      name = String.duplicate("é", 80)
      destination = insert!(ctx, :https, %{name: name})
      assert Repo.get!(Destination, destination.id).name == name
    end

    test "refuses 81 characters, and 80 graphemes made of 160 codepoints", ctx do
      assert "should be at most 80 character(s)" in errors_on_field(
               changeset(ctx, %{attrs(:https) | name: String.duplicate("é", 81)}),
               :name
             )

      # q with an acute accent has no precomposed form, so NFC keeps it as
      # two codepoints; a decomposed é is composed into one and fits.
      decomposed = String.duplicate("q\u0301", 80)
      assert String.length(decomposed) == 80
      refute changeset(ctx, %{attrs(:https) | name: decomposed}).valid?

      assert changeset(ctx, %{attrs(:https) | name: String.duplicate("e\u0301", 80)}).valid?
    end

    test "refuses a blank or invisible name", ctx do
      for name <- ["", "   ", "​‍"] do
        assert "can't be blank" in errors_on_field(
                 changeset(ctx, %{attrs(:https) | name: name}),
                 :name
               )
      end
    end

    test "normalizes the name: NFC, invisible characters removed, trimmed", ctx do
      for {name, normalized} <- [
            {"Splunk\u200B", "Splunk"},
            {"\u202ESplunk", "Splunk"},
            {"\uFEFFSplunk", "Splunk"},
            {"  Splunk  ", "Splunk"},
            {"Caf" <> "e\u0301", "Café"},
            {"a\u200Db", "a\u200Db"}
          ] do
        changeset = changeset(ctx, %{attrs(:https) | name: name})
        assert Ecto.Changeset.get_field(changeset, :name) == normalized
      end
    end

    test "treats names that look the same as the same name", ctx do
      insert!(ctx, :https, %{name: "Café"})

      for lookalike <- ["Caf" <> "e\u0301", "Café\u200B", " Café", "\u2066Café"] do
        assert {:error, changeset} = ctx |> changeset(:https, %{name: lookalike}) |> Repo.insert()
        assert "has already been taken" in errors_on_field(changeset, :name)
      end
    end

    test "is unique per Organization", ctx do
      insert!(ctx, :https)

      assert {:error, changeset} = ctx |> changeset(attrs(:https)) |> Repo.insert()
      assert "has already been taken" in errors_on_field(changeset, :name)

      other = %{ctx | organization: organization_fixture()}
      assert {:ok, _destination} = other |> changeset(attrs(:https)) |> Repo.insert()
    end
  end

  describe "Destination.changeset/2 settings" do
    test "stores atom keys as strings", ctx do
      destination = insert!(ctx, :splunk_hec, %{settings: %{index: "main"}})

      assert Repo.get!(Destination, destination.id).settings == %{"index" => "main"}
    end

    test "refuses keys another kind uses, unknown keys and non-text values", ctx do
      for settings <- [
            %{"site" => "datadoghq.com"},
            %{"token" => "abc"},
            %{"index" => 5},
            %{"index" => ["main"]},
            %{"index" => "nul\0byte"}
          ] do
        assert :settings in validations(
                 changeset(ctx, %{attrs(:splunk_hec) | settings: settings}),
                 :settings
               )
      end

      for tags <- ["env:prod", [1], ["ok", nil]] do
        settings = %{"tags" => tags}

        assert :settings in validations(
                 changeset(ctx, %{attrs(:datadog) | settings: settings}),
                 :settings
               )
      end
    end

    test "accepts empty settings", ctx do
      # No header name, so no header value either (W2707: they come together).
      assert changeset(ctx, %{attrs(:https) | settings: %{}, credential: nil}).valid?
    end

    test "refuses nil settings without raising", ctx do
      assert "can't be blank" in errors_on_field(
               changeset(ctx, %{attrs(:https) | settings: nil}),
               :settings
             )
    end
  end

  describe "Destination.changeset/2 excluded_actions" do
    test "accepts an empty list and known audit actions, without duplicates", ctx do
      assert changeset(ctx, :https, %{excluded_actions: []}).valid?

      [action | _rest] = Destination.excludable_actions()
      changeset = changeset(ctx, :https, %{excluded_actions: [action, action]})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :excluded_actions) == [action]

      destination = Repo.insert!(changeset)
      cleared = destination |> Destination.changeset(%{excluded_actions: []}) |> Repo.update!()
      assert Repo.get!(Destination, cleared.id).excluded_actions == []
    end

    test "refuses nil, and a nil action, without raising", ctx do
      assert "can't be blank" in errors_on_field(
               changeset(ctx, :https, %{excluded_actions: nil}),
               :excluded_actions
             )

      [action | _rest] = Destination.excludable_actions()
      changeset = changeset(ctx, :https, %{excluded_actions: [action, nil]})
      refute changeset.valid?
      assert errors_on_field(changeset, :excluded_actions) != []
    end

    test "refuses an unknown action", ctx do
      changeset = changeset(ctx, :https, %{excluded_actions: ["not_an_action"]})

      assert :subset in validations(changeset, :excluded_actions)
    end

    test "refuses every audit_stream_ action", ctx do
      for action <- ["audit_stream_destination_created", "audit_stream_"] do
        changeset = changeset(ctx, :https, %{excluded_actions: [action]})

        assert :audit_stream_action in validations(changeset, :excluded_actions)
      end
    end

    test "excludable_actions/0 lists audit actions and no audit_stream_ action" do
      actions = Destination.excludable_actions()

      assert actions != []
      assert Enum.all?(actions, &is_binary/1)
      refute Enum.any?(actions, &String.starts_with?(&1, "audit_stream_"))
    end

    test "excludable_actions/1 drops audit_stream_ and non-audit actions from the events given" do
      events = [
        %{domain: :audit, name: [:kanban, :audit, :board_deleted]},
        %{domain: :audit, name: [:kanban, :audit, :audit_stream_destination_created]},
        %{domain: :api, name: [:kanban, :api, :request]}
      ]

      assert Destination.excludable_actions(events) == ["board_deleted"]
    end
  end

  describe "Destination.changeset/2 hints" do
    test "derives url_host, url_hint and credential_hint from the plaintext", ctx do
      destination = insert!(ctx, :splunk_hec)

      assert destination.url_host == "collector.example.com"
      assert destination.url_hint == "ctor"
      assert destination.credential_hint == "wxyz"
    end

    test "lowercases the host", ctx do
      assert ctx
             |> changeset(%{attrs(:https) | url: "https://SIEM.Example.ORG/x/abcdef"})
             |> Ecto.Changeset.get_change(:url_host) ==
               "siem.example.org"
    end

    test "refuses a URL with no host, or one that does not parse", ctx do
      for url <- [
            "not a url at all",
            "https://siem.example.org/a b",
            "mailto:security-team@example.org",
            "https:///no-host-here/ingest"
          ] do
        changeset = changeset(ctx, %{attrs(:https) | url: url})
        assert :url in validations(changeset, :url), url
      end
    end

    test "refuses a URL that is not valid UTF-8 without raising", ctx do
      changeset = changeset(ctx, %{attrs(:https) | url: "https://siem.example.org/" <> <<0xFF>>})

      refute changeset.valid?
      assert errors_on_field(changeset, :url) != []
    end

    test "stores a hint of 4 codepoints of any width", ctx do
      # No credential a kind accepts carries more than ASCII (each is sent as
      # a header value), so the column is checked directly; how a hint is cut
      # is in Kanban.AuditStream.SecretHintTest.
      flag = "\u{1F1EB}\u{1F1F7}"
      destination = insert!(ctx, :datadog)

      from(d in Destination, where: d.id == ^destination.id)
      |> Repo.update_all(set: [credential_hint: flag <> flag])

      assert Repo.get!(Destination, destination.id).credential_hint == flag <> flag
    end

    test "gives no hint for a secret shorter than 16 characters", ctx do
      for short <- ["a", "abcd", "abcde", String.duplicate("x", 15)] do
        changeset = changeset(ctx, %{attrs(:splunk_hec) | credential: short})
        assert Ecto.Changeset.get_field(changeset, :credential_hint) == nil
      end

      changeset = changeset(ctx, %{attrs(:splunk_hec) | credential: "abcdefghijklmnop"})
      assert Ecto.Changeset.get_field(changeset, :credential_hint) == "mnop"
    end

    test "refuses a URL whose host is longer than 253 characters", ctx do
      long_host = String.duplicate("a", 60) |> List.duplicate(5) |> Enum.join(".")
      assert byte_size(long_host) > 253

      changeset = changeset(ctx, %{attrs(:https) | url: "https://#{long_host}/ingest"})
      assert :url_host in validations(changeset, :url)
      assert Ecto.Changeset.get_change(changeset, :url_host) == nil

      host = String.duplicate("b", 63) |> List.duplicate(3) |> Enum.join(".")
      assert byte_size(host) <= 253
      destination = insert!(ctx, :https, %{url: "https://#{host}/ingest"})
      assert destination.url_host == host
    end

    test "recomputes the hint when the credential changes", ctx do
      destination = insert!(ctx, :https, %{credential: "first-credential"})
      assert destination.credential_hint == "tial"

      updated =
        destination
        |> Destination.changeset(%{credential: "second-credential-value"})
        |> Repo.update!()

      assert updated.credential_hint == "alue"

      # The header value goes with its name (W2707), so both are cleared.
      cleared =
        updated
        |> Destination.changeset(%{credential: nil, settings: %{"format" => "ndjson"}})
        |> Repo.update!()

      assert cleared.credential_hint == nil
    end
  end

  describe "secrets at rest" do
    test "are stored encrypted and load back decrypted", ctx do
      destination =
        ctx
        |> insert!(:splunk_hec)
        |> Destination.signing_secret_changeset(%{
          signing_secret: "current-signing-secret",
          previous_signing_secret: "previous-signing-secret"
        })
        |> Repo.update!()

      plaintexts = [
        @splunk_url,
        @splunk_token,
        "current-signing-secret",
        "previous-signing-secret"
      ]

      stored =
        raw_columns(destination.id, ~w(url credential signing_secret previous_signing_secret))

      for {ciphertext, plaintext} <- Enum.zip(stored, plaintexts) do
        refute ciphertext =~ plaintext
        assert {:ok, ^plaintext} = Encryption.decrypt(ciphertext)
      end

      loaded = Repo.get!(Destination, destination.id)
      assert loaded.url == @splunk_url
      assert loaded.credential == @splunk_token
      assert loaded.signing_secret == "current-signing-secret"
      assert loaded.previous_signing_secret == "previous-signing-secret"
    end

    test "are redacted from inspect output of the struct and the changeset", ctx do
      changeset =
        changeset(ctx, attrs(:splunk_hec))
        |> Ecto.Changeset.put_change(:signing_secret, "current-signing-secret")

      destination = Repo.insert!(changeset)
      loaded = Repo.get!(Destination, destination.id)

      for output <- [inspect(changeset), inspect(destination), inspect(loaded)],
          secret <- [@splunk_url, @splunk_token, "current-signing-secret"] do
        refute output =~ secret
      end
    end
  end

  describe "unreadable secrets" do
    test "a row whose credential cannot be decrypted loads, and unreadable_secrets/1 lists it",
         ctx do
      destination = insert!(ctx, :splunk_hec)
      tamper!(destination.id, "credential")

      loaded = Repo.get!(Destination, destination.id)

      assert loaded.credential == :unreadable
      assert loaded.url == @splunk_url
      assert Destination.unreadable_secrets(loaded) == [:credential]
      refute inspect(loaded) =~ "unreadable"
    end

    test "only the previous signing secret is unreadable while the current one reads", ctx do
      destination =
        ctx
        |> insert!(:https)
        |> Destination.signing_secret_changeset(%{
          signing_secret: "current-signing-secret",
          previous_signing_secret: "previous-signing-secret"
        })
        |> Repo.update!()

      tamper!(destination.id, "previous_signing_secret")
      loaded = Repo.get!(Destination, destination.id)

      assert loaded.signing_secret == "current-signing-secret"
      assert Destination.unreadable_secrets(loaded) == [:previous_signing_secret]
    end

    test "lists every unreadable field in order", ctx do
      destination =
        ctx
        |> insert!(:splunk_hec)
        |> Destination.signing_secret_changeset(%{signing_secret: "current-signing-secret"})
        |> Repo.update!()

      for column <- ~w(signing_secret url credential), do: tamper!(destination.id, column)

      assert Destination
             |> Repo.get!(destination.id)
             |> Destination.unreadable_secrets() == [:url, :credential, :signing_secret]
    end

    test "the marker can never be written over the stored ciphertext", ctx do
      destination = insert!(ctx, :splunk_hec)
      [stored] = raw_columns(destination.id, ["credential"])

      assert_raise Ecto.ChangeError, fn ->
        destination |> Ecto.Changeset.change(credential: :unreadable) |> Repo.update()
      end

      refute Destination.changeset(destination, %{credential: :unreadable}).valid?
      assert raw_columns(destination.id, ["credential"]) == [stored]
    end

    test "saving an unrelated field leaves an unreadable credential untouched", ctx do
      destination = insert!(ctx, :splunk_hec)
      tamper!(destination.id, "credential")
      [tampered] = raw_columns(destination.id, ["credential"])

      Destination
      |> Repo.get!(destination.id)
      |> Destination.changeset(%{name: "Renamed"})
      |> Repo.update!()

      assert raw_columns(destination.id, ["credential", "name"]) == [tampered, "Renamed"]
    end
  end

  describe "Destination.status_changeset/2" do
    test "halted_reason accepts the four reasons, credentials_unreadable among them", ctx do
      destination = insert!(ctx, :https)

      for reason <- ~w(rejected_batch blocked_address txid_reset credentials_unreadable) do
        updated =
          destination |> Destination.status_changeset(%{halted_reason: reason}) |> Repo.update!()

        assert Atom.to_string(updated.halted_reason) == reason
      end

      assert :credentials_unreadable in Destination.halted_reasons()
    end

    test "refuses an unknown halted_reason or state", ctx do
      destination = insert!(ctx, :https)

      refute Destination.status_changeset(destination, %{halted_reason: "other"}).valid?
      refute Destination.status_changeset(destination, %{state: "broken"}).valid?
      refute Destination.status_changeset(destination, %{consecutive_failures: -1}).valid?

      assert Destination.status_changeset(destination, %{
               state: "failing",
               state_reason: "HTTP 503"
             }).valid?
    end
  end

  describe "Cursor" do
    test "is keyed by destination and stores the pending batch", ctx do
      destination = insert!(ctx, :https)
      batch_id = Ecto.UUID.generate()

      cursor =
        %Cursor{destination_id: destination.id}
        |> Cursor.changeset(%{
          last_txid: 10,
          last_event_id: 20,
          pending_batch_id: batch_id,
          pending_filter_version: 2
        })
        |> Repo.insert!()

      loaded = Repo.get!(Cursor, destination.id)
      assert loaded.pending_batch_id == batch_id
      assert loaded.pending_filter_version == 2
      assert loaded.pending_attempts == 0
      assert cursor.updated_at

      assert {:error, changeset} =
               %Cursor{destination_id: destination.id}
               |> Cursor.changeset(%{last_txid: 1, last_event_id: 1})
               |> Repo.insert()

      assert "has already been taken" in errors_on_field(changeset, :destination_id)
    end

    test "pending_filter_version may be nil; last_txid and last_event_id are required", ctx do
      destination = insert!(ctx, :https)
      base = %Cursor{destination_id: destination.id}

      assert Cursor.changeset(base, %{last_txid: 0, last_event_id: 0}).valid?

      assert "can't be blank" in errors_on_field(
               Cursor.changeset(base, %{last_event_id: 0}),
               :last_txid
             )

      refute Cursor.changeset(base, %{last_txid: 0, last_event_id: 0, pending_attempts: -1}).valid?
    end

    test "the restored bound is set whole or not at all", ctx do
      destination = insert!(ctx, :https)
      base = %Cursor{destination_id: destination.id}
      attrs = %{last_txid: 0, last_event_id: 0}

      cursor =
        base
        |> Cursor.changeset(Map.merge(attrs, %{restored_max_event_id: 7, restored_min_txid: 9}))
        |> Repo.insert!()

      assert {cursor.restored_max_event_id, cursor.restored_min_txid} == {7, 9}

      for half <- [%{restored_max_event_id: 7}, %{restored_min_txid: 9}] do
        assert "must be set with restored_min_txid" in errors_on_field(
                 Cursor.changeset(base, Map.merge(attrs, half)),
                 :restored_max_event_id
               )
      end

      # The check constraint holds even for a write that skips the changeset.
      assert_raise Postgrex.Error, ~r/audit_stream_cursors_restored_bound_complete/, fn ->
        Repo.query!(
          "UPDATE audit_stream_cursors SET restored_min_txid = NULL WHERE destination_id = $1",
          [destination.id]
        )
      end
    end
  end

  describe "Attempt" do
    defp attempt_attrs(destination, extra) do
      Map.merge(
        %{
          destination_id: destination.id,
          batch_id: Ecto.UUID.generate(),
          started_at: DateTime.utc_now(),
          outcome: :delivered
        },
        extra
      )
    end

    test "accepts each of the seven outcomes and refuses any other", ctx do
      destination = insert!(ctx, :https)

      for outcome <- ~w(delivered retry rejected unauthorized config_error blocked skipped) do
        attempt =
          %Attempt{}
          |> Attempt.changeset(attempt_attrs(destination, %{outcome: outcome}))
          |> Repo.insert!()

        assert Atom.to_string(attempt.outcome) == outcome
      end

      assert length(Attempt.outcomes()) == 7
      refute Attempt.changeset(%Attempt{}, attempt_attrs(destination, %{outcome: "other"})).valid?
    end

    test "cuts an error to 200 characters", ctx do
      destination = insert!(ctx, :https)

      attempt =
        %Attempt{}
        |> Attempt.changeset(
          attempt_attrs(destination, %{outcome: :retry, error: String.duplicate("é", 201)})
        )
        |> Repo.insert!()

      assert Repo.get!(Attempt, attempt.id).error == String.duplicate("é", 200)
    end

    test "cuts by codepoints, so an error of multi-codepoint graphemes still inserts", ctx do
      destination = insert!(ctx, :https)
      decomposed = String.duplicate("e\u0301", 201)

      attempt =
        %Attempt{}
        |> Attempt.changeset(attempt_attrs(destination, %{outcome: :retry, error: decomposed}))
        |> Repo.insert!()

      stored = Repo.get!(Attempt, attempt.id).error
      assert length(String.codepoints(stored)) == 200
      assert String.starts_with?(decomposed, stored)
    end

    test "requires the destination, batch, start time and outcome" do
      changeset = Attempt.changeset(%Attempt{}, %{})

      for field <- [:destination_id, :batch_id, :started_at, :outcome] do
        assert "can't be blank" in errors_on_field(changeset, field)
      end
    end
  end

  describe "Gap" do
    defp gap_attrs(destination, extra) do
      now = DateTime.utc_now()

      Map.merge(
        %{
          destination_id: destination.id,
          reason: :retention,
          events: 3,
          first_occurred_at: now,
          last_occurred_at: now,
          opened_at: now,
          last_extended_at: now
        },
        extra
      )
    end

    test "accepts retention, too_old and database_move and refuses any other reason", ctx do
      destination = insert!(ctx, :https)

      for reason <- ~w(retention too_old database_move) do
        gap = %Gap{} |> Gap.changeset(gap_attrs(destination, %{reason: reason})) |> Repo.insert!()
        assert Atom.to_string(gap.reason) == reason
      end

      refute Gap.changeset(%Gap{}, gap_attrs(destination, %{reason: "other"})).valid?
      refute Gap.changeset(%Gap{}, gap_attrs(destination, %{events: -1})).valid?
    end

    test "dismiss_changeset/3 records who dismissed it and when", ctx do
      destination = insert!(ctx, :https)
      gap = %Gap{} |> Gap.changeset(gap_attrs(destination, %{})) |> Repo.insert!()
      at = DateTime.utc_now()

      dismissed = gap |> Gap.dismiss_changeset(ctx.user.id, at) |> Repo.update!()

      assert dismissed.dismissed_by_id == ctx.user.id
      assert dismissed.dismissed_at == at
    end
  end

  describe "deletion" do
    defp with_children!(ctx) do
      destination = insert!(ctx, :https)
      now = DateTime.utc_now()

      %Cursor{destination_id: destination.id}
      |> Cursor.changeset(%{last_txid: 1, last_event_id: 1})
      |> Repo.insert!()

      %Attempt{}
      |> Attempt.changeset(%{
        destination_id: destination.id,
        batch_id: Ecto.UUID.generate(),
        started_at: now,
        outcome: :delivered
      })
      |> Repo.insert!()

      gap =
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
        |> Gap.dismiss_changeset(ctx.user.id, now)
        |> Repo.update!()

      {destination, gap}
    end

    defp counts(destination_id) do
      for schema <- [Cursor, Attempt, Gap] do
        schema
        |> where([row], row.destination_id == ^destination_id)
        |> Repo.aggregate(:count)
      end
    end

    test "deleting a destination deletes its cursor, attempts and gaps", ctx do
      {destination, _gap} = with_children!(ctx)
      assert counts(destination.id) == [1, 1, 1]

      Repo.delete!(destination)

      assert counts(destination.id) == [0, 0, 0]
    end

    test "deleting the Organization cascades to destinations and their children", ctx do
      {destination, _gap} = with_children!(ctx)

      Repo.delete!(ctx.organization)

      refute Repo.get(Destination, destination.id)
      assert counts(destination.id) == [0, 0, 0]
    end

    test "deleting a user nils created_by_id and dismissed_by_id", ctx do
      {destination, gap} = with_children!(ctx)
      assert gap.dismissed_by_id == ctx.user.id

      Repo.delete!(ctx.user)

      assert Repo.get!(Destination, destination.id).created_by_id == nil
      assert Repo.get!(Gap, gap.id).dismissed_by_id == nil
    end
  end
end
