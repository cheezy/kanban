defmodule Kanban.AuditLog.Signing.DevKey do
  @moduledoc """
  The development key file behind the `:dev_file` fallback of
  `Kanban.AuditLog.Signing`.

  Only `Kanban.AuditLog.Signing` calls this module; no controller, LiveView
  or other module does. Signing calls it the first time it needs the
  development key, which is often while serving a request, after expanding
  `:dev_key_path`, and caches the seed returned here under
  `{Kanban.AuditLog.Signing, {:dev_file, path}}`. This module keeps no cache
  and never calls Signing. Its two functions return the private seed, so they
  are not part of any API, and nothing here logs or inspects the seed: the
  warning below names only the path and the file mode.

  ## The development key file

  The file is a PKCS#8 PEM, the same bytes `openssl genpkey -algorithm
  ed25519` writes. It is written inside a new owner-only directory beside
  its final path, given mode 0600, and only then hard-linked into place.
  A link never replaces an existing file and never follows a symlink, and a
  second process that starts at the same moment finds the file complete and
  reads the first one's key.

  A file that is there but is a symlink, can't be read or isn't an Ed25519
  key raises, naming the path. It is never replaced: a silently regenerated
  key would break every signature made with the old one. Blank lines around
  the PEM are accepted; any other text around it is not.

  A key file that group or other users can read or write is set back to
  0600 and a warning is logged, because another user may have copied the
  key. A first use that is killed part-way can leave its staging directory
  behind (`<path>.tmp-…`); the next load removes any that are more than
  five minutes old.
  """

  require Logger

  @private_der_prefix Base.decode16!("302E020100300506032B657004220420")

  # How old a leftover staging directory must be before it is removed.
  @stale_staging_seconds 300

  # Every private function below that takes the seed has one clause with no
  # pattern or guard on it, so a failed match can never carry the seed into
  # an exception.

  @doc false
  # The seed of the key file at `path`, an expanded path: read when the
  # file is there, created when nothing is. Signing calls it inside its
  # cache, once per path.
  @spec dev_key_seed(Path.t()) :: <<_::256>>
  def dev_key_seed(path) do
    seed =
      case File.lstat(path) do
        {:error, :enoent} -> create_dev_key_seed(path)
        stat -> read_dev_key(path, stat)
      end

    remove_stale_staging(path)
    seed
  end

  # The File calls below take the development key path from the application
  # config (config/dev.exs), never from a request, so Sobelow's traversal
  # check does not apply to them.

  # lstat, not stat: a symlink planted at the path is refused, not followed.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_dev_key(path, {:ok, %File.Stat{type: :regular, mode: mode}}) do
    with {:ok, pem} <- File.read(path),
         {:ok, seed} <- decode_private_pem(pem) do
      close_to_other_users(path, mode)
      seed
    else
      {:error, reason} -> dev_key_error!(path, "cannot be read (#{reason})")
      :error -> dev_key_error!(path, "is not an Ed25519 private key in PKCS#8 PEM form")
    end
  end

  defp read_dev_key(path, {:ok, %File.Stat{}}) do
    dev_key_error!(path, "is not a regular file")
  end

  defp read_dev_key(path, {:error, reason}) do
    no_dev_key_error!(path, "cannot be reached (#{reason})")
  end

  # A key file that group or other users can read or write is set back to
  # 0600, and the log says so: the key may already have been copied.
  # sobelow_skip ["Traversal.FileModule"]
  defp close_to_other_users(path, mode) do
    if Bitwise.band(mode, 0o077) != 0 do
      outcome =
        case File.chmod(path, 0o600) do
          :ok -> "Stride set it to 600"
          {:error, reason} -> "Stride could not set it to 600 (#{reason})"
        end

      Logger.warning(
        "The audit signing development key file #{path} could be read or written by " <>
          "other users of this machine (mode #{Integer.to_string(Bitwise.band(mode, 0o777), 8)}). " <>
          "#{outcome}. Another user may have copied the key."
      )
    end

    :ok
  end

  @doc false
  # The create half, without first looking for the file: every caller
  # stages its own key and tries to link it into place, and exactly one
  # link succeeds. A caller whose link fails reads the winner's key.
  @spec create_dev_key_seed(Path.t()) :: <<_::256>>
  def create_dev_key_seed(path) do
    seed = :crypto.strong_rand_bytes(32)

    case link_new_key(path, private_pem(seed)) do
      :ok -> seed
      {:error, :eexist} -> read_dev_key(path, File.lstat(path))
      {:error, reason} -> no_dev_key_error!(path, "cannot be created (#{reason})")
    end
  end

  # Stages the PEM beside `path` and hard-links it into place. A link fails
  # with :eexist on anything already at `path`, a symlink included, and the
  # linked file is complete from the moment it appears.
  # sobelow_skip ["Traversal.FileModule"]
  defp link_new_key(path, pem) do
    staging = path <> ".tmp-" <> random_suffix()
    staged = Path.join(staging, "key")

    linked =
      with :ok <- path |> Path.dirname() |> File.mkdir_p(),
           :ok <- stage(staging, staged, pem) do
        File.ln(staged, path)
      end

    _ = File.rm(staged)
    _ = File.rmdir(staging)
    linked
  end

  defp random_suffix do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # File.mkdir/1 fails on an existing path and never follows a symlink, and
  # the directory is owner-only before the key is written into it, so no
  # other OS user can open the file between its creation and its chmod.
  # sobelow_skip ["Traversal.FileModule"]
  defp stage(staging, staged, pem) do
    with :ok <- File.mkdir(staging),
         :ok <- File.chmod(staging, 0o700),
         :ok <- File.write(staged, pem, [:exclusive, :sync]) do
      File.chmod(staged, 0o600)
    end
  end

  # A first use that is killed part-way leaves its staging directory behind,
  # sometimes with a key in it, and nothing else removes one. Each load
  # removes those older than five minutes: no creation in progress is that
  # old. Only a real directory is touched, never a symlink.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_stale_staging(path) do
    directory = Path.dirname(path)
    prefix = Path.basename(path) <> ".tmp-"
    oldest_kept = System.os_time(:second) - @stale_staging_seconds

    names =
      case File.ls(directory) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end

    for name <- names, String.starts_with?(name, prefix) do
      remove_staging(Path.join(directory, name), oldest_kept)
    end

    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_staging(staging, oldest_kept) do
    case File.lstat(staging, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} when mtime < oldest_kept ->
        _ = staging |> Path.join("key") |> File.rm()
        _ = File.rmdir(staging)
        :ok

      _other ->
        :ok
    end
  end

  # For a path with no key file Stride could find or make.
  defp no_dev_key_error!(path, problem) do
    raise "The audit signing development key file #{path} #{problem}. Stride did not " <>
            "create a key there. Check that its directory exists and that Stride can " <>
            "read and write it, or set AUDIT_SIGNING_KEY."
  end

  # For a file that is there and cannot be used.
  defp dev_key_error!(path, problem) do
    raise "The audit signing development key file #{path} #{problem}. Stride did not " <>
            "replace it, because a new key would break every signature made with the old " <>
            "one. Fix or delete the file, or set AUDIT_SIGNING_KEY."
  end

  # Only an Ed25519 PKCS#8 private key: its DER is a fixed 16-byte header and
  # the 32-byte seed. An RSA or P-256 key has another header and is refused.
  defp decode_private_pem(pem) do
    with [_pem, body] <-
           Regex.run(~r/\A\s*-----BEGIN PRIVATE KEY-----(.+)-----END PRIVATE KEY-----\s*\z/s, pem),
         {:ok, <<@private_der_prefix::binary, seed::binary-size(32)>>} <-
           Base.decode64(body, ignore: :whitespace, padding: false) do
      {:ok, seed}
    else
      _other -> :error
    end
  end

  defp private_pem(seed), do: pem("PRIVATE KEY", @private_der_prefix <> seed)

  # The same PEM framing Signing gives the public key; this module does not
  # call Signing, so it keeps its own copy.
  defp pem(label, der) do
    "-----BEGIN #{label}-----\n#{Base.encode64(der)}\n-----END #{label}-----\n"
  end
end
