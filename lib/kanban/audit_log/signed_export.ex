defmodule Kanban.AuditLog.SignedExport do
  @moduledoc """
  Builds a signed export of an Organization's audit log: one zip holding the
  export file, a manifest describing it, an Ed25519 signature over the
  manifest and a README with the verification commands.

  `Kanban.AuditLog` delegates `with_signed_export/3` and
  `signed_export_available?/0` here, so callers keep using the context's
  public API.

  ## The archive

  | Entry | Contents |
  | --- | --- |
  | `audit_log.csv` or `audit_log.json` | The events, encoded by `Kanban.AuditLog.Export`'s encoders: byte for byte what an unsigned export of the same events holds |
  | `manifest.json` | What the export is: instance, Organization, who made it and when, the filters, the file's name, size and SHA-256, the row count, the newest and oldest event, `truncated`, the signing key's id and `snapshot_at`, the boundary of the snapshot the events were read from |
  | `manifest.json.sig` | The raw 64-byte Ed25519 signature over the exact bytes of `manifest.json` (`Kanban.AuditLog.Signing.sign/1`) |
  | `README.txt` | The three verification commands (`Kanban.AuditLog.SignedExport.Readme`) |

  ## One read

  Erlang's `:zip` cannot write to a streaming response, so the file is written
  to a temporary directory first. The events are read once, through
  `Kanban.AuditLog.Export.batches/2`. The SHA-256, the byte count, the row
  count and the newest and oldest rows are taken while the file is written.

  The read asks for one row more than the cap. `truncated` is `true` only when
  that extra row arrives, and the extra row is never written. So `truncated`
  describes the file, not a count taken beforehand.

  An event recorded with the current time after the read starts is newer than
  the first batch and is not in the file. That includes the export's own
  `org_audit_log_exported` event: it carries the file's SHA-256, so it can
  only be recorded after the file is built.

  Every batch is read inside one `REPEATABLE READ, READ ONLY` transaction
  (`Kanban.AuditLog.SignedExport.Snapshot`), so the file is one point in
  time. The transaction covers the read only and ends before the file is
  signed, zipped or handed to the caller's function, so the download never
  holds it. The manifest's last field, `snapshot_at`, is that point: every
  matching event committed before it is in the file, up to the row cap that
  `truncated` reports, and an event committed after it is not, even one
  whose `inserted_at` is earlier because it was written inside a transaction
  that was still open when the read began. The snapshot's moduledoc has the
  one instant of slack and the bounds.

  ## Scope

  The query is built here from the parsed filters and the `:organization`
  option: `organization_id` is forced to that Organization, actors outside it
  are redacted (`Kanban.AuditLog.OrganizationScope`), and the actor-email
  filter is never applied. The manifest names the same Organization and the
  same filters, so the signed manifest cannot disagree with the file's scope.

  ## The temporary directory

  The directory is owner-only with an unpredictable name
  (`Kanban.AuditLog.SignedExport.Scratch`). It briefly holds audit data, so it
  is removed on every path. `with_archive/3` removes it when the build fails,
  when the caller's function returns and when that function raises. A client
  that cancels the download is the returning case: the caller treats it as a
  normal end, so its function returns and the directory goes. A guard process
  removes it when the building process is killed instead. A killed VM runs
  neither, so a sweep at boot and every 15 minutes removes what such a VM left
  once it is an hour old. A removal the operating system refuses is logged.

  It is created in `System.tmp_dir/0`'s `stride-signed-exports`.
  `config :kanban, Kanban.AuditLog.SignedExport, tmp_root: path` names
  another root, which must hold nothing else.

  A failure is logged by its error name only, never with a path or an
  exception message.
  """

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export
  alias Kanban.AuditLog.Filters
  alias Kanban.AuditLog.SignedExport.Readme
  alias Kanban.AuditLog.SignedExport.Scratch
  alias Kanban.AuditLog.SignedExport.Snapshot
  alias Kanban.AuditLog.Signing

  require Logger

  @schema "stride.audit-export.v1"
  @manifest_name "manifest.json"
  @signature_name "manifest.json.sig"
  @readme_name "README.txt"
  @zip_name "export.zip"

  @typedoc "What `with_archive/3` hands to the caller's function."
  @type archive :: %{
          zip_path: String.t(),
          format: :csv | :json,
          sha256: String.t(),
          key_id: Signing.key_id(),
          truncated: boolean(),
          rows: non_neg_integer(),
          bytes: non_neg_integer()
        }

  @doc """
  Whether this instance can sign an export, that is, whether it has a signing
  key (`Kanban.AuditLog.Signing.enabled?/0`).
  """
  @spec available?() :: boolean()
  def available?, do: Signing.enabled?()

  @doc """
  Builds the signed archive for the events matching `parsed`
  (`Kanban.AuditLog.Filters.parse/1`), calls `fun` with it, removes the
  temporary directory and returns `{:ok, result_of_fun}`.

  The zip at `archive.zip_path` exists only while `fun` runs.

  `opts` (all but `:batch_size` are required; any other key raises
  `ArgumentError`):

    * `:format` — `:csv` or `:json`.
    * `:organization` — `%{id: integer, name: string}`. The export holds this
      Organization's events only.
    * `:generated_by` — `%{user_id: integer, email: string}`, the org-admin.
    * `:instance` — this instance's host name, for the manifest.
    * `:keys_url` — the absolute URL of the published signing keys, for the
      README's first command.
    * `:max_rows` — the row cap, a positive integer.
    * `:batch_size` — rows read per round trip.

  Returns `{:error, :not_configured}` when signing is off, and
  `{:error, :build_failed}` when the archive could not be built. In both
  cases `fun` is not called and the temporary directory is removed.
  """
  @spec with_archive(Filters.t(), keyword(), (archive() -> result)) ::
          {:ok, result} | {:error, :not_configured | :build_failed}
        when result: var
  def with_archive(%{filters: _filters, params: _params} = parsed, opts, fun)
      when is_function(fun, 1) do
    request = request(parsed, opts)

    with {:ok, key_id} <- current_key_id(),
         {:ok, scratch} <- checkout() do
      in_dir(scratch, Map.put(request, :key_id, key_id), fun)
    end
  end

  defp request(parsed, opts) do
    opts =
      Keyword.validate!(opts, [
        :format,
        :organization,
        :generated_by,
        :instance,
        :keys_url,
        :max_rows,
        :batch_size
      ])

    %{id: organization_id, name: _name} = organization = Keyword.fetch!(opts, :organization)

    %{
      format: checked_format(Keyword.fetch!(opts, :format)),
      organization: organization,
      generated_by: Keyword.fetch!(opts, :generated_by),
      instance: Keyword.fetch!(opts, :instance),
      keys_url: Keyword.fetch!(opts, :keys_url),
      max_rows: checked_max_rows(Keyword.fetch!(opts, :max_rows)),
      read_opts: read_opts(opts, organization_id),
      query: query_filters(parsed, organization_id),
      filters: manifest_filters(parsed)
    }
  end

  defp checked_format(format) when format in [:csv, :json], do: format

  defp checked_format(other),
    do: raise(ArgumentError, "expected :format to be :csv or :json, got: #{inspect(other)}")

  defp checked_max_rows(rows) when is_integer(rows) and rows > 0, do: rows

  defp checked_max_rows(other),
    do:
      raise(ArgumentError, "expected :max_rows to be a positive integer, got: #{inspect(other)}")

  defp read_opts(opts, organization_id) do
    opts
    |> Keyword.take([:batch_size])
    |> Keyword.put(:redact_actors_outside, organization_id)
  end

  # Only the filters an org-admin export honours, and never :actor_email: it
  # matches before outside actors are redacted, so it would confirm a guessed
  # email of a site admin. organization_id is forced last, so nothing in
  # `parsed` can widen the export.
  defp query_filters(parsed, organization_id) do
    parsed.filters
    |> Keyword.take([:action, :since, :until])
    |> Keyword.put(:organization_id, organization_id)
  end

  # Always the same three keys: a filter the request did not set is null.
  defp manifest_filters(parsed) do
    summary = Filters.summary(parsed)
    Enum.map(~w(action from to), &{&1, Map.get(summary, &1)})
  end

  defp current_key_id do
    case Signing.current_key() do
      %{key_id: key_id} -> {:ok, key_id}
      nil -> {:error, :not_configured}
    end
  end

  # The reason is not logged: it can only be a posix name, but the path it
  # belongs to must not be guessable from the log either.
  defp checkout do
    with {:error, _reason} <- Scratch.checkout() do
      Logger.warning("signed audit export failed: no temporary directory")
      {:error, :build_failed}
    end
  end

  # The directory goes away however this ends: a failed build, a returned
  # `fun` and a raising `fun` alike. Scratch's guard covers a killed process.
  defp in_dir(scratch, request, fun) do
    with {:ok, archive} <- build(scratch.path, request) do
      {:ok, fun.(archive)}
    end
  after
    Scratch.release(scratch)
  end

  defp build(dir, request) do
    file = write_events(dir, request)
    write_file!(dir, @readme_name, Readme.text(request))

    manifest = manifest_bytes(request, file)
    write_file!(dir, @manifest_name, manifest)
    write_file!(dir, @signature_name, sign!(manifest, request.key_id))

    {:ok, archive(zip!(dir, request.format), request, file)}
  rescue
    error ->
      Logger.warning("signed audit export failed: #{inspect(error.__struct__)}")
      {:error, :build_failed}
  catch
    {:signed_export, :not_configured} ->
      {:error, :not_configured}

    {:signed_export, reason} ->
      Logger.warning("signed audit export failed: #{inspect(reason)}")
      {:error, :build_failed}

    # An exit, such as the Slots server going down while a build waits for
    # a slot, fails the build like any other failure rather than escaping
    # the {:error, :build_failed} contract. Only the kind is logged.
    :exit, _reason ->
      Logger.warning("signed audit export failed: exit")
      {:error, :build_failed}
  end

  defp archive(zip_path, request, file) do
    %{
      zip_path: zip_path,
      format: request.format,
      sha256: file.sha256,
      key_id: request.key_id,
      truncated: file.truncated,
      rows: file.rows,
      bytes: file.bytes
    }
  end

  ## The export file

  # The path is the temporary directory plus a fixed name.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_events(dir, request) do
    path = Path.join(dir, file_name(request.format))

    # No :delayed_write: a full disk then fails the write itself. The snapshot
    # covers the read only: it has ended before the file is signed or zipped.
    case File.open(path, [:write, :binary], &read_snapshot(&1, request)) do
      {:ok, {snapshot_at, state}} -> state |> finish() |> Map.put(:snapshot_at, snapshot_at)
      {:error, reason} -> throw({:signed_export, reason})
    end
  end

  defp read_snapshot(io, request), do: Snapshot.read(fn -> write_rows(io, request) end)

  defp write_rows(io, request) do
    start = %{
      io: io,
      hash: :crypto.hash_init(:sha256),
      bytes: 0,
      rows: 0,
      newest: nil,
      oldest: nil,
      truncated: false
    }

    request.query
    |> Export.batches([{:max_rows, request.max_rows + 1} | request.read_opts])
    |> Enum.reduce_while(emit(start, opening(request.format)), &take_batch(&1, &2, request))
    |> emit(closing(request.format))
  end

  # Writes what the cap still allows. A row beyond it is the proof that the
  # file is cut; it is dropped here and never written.
  defp take_batch(batch, state, %{format: format, max_rows: max_rows}) do
    {kept, extra} = Enum.split(batch, max_rows - state.rows)

    state =
      state
      |> emit(encode_rows(format, kept, state.rows == 0))
      |> track(kept)

    if extra == [], do: {:cont, state}, else: {:halt, %{state | truncated: true}}
  end

  defp opening(:csv), do: Export.csv_header()
  defp opening(:json), do: "["

  defp closing(:csv), do: []
  defp closing(:json), do: "]"

  defp encode_rows(:csv, events, _first?), do: Export.csv_rows(events)
  defp encode_rows(:json, events, first?), do: Export.json_rows(events, first?)

  defp emit(state, chunk) do
    write!(state.io, chunk)

    %{
      state
      | hash: :crypto.hash_update(state.hash, chunk),
        bytes: state.bytes + IO.iodata_length(chunk)
    }
  end

  defp track(state, []), do: state

  # Newest first: the first row ever written is the newest, the last row of
  # the latest batch the oldest so far.
  defp track(state, events) do
    %{
      state
      | rows: state.rows + length(events),
        newest: state.newest || hd(events),
        oldest: List.last(events)
    }
  end

  defp finish(state) do
    sha256 =
      state.hash
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    state
    |> Map.take([:bytes, :rows, :newest, :oldest, :truncated])
    |> Map.put(:sha256, sha256)
  end

  defp file_name(format), do: Readme.file_name(format)

  ## The manifest

  # Jason.OrderedObject keeps the documented key order in the bytes that are
  # signed. Those exact bytes are what is written to manifest.json.
  defp manifest_bytes(request, file) do
    request
    |> manifest_fields(file)
    |> Jason.OrderedObject.new()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp manifest_fields(request, file) do
    [
      {"schema", @schema},
      {"instance", request.instance},
      {"organization", organization_object(request.organization)},
      {"generated_at", generated_at()},
      {"generated_by", generated_by_object(request.generated_by)},
      {"filters", Jason.OrderedObject.new(request.filters)},
      {"file", file_object(request.format, file)},
      {"rows", file.rows},
      {"oldest_event", event_object(file.oldest)},
      {"newest_event", event_object(file.newest)},
      {"truncated", file.truncated},
      {"key_id", request.key_id},
      {"snapshot_at", file.snapshot_at}
    ]
  end

  defp organization_object(%{id: id, name: name}),
    do: Jason.OrderedObject.new([{"id", id}, {"name", name}])

  defp generated_by_object(%{user_id: user_id, email: email}),
    do: Jason.OrderedObject.new([{"user_id", user_id}, {"email", email}])

  defp file_object(format, file) do
    Jason.OrderedObject.new([
      {"name", file_name(format)},
      {"format", Atom.to_string(format)},
      {"bytes", file.bytes},
      {"sha256", file.sha256}
    ])
  end

  defp event_object(nil), do: nil

  # The id and inserted_at exactly as the file's own row shows them.
  defp event_object(%AuditEvent{} = event) do
    row = Export.row_map(event)
    Jason.OrderedObject.new([{"id", row["id"]}, {"inserted_at", row["inserted_at"]}])
  end

  defp generated_at do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  # The manifest names the key that was current when the build began. If the
  # key changed in between, the signature would not match that name.
  defp sign!(manifest, key_id) do
    case Signing.sign(manifest) do
      {:ok, %{signature: signature, key_id: ^key_id}} -> signature
      {:ok, _signed_by_another_key} -> throw({:signed_export, :key_changed})
      {:error, :not_configured} -> throw({:signed_export, :not_configured})
    end
  end

  ## Files

  # Every path is the temporary directory plus a fixed name.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_file!(dir, name, data) do
    case dir |> Path.join(name) |> File.write(data) do
      :ok -> :ok
      {:error, reason} -> throw({:signed_export, reason})
    end
  end

  defp write!(io, data) do
    case :file.write(io, data) do
      :ok -> :ok
      {:error, reason} -> throw({:signed_export, reason})
    end
  end

  # Files only, by their fixed names, so the zip holds exactly four entries.
  defp zip!(dir, format) do
    zip_path = Path.join(dir, @zip_name)

    names =
      Enum.map(
        [file_name(format), @manifest_name, @signature_name, @readme_name],
        &String.to_charlist/1
      )

    zip_name = String.to_charlist(zip_path)
    cwd = String.to_charlist(dir)

    case :zip.create(zip_name, names, cwd: cwd) do
      {:ok, _name} -> zip_path
      {:error, _reason} -> throw({:signed_export, :zip_failed})
    end
  end
end
