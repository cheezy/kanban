defmodule Kanban.AuditLog.SignedExportTest do
  # async: false — the tests set the application config of
  # Kanban.AuditLog.SignedExport (the temporary root) and some replace
  # Kanban.AuditLog.Signing's, both of which are global.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export
  alias Kanban.AuditLog.Filters
  alias Kanban.AuditLog.SignedExport
  alias Kanban.AuditLog.Signing

  @moduletag :tmp_dir

  @base ~U[2026-10-03 00:00:00.000000Z]
  @keys_url "https://stride.test/.well-known/stride-audit-signing-keys"
  @entry_names ~w(README.txt manifest.json manifest.json.sig)

  setup %{tmp_dir: tmp_dir} do
    saved =
      for module <- [SignedExport, Signing], do: {module, Application.fetch_env(:kanban, module)}

    Application.put_env(:kanban, SignedExport, tmp_root: tmp_dir)

    on_exit(fn ->
      for {module, env} <- saved do
        case env do
          {:ok, config} -> Application.put_env(:kanban, module, config)
          :error -> Application.delete_env(:kanban, module)
        end
      end
    end)

    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)

    %{organization: organization, org_admin: org_admin, root: tmp_dir}
  end

  defp insert_event!(organization, seconds, attrs \\ %{}) do
    %AuditEvent{
      action: "signed_export_test",
      organization_id: organization.id,
      inserted_at: DateTime.add(@base, seconds),
      metadata: %{}
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp opts(%{organization: organization, org_admin: org_admin}, overrides) do
    Keyword.merge(
      [
        format: :csv,
        organization: %{id: organization.id, name: organization.name},
        generated_by: %{user_id: org_admin.id, email: org_admin.email},
        instance: "stride.test",
        keys_url: @keys_url,
        max_rows: 50
      ],
      overrides
    )
  end

  defp with_archive(context, fun, overrides \\ [], params \\ %{}) do
    parsed = Filters.parse(params)
    opts = opts(context, overrides)

    SignedExport.with_archive(parsed, opts, fun)
  end

  # Builds the archive and reads everything out of it while it still exists.
  defp build!(context, overrides \\ [], params \\ %{}) do
    assert {:ok, built} = with_archive(context, &read/1, overrides, params)

    built
  end

  defp never_called(_archive), do: flunk("the function must not run when the build fails")

  defp put_file!(dir, name, bytes), do: dir |> Path.join(name) |> File.write!(bytes)

  defp read(archive) do
    {:ok, entries} =
      archive.zip_path
      |> String.to_charlist()
      |> :zip.unzip([:memory])

    entries = Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end)
    manifest = entries["manifest.json"]

    %{
      archive: archive,
      entries: entries,
      file: entries["audit_log.#{archive.format}"],
      manifest: Jason.decode!(manifest),
      manifest_bytes: manifest,
      signature: entries["manifest.json.sig"],
      readme: entries["README.txt"]
    }
  end

  defp unsigned(organization, format, max_rows) do
    [organization_id: organization.id]
    |> Export.export_stream(format, max_rows: max_rows, redact_actors_outside: organization.id)
    |> Enum.join()
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # Runs `fun` once, in the test process, when the build issues its first read
  # of audit_events: the temporary directory exists by then and the export
  # file is open, so this is "during the build".
  defp on_first_read(fun) do
    test_pid = self()
    handler_id = "signed-export-first-read-#{System.unique_integer([:positive])}"
    fired = :counters.new(1, [])

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and audit_read?(metadata) and :counters.get(fired, 1) == 0 do
          :counters.add(fired, 1, 1)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp audit_read?(%{source: "audit_events", query: "SELECT" <> _rest}), do: true
  defp audit_read?(_metadata), do: false

  # The guard removes the directory from its own process, so wait for it.
  defp emptied?(root, attempts \\ 200) do
    cond do
      File.ls!(root) == [] ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        emptied?(root, attempts - 1)
    end
  end

  defp build_dir(root) do
    assert [name] = File.ls!(root)
    Path.join(root, name)
  end

  describe "the archive" do
    test "the zip holds exactly the four named entries", context do
      insert_event!(context.organization, 1)

      csv = build!(context)

      assert csv.entries |> Map.keys() |> Enum.sort() ==
               Enum.sort(["audit_log.csv" | @entry_names])

      json = build!(context, format: :json)

      assert json.entries |> Map.keys() |> Enum.sort() ==
               Enum.sort(["audit_log.json" | @entry_names])
    end

    test "the CSV and JSON files equal the Export encoders' output for the same events",
         context do
      for i <- 1..5, do: insert_event!(context.organization, i)

      for format <- [:csv, :json], batch_size <- [1, 2, 500] do
        built = build!(context, format: format, batch_size: batch_size)
        assert built.file == unsigned(context.organization, format, 50)
      end
    end

    test "CSV metadata holding commas, quotes and non-ASCII text matches the unsigned file",
         context do
      insert_event!(context.organization, 1, %{metadata: %{"note" => "a, \"quoted\" ✓ 監査"}})

      built = build!(context)

      assert built.file == unsigned(context.organization, :csv, 50)
      assert built.file =~ "監査"
      assert built.manifest["file"]["sha256"] == sha256(built.file)
    end

    test "holds only the Organization's events, whatever the parsed filters say", context do
      other = organization_fixture()
      insert_event!(context.organization, 1)
      insert_event!(other, 2, %{metadata: %{"note" => "other-organization"}})

      built = build!(context, [format: :json], %{"organization_id" => "#{other.id}"})

      assert [%{"id" => _id}] = Jason.decode!(built.file)
      refute built.file =~ "other-organization"
      assert built.manifest["organization"]["id"] == context.organization.id
    end

    test "outside actors are redacted in the signed file", context do
      outsider = user_fixture()

      insert_event!(context.organization, 1, %{
        actor_user_id: outsider.id,
        actor_in_organization: false,
        ip: "203.0.113.7",
        metadata: %{"user_id" => outsider.id}
      })

      for format <- [:csv, :json] do
        built = build!(context, format: format)

        refute built.file =~ outsider.email
        refute built.file =~ "203.0.113.7"
        refute built.manifest_bytes =~ outsider.email
        assert built.file == unsigned(context.organization, format, 50)
      end
    end

    test "the actor-email filter is never applied", context do
      insert_event!(context.organization, 1)

      built = build!(context, [format: :json], %{"actor_email" => "nobody@example.test"})

      assert [_row] = Jason.decode!(built.file)
      refute Map.has_key?(built.manifest["filters"], "actor_email")
      refute built.manifest_bytes =~ "nobody@example.test"
    end

    test "an event recorded during the build is not in the file", context do
      insert_event!(context.organization, 1)
      insert_event!(context.organization, 2)

      on_first_read(fn ->
        insert_event!(context.organization, 99, %{metadata: %{"note" => "recorded-during-build"}})
      end)

      built = build!(context, format: :json, batch_size: 1)

      assert length(Jason.decode!(built.file)) == 2
      refute built.file =~ "recorded-during-build"
      assert built.manifest["rows"] == 2
    end
  end

  describe "the manifest" do
    test "sha256, bytes and rows match the file", context do
      for i <- 1..3, do: insert_event!(context.organization, i)

      for format <- [:csv, :json] do
        built = build!(context, format: format)
        manifest = built.manifest

        assert manifest["file"] == %{
                 "name" => "audit_log.#{format}",
                 "format" => Atom.to_string(format),
                 "bytes" => byte_size(built.file),
                 "sha256" => sha256(built.file)
               }

        assert manifest["rows"] == 3
        assert built.archive.sha256 == sha256(built.file)
        assert built.archive.bytes == byte_size(built.file)
        assert built.archive.rows == 3
      end
    end

    test "carries the documented fields in the documented order", context do
      insert_event!(context.organization, 1)

      built = build!(context)

      ordered = Jason.decode!(built.manifest_bytes, objects: :ordered_objects)

      assert Enum.map(ordered.values, &elem(&1, 0)) ==
               ~w(schema instance organization generated_at generated_by filters file rows
                  oldest_event newest_event truncated key_id)

      manifest = built.manifest
      assert manifest["schema"] == "stride.audit-export.v1"
      assert manifest["instance"] == "stride.test"

      assert manifest["organization"] ==
               %{"id" => context.organization.id, "name" => context.organization.name}

      assert manifest["generated_by"] ==
               %{"user_id" => context.org_admin.id, "email" => context.org_admin.email}

      assert manifest["generated_at"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
      assert manifest["key_id"] == Signing.current_key().key_id
      assert manifest["key_id"] == built.archive.key_id
      assert manifest["truncated"] == false

      # Pretty-printed, with one trailing newline.
      assert built.manifest_bytes =~ ~s(\n  "schema": "stride.audit-export.v1",\n)
      assert String.ends_with?(built.manifest_bytes, "}\n")
      refute String.ends_with?(built.manifest_bytes, "\n\n")
    end

    test "newest_event is the first row and oldest_event the last; both null when empty",
         context do
      empty = build!(context, format: :json)

      assert empty.manifest["rows"] == 0
      assert empty.manifest["newest_event"] == nil
      assert empty.manifest["oldest_event"] == nil
      assert empty.manifest["truncated"] == false
      assert empty.file == "[]"
      assert Map.has_key?(empty.manifest, "newest_event")
      assert Map.has_key?(empty.manifest, "oldest_event")

      assert build!(context).file == Export.csv_header()

      oldest = insert_event!(context.organization, 1)
      insert_event!(context.organization, 2)
      newest = insert_event!(context.organization, 3)

      built = build!(context, format: :json, batch_size: 2)
      rows = Jason.decode!(built.file)

      assert built.manifest["newest_event"] ==
               %{"id" => newest.id, "inserted_at" => DateTime.to_iso8601(newest.inserted_at)}

      assert built.manifest["oldest_event"] ==
               %{"id" => oldest.id, "inserted_at" => DateTime.to_iso8601(oldest.inserted_at)}

      assert built.manifest["newest_event"] ==
               rows |> List.first() |> Map.take(~w(id inserted_at))

      assert built.manifest["oldest_event"] == rows |> List.last() |> Map.take(~w(id inserted_at))
      assert is_integer(built.manifest["newest_event"]["id"])
    end

    test "truncated is false at exactly the cap and true at cap plus one, and the file holds cap rows",
         context do
      events = for i <- 1..4, do: insert_event!(context.organization, i)

      # Batch sizes that end a batch before, on and after the cap.
      for format <- [:csv, :json], batch_size <- [1, 2, 3, 4, 500] do
        at_cap = build!(context, format: format, max_rows: 4, batch_size: batch_size)

        refute at_cap.manifest["truncated"]
        refute at_cap.archive.truncated
        assert at_cap.manifest["rows"] == 4
        assert at_cap.file == unsigned(context.organization, format, 4)

        cut = build!(context, format: format, max_rows: 3, batch_size: batch_size)

        assert cut.manifest["truncated"]
        assert cut.archive.truncated
        assert cut.manifest["rows"] == 3
        assert cut.file == unsigned(context.organization, format, 3)
        assert cut.manifest["file"]["sha256"] == sha256(cut.file)
      end

      # The row past the cap, the oldest, is never written.
      cut = build!(context, format: :json, max_rows: 3)
      ids = cut.file |> Jason.decode!() |> Enum.map(& &1["id"])

      assert ids == events |> Enum.drop(1) |> Enum.map(& &1.id) |> Enum.reverse()
      assert cut.manifest["oldest_event"]["id"] == Enum.at(events, 1).id
    end

    test "filters absent from the request are null in the manifest", context do
      assert build!(context).manifest["filters"] ==
               %{"action" => nil, "from" => nil, "to" => nil}

      insert_event!(context.organization, 1)
      insert_event!(context.organization, 2, %{action: "another_action"})

      params = %{"action" => "signed_export_test", "from" => "2026-10-01", "to" => "2026-10-31"}
      built = build!(context, [format: :json], params)

      assert built.manifest["filters"] == params
      assert [%{"action" => "signed_export_test"}] = Jason.decode!(built.file)

      ordered = Jason.decode!(built.manifest_bytes, objects: :ordered_objects)
      assert Enum.map(ordered["filters"].values, &elem(&1, 0)) == ~w(action from to)
    end
  end

  describe "the signature" do
    test "verifies over manifest bytes and fails after one changed byte", context do
      insert_event!(context.organization, 1)

      built = build!(context)
      key_id = built.manifest["key_id"]
      {:ok, %{public_key: public_key}} = Signing.find_published(key_id)

      assert byte_size(built.signature) == 64
      assert Signing.verify(built.manifest_bytes, built.signature, key_id)

      assert :crypto.verify(:eddsa, :none, built.manifest_bytes, built.signature, [
               public_key,
               :ed25519
             ])

      <<first, rest::binary>> = built.manifest_bytes
      changed = <<Bitwise.bxor(first, 1), rest::binary>>

      refute Signing.verify(changed, built.signature, key_id)
      refute :crypto.verify(:eddsa, :none, changed, built.signature, [public_key, :ed25519])

      # A re-encoded manifest is different bytes: only the written bytes verify.
      reencoded = built.manifest_bytes |> Jason.decode!() |> Jason.encode!()
      refute Signing.verify(reencoded, built.signature, key_id)
    end

    @tag :openssl3
    test "the README openssl pkeyutl command verifies the signature", context do
      openssl = Kanban.OpenSSL3.executable()

      assert openssl,
             "this test needs OpenSSL 3.0 or later on the PATH; LibreSSL cannot verify Ed25519"

      insert_event!(context.organization, 1)
      built = build!(context)

      dir = Path.join(context.root, "verify")
      File.mkdir_p!(dir)
      {:ok, %{public_key: public_key}} = Signing.find_published(built.manifest["key_id"])
      put_file!(dir, "stride-audit.pem", Signing.public_key_pem(public_key))
      put_file!(dir, "manifest.json", built.manifest_bytes)
      put_file!(dir, "manifest.json.sig", built.signature)
      put_file!(dir, "audit_log.csv", built.file)

      # The command exactly as the README gives it.
      assert [command] = Regex.run(~r/^openssl pkeyutl .+$/m, built.readme)
      ["openssl" | args] = String.split(command)

      assert {output, 0} = System.cmd(openssl, args, cd: dir, stderr_to_stdout: true)
      assert output =~ "Signature Verified Successfully"

      assert {digest, 0} = System.cmd(openssl, ~w(dgst -sha256 -r audit_log.csv), cd: dir)
      assert digest =~ built.manifest["file"]["sha256"]

      <<first, rest::binary>> = built.manifest_bytes
      put_file!(dir, "manifest.json", <<Bitwise.bxor(first, 1), rest::binary>>)

      assert {_output, status} = System.cmd(openssl, args, cd: dir, stderr_to_stdout: true)
      assert status != 0
    end
  end

  describe "the README" do
    test "gives the three commands with this instance's key URL and the manifest's key id",
         context do
      built = build!(context)
      key_id = built.manifest["key_id"]
      readme = built.readme

      assert readme =~ ~s(curl -fsS "#{@keys_url}?format=pem&kid=#{key_id}" -o stride-audit.pem)

      assert readme =~
               "openssl pkeyutl -verify -pubin -inkey stride-audit.pem -rawin " <>
                 "-in manifest.json -sigfile manifest.json.sig"

      assert readme =~ "\nshasum -a 256 audit_log.csv\n"
      assert readme =~ "OpenSSL 3.0 or later"
      assert readme =~ "LibreSSL"
      assert readme =~ "brew install openssl@3"
      assert readme =~ "Python"
      assert readme =~ "docs/audit-log-signed-exports.md"
      assert readme =~ "file.sha256"
    end

    test "names the JSON file for a JSON export", context do
      readme = build!(context, format: :json).readme

      assert readme =~ "\nshasum -a 256 audit_log.json\n"
      refute readme =~ "audit_log.csv"
    end
  end

  describe "the temp dir" do
    test "is owner-only, holds the zip while the function runs, and is removed afterwards",
         context do
      insert_event!(context.organization, 1)

      assert {:ok, dir} =
               with_archive(context, fn archive ->
                 dir = Path.dirname(archive.zip_path)
                 assert dir == build_dir(context.root)
                 assert Path.basename(dir) =~ ~r/\A\.tmp-[A-Za-z0-9_-]{22}\z/
                 assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
                 assert File.regular?(archive.zip_path)
                 dir
               end)

      refute File.exists?(dir)
      assert File.ls!(context.root) == []
    end

    test "is removed after success and after a forced write failure", context do
      insert_event!(context.organization, 1)

      build!(context)
      assert File.ls!(context.root) == []

      # A directory planted where manifest.json goes makes that write fail
      # after the temporary directory and the export file exist.
      on_first_read(fn ->
        context.root |> build_dir() |> Path.join("manifest.json") |> File.mkdir!()
      end)

      log =
        capture_log(fn ->
          assert {:error, :build_failed} =
                   with_archive(context, &never_called/1)
        end)

      assert File.ls!(context.root) == []
      assert log =~ "signed audit export failed: :eisdir"
      refute log =~ context.root
    end

    test "a zip that cannot be written fails the build and leaves nothing", context do
      insert_event!(context.organization, 1)

      # A directory planted where export.zip goes makes the zip step fail
      # after the export file, the manifest and the signature are written.
      on_first_read(fn ->
        context.root |> build_dir() |> Path.join("export.zip") |> File.mkdir!()
      end)

      log =
        capture_log(fn ->
          assert {:error, :build_failed} =
                   with_archive(context, &never_called/1)
        end)

      assert File.ls!(context.root) == []
      assert log =~ "signed audit export failed: :zip_failed"
      refute log =~ context.root
    end

    test "is removed when the caller's function raises", context do
      assert_raise RuntimeError, "the client went away", fn ->
        with_archive(context, fn archive ->
          assert File.regular?(archive.zip_path)
          raise "the client went away"
        end)
      end

      assert File.ls!(context.root) == []
    end

    test "an exception during the build is logged by name only and leaves nothing", context do
      # Not valid UTF-8, so encoding the manifest raises.
      organization = %{id: context.organization.id, name: <<255, 254>>}

      log =
        capture_log(fn ->
          assert {:error, :build_failed} =
                   with_archive(context, &never_called/1, organization: organization)
        end)

      assert File.ls!(context.root) == []
      assert log =~ "signed audit export failed: Jason.EncodeError"
      refute log =~ context.root
      refute log =~ "invalid byte"
    end

    test "an unusable temporary root fails the build", context do
      for root <- [Path.join(context.root, "missing"), write_regular_file(context.root)] do
        Application.put_env(:kanban, SignedExport, tmp_root: root)

        log =
          capture_log(fn ->
            assert {:error, :build_failed} =
                     with_archive(context, &never_called/1)
          end)

        assert log =~ "signed audit export failed: no temporary directory"
        refute log =~ context.root
      end

      assert File.ls!(context.root) == ["a-file"]
    end

    test "defaults to a directory of its own under the system temporary directory", context do
      Application.delete_env(:kanban, SignedExport)

      assert {:ok, dir} =
               with_archive(context, fn archive ->
                 Path.dirname(archive.zip_path)
               end)

      default = System.tmp_dir!() |> Path.join("stride-signed-exports") |> Path.expand()

      assert dir |> Path.dirname() |> Path.expand() == default

      refute File.exists?(dir)
    end

    test "is removed when the building process is killed during the download", context do
      insert_event!(context.organization, 1)
      test_pid = self()

      builder =
        spawn(fn ->
          with_archive(context, fn archive ->
            send(test_pid, {:downloading, archive.zip_path})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:downloading, zip_path}, 5_000
      assert File.regular?(zip_path)

      Process.exit(builder, :kill)

      assert emptied?(context.root)
    end
  end

  describe "signing" do
    test "off: returns :not_configured, calls nothing and creates no directory", context do
      Application.put_env(:kanban, Signing, [])

      refute SignedExport.available?()

      assert {:error, :not_configured} =
               with_archive(context, &never_called/1)

      assert File.ls!(context.root) == []
    end

    test "available?/0 follows the signing key" do
      assert SignedExport.available?()
      assert AuditLog.signed_export_available?()
    end

    test "a key that changes during the build fails it and leaves nothing", context do
      insert_event!(context.organization, 1)

      on_first_read(fn ->
        Application.put_env(:kanban, Signing, private_key: :crypto.strong_rand_bytes(32))
      end)

      log =
        capture_log(fn ->
          assert {:error, :build_failed} =
                   with_archive(context, &never_called/1)
        end)

      assert log =~ "signed audit export failed: :key_changed"
      assert File.ls!(context.root) == []
    end

    test "a key removed during the build returns :not_configured and leaves nothing", context do
      insert_event!(context.organization, 1)
      on_first_read(fn -> Application.put_env(:kanban, Signing, []) end)

      assert {:error, :not_configured} =
               with_archive(context, &never_called/1)

      assert File.ls!(context.root) == []
    end
  end

  describe "options" do
    test "an unknown, missing or invalid option raises before anything is built", context do
      assert_raise ArgumentError, fn -> with_archive(context, & &1, max_row: 1) end
      assert_raise ArgumentError, ~r/:format/, fn -> with_archive(context, & &1, format: :pdf) end

      assert_raise ArgumentError, ~r/:max_rows/, fn ->
        with_archive(context, & &1, max_rows: 0)
      end

      parsed = Filters.parse(%{})
      without_instance = context |> opts([]) |> Keyword.delete(:instance)

      assert_raise KeyError, fn -> SignedExport.with_archive(parsed, without_instance, & &1) end

      assert File.ls!(context.root) == []
    end

    test "the Kanban.AuditLog delegate builds the same archive", context do
      insert_event!(context.organization, 1)

      parsed = Filters.parse(%{})
      opts = opts(context, [])

      assert {:ok, built} = AuditLog.with_signed_export(parsed, opts, &read/1)

      assert built.file == unsigned(context.organization, :csv, 50)
      assert Signing.verify(built.manifest_bytes, built.signature, built.manifest["key_id"])
    end
  end

  defp write_regular_file(root) do
    path = Path.join(root, "a-file")
    File.write!(path, "not a directory")
    path
  end
end
