defmodule Kanban.AuditLog.Signing do
  @moduledoc """
  The instance's Ed25519 audit signing key (W2696).

  One key per Stride instance signs both the manifest of a signed audit
  export and the `X-Stride-Audit-Signature` header on streamed HTTPS batches,
  so an auditor and a receiver check against the same published key. Ed25519
  comes from Erlang's `:crypto`, so no dependency is involved.

  ## Configuration

  `config/runtime.exs` parses three environment variables into
  `config :kanban, Kanban.AuditLog.Signing`, as raw bytes:

    * `AUDIT_SIGNING_KEY` becomes `:private_key`, the 32-byte seed;
    * `AUDIT_SIGNING_KEYS_PREVIOUS` becomes `:previous`, a list of 32-byte
      public keys that are retired but still published;
    * `AUDIT_SIGNING_KEYS_REVOKED` becomes `:revoked`, a list of
      `{public_key, date | nil}` for keys that leaked and are no longer
      published. A bare public key counts as one with no date, and a key
      listed twice keeps its earliest date.

  The config is read on every call, never at compile time, so a test can
  turn signing off with `Application.put_env/3`. It must be a keyword list.

  The private key must not also appear in `:previous` or `:revoked`: those
  lists hold public keys, so the same 32 bytes there mean a public key was
  set as the private key, or the private key was pasted into a published
  list. `config/runtime.exs` refuses to boot on it and every function here
  raises. A private key listed there with no `AUDIT_SIGNING_KEY` equal to it
  cannot be told from a public key and is not detected.

  When no private key is configured, `:fallback` decides what happens:

    * `:none` (the default, and so production): signing is off. `enabled?/0`
      is false and `sign/1` returns `{:error, :not_configured}`;
    * `:dev_file` (development): a key is generated once and kept in the PEM
      file named by `:dev_key_path`, so signatures still verify after a
      restart;
    * `:ephemeral` (tests): one key is generated per run.

  Both fallback keys are cached in `:persistent_term`, so the first use pays
  for the file or the random bytes and later uses do not.

  ## The development key file

  `Kanban.AuditLog.Signing.DevKey` reads, creates and checks the PEM file
  behind the `:dev_file` fallback, and its moduledoc describes the file.
  This module expands `:dev_key_path` and caches the seed DevKey returns.

  ## Key id and fingerprint

  Both are computed over the 32 raw public-key bytes (the JWK `x` value
  after base64url decoding). The fingerprint is their SHA-256 as 64 lowercase
  hex characters, and the key id is `k1-` followed by the first 16 of them.

  ## Revoked keys

  A revoked key never signs, never verifies and is never published.
  `config/runtime.exs` refuses to boot with a current or previous key that
  is also revoked. As a second line of defence this module treats a current
  key found in the revoked list as not configured, whatever its source, and
  leaves a revoked key out of the previous keys.

  ## The private seed

  No public function of this module returns the seed, and nothing here logs
  or inspects it. `Kanban.AuditLog.Signing.DevKey` returns the development
  seed, and only this module calls it. The production seed lives only in the
  environment and the application config; only the development key is ever
  written to disk.
  """

  alias Kanban.AuditLog.Signing.DevKey

  @public_der_prefix Base.decode16!("302A300506032B6570032100")

  @typedoc "The 32 raw bytes of an Ed25519 public key."
  @type public_key :: <<_::256>>

  @typedoc "`k1-` followed by 16 lowercase hex characters."
  @type key_id :: String.t()

  @typedoc "A published key: public material only, never the seed."
  @type key :: %{key_id: key_id(), fingerprint: String.t(), public_key: public_key()}

  @typedoc "A revoked key's id and the date it was revoked, when known."
  @type revoked_key :: %{key_id: key_id(), revoked_on: Date.t() | nil}

  @typedoc "What `published_keys/0` returns."
  @type published :: %{current: key() | nil, previous: [key()], revoked: [revoked_key()]}

  @doc """
  Whether this instance has a usable signing key.

  With the `:dev_file` fallback this creates the key file on first use, and
  raises if a file is there that can't be used, exactly as `sign/1` would.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: signing_key(config()) != nil

  @doc """
  Signs `message`, any iodata, with the current key.

  Returns the raw 64-byte Ed25519 signature and the id of the key that made
  it, or `{:error, :not_configured}` when signing is off.
  """
  @spec sign(iodata()) ::
          {:ok, %{signature: <<_::512>>, key_id: key_id()}} | {:error, :not_configured}
  def sign(message) do
    bytes = IO.iodata_to_binary(message)

    case signing_key(config()) do
      {seed, public_key} ->
        signature = guard_seed(fn -> :crypto.sign(:eddsa, :none, bytes, [seed, :ed25519]) end)
        {:ok, %{signature: signature, key_id: key_id(public_key)}}

      nil ->
        {:error, :not_configured}
    end
  end

  @doc """
  Whether `signature` is the Ed25519 signature over `message`, any iodata,
  made by the published key with id `key_id`.

  `signature` is the raw 64 bytes. The key is looked up with
  `find_published/1`, so a signature made by a revoked or unknown key never
  verifies. Anything that isn't a 64-byte signature and a key id is false.
  """
  @spec verify(iodata(), binary(), key_id()) :: boolean()
  def verify(message, signature, key_id)
      when is_binary(signature) and byte_size(signature) == 64 do
    case find_published(key_id) do
      {:ok, %{public_key: public_key}} ->
        bytes = IO.iodata_to_binary(message)
        :crypto.verify(:eddsa, :none, bytes, signature, [public_key, :ed25519])

      {:error, :not_found} ->
        false
    end
  end

  def verify(_message, _signature, _key_id), do: false

  @doc """
  The current key's id, fingerprint and public key, or nil when signing is
  off. Never the private seed.
  """
  @spec current_key() :: key() | nil
  def current_key, do: current_key(config())

  @doc """
  Every key an auditor or a receiver may need: the current key, the previous
  (retired) keys that still verify, and the id and revocation date of each
  revoked key.
  """
  @spec published_keys() :: published()
  def published_keys do
    config = config()
    current = current_key(config)
    revoked = revoked(config)
    hidden = [current && current.public_key | Enum.map(revoked, &elem(&1, 0))]

    %{
      current: current,
      previous: previous(config, hidden),
      revoked: Enum.map(revoked, &revoked_key/1)
    }
  end

  @doc """
  Finds a published key by its id: the current key or a previous one, never
  a revoked key. Anything else, including a term that isn't a string, is
  `{:error, :not_found}`.
  """
  @spec find_published(term()) :: {:ok, key()} | {:error, :not_found}
  def find_published(key_id) when is_binary(key_id) do
    %{current: current, previous: previous} = published_keys()

    case Enum.find([current | previous], &(&1 != nil and &1.key_id == key_id)) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  def find_published(_key_id), do: {:error, :not_found}

  @doc """
  The public key as a SubjectPublicKeyInfo PEM, which `openssl pkey -pubin`
  and `:public_key.pem_decode/1` read.
  """
  @spec public_key_pem(public_key()) :: String.t()
  def public_key_pem(<<_::binary-size(32)>> = public_key) do
    pem("PUBLIC KEY", @public_der_prefix <> public_key)
  end

  @doc """
  The key id of a public key: `k1-` and the first 16 hex characters of its
  fingerprint.
  """
  @spec key_id(public_key()) :: key_id()
  def key_id(<<_::binary-size(32)>> = public_key) do
    "k1-" <> binary_part(fingerprint(public_key), 0, 16)
  end

  @doc """
  The fingerprint of a public key: the SHA-256 of its 32 raw bytes, as 64
  lowercase hex characters.
  """
  @spec fingerprint(public_key()) :: String.t()
  def fingerprint(<<_::binary-size(32)>> = public_key) do
    :sha256 |> :crypto.hash(public_key) |> Base.encode16(case: :lower)
  end

  @doc false
  # The development key file's create half (`DevKey.create_dev_key_seed/1`),
  # without the cache and without first looking for the file. Public so the
  # tests can write a key file and read it back through config/runtime.exs;
  # the application reaches DevKey through the `:dev_file` fallback only.
  @spec create_dev_key(Path.t()) :: key()
  def create_dev_key(path) do
    path |> DevKey.create_dev_key_seed() |> public_key() |> key()
  end

  @doc false
  # Runs `fun`, a :crypto call that takes the seed. When the call raises, the
  # error is raised again from here as a fixed message, so the failed call's
  # stack frames, and any argument they carry, never travel with it. Public
  # so the tests can make a :crypto call fail inside it.
  @spec guard_seed((-> result)) :: result when result: var
  def guard_seed(fun) do
    case attempt(fun) do
      {:ok, result} ->
        result

      :error ->
        raise "Kanban.AuditLog.Signing could not use its Ed25519 key: the :crypto call " <>
                "failed, so this Erlang or OpenSSL build may not support Ed25519. " <>
                "The key is not shown here."
    end
  end

  # The error is dropped here and raised by the caller, outside the rescue,
  # so the new error starts a new stack trace.
  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    _error -> :error
  end

  # Every private function below that takes the seed has one clause with no
  # pattern or guard on it, so a failed match can never carry the seed into
  # an exception.

  # Anything but a proper list is refused here: Keyword.get/3 on a map, or on
  # an improper list, would raise with the whole config, seed included, in its
  # stack frame.
  defp config do
    config = Application.get_env(:kanban, __MODULE__, [])

    if proper_list?(config) do
      config
    else
      raise ArgumentError,
            "config :kanban, Kanban.AuditLog.Signing must be a keyword list. " <>
              "Its value is not shown here."
    end
  end

  # :previous or :revoked, refused unless it is a proper list. On a binary, a
  # tuple or an improper list, `in`, `for` and :lists.member/2 raise with the
  # value, or the seed beside it, in the error or a stack frame; a map would
  # not raise but be silently misread.
  defp list_option(config, name) do
    list = Keyword.get(config, name, [])

    if proper_list?(list) do
      list
    else
      raise ArgumentError,
            "config :kanban, Kanban.AuditLog.Signing, #{inspect(name)} must be a list of " <>
              "public keys. Its value is not shown here."
    end
  end

  # List.improper?/1 has guard-only clauses, so it cannot raise.
  defp proper_list?(value), do: is_list(value) and not List.improper?(value)

  defp current_key(config) do
    case signing_key(config) do
      {_seed, public_key} -> key(public_key)
      nil -> nil
    end
  end

  # {seed, public key} for the key that signs, or nil when signing is off:
  # no key, or a key that has been revoked.
  defp signing_key(config) do
    seed = seed(config)

    if seed != nil and listed_as_public?(config, seed) do
      raise ArgumentError,
            "config :kanban, Kanban.AuditLog.Signing lists its private key in :previous " <>
              "or :revoked, which hold public keys. Signing is refused so that the " <>
              "private key is never published. The key is not shown here."
    end

    public_key = seed && public_key(seed)

    if public_key != nil and not revoked?(config, public_key), do: {seed, public_key}
  end

  # The same 32 bytes as a previous or revoked key: a public key pasted as the
  # private key, or the private key pasted into a list of public keys.
  defp listed_as_public?(config, seed) do
    seed in list_option(config, :previous) or revoked?(config, seed)
  end

  defp seed(config) do
    case Keyword.get(config, :private_key) do
      nil ->
        fallback_seed(Keyword.get(config, :fallback, :none), config)

      <<_::binary-size(32)>> = seed ->
        seed

      _other ->
        raise ArgumentError,
              "config :kanban, Kanban.AuditLog.Signing, :private_key must be a 32-byte " <>
                "Ed25519 seed or nil"
    end
  end

  defp fallback_seed(:ephemeral, _config) do
    cached(:ephemeral, fn -> :crypto.strong_rand_bytes(32) end)
  end

  defp fallback_seed(:dev_file, config) do
    case Keyword.get(config, :dev_key_path) do
      path when is_binary(path) ->
        path = Path.expand(path)
        cached({:dev_file, path}, fn -> DevKey.dev_key_seed(path) end)

      _missing ->
        raise ArgumentError,
              "config :kanban, Kanban.AuditLog.Signing needs :dev_key_path with fallback: :dev_file"
    end
  end

  defp fallback_seed(_none, _config), do: nil

  # One :persistent_term entry per key source. persistent_term has no
  # put-if-absent, so the first load runs under a node-local lock: two
  # processes that both miss the cache still end with one key.
  defp cached(source, load) do
    term = {__MODULE__, source}

    case :persistent_term.get(term, nil) do
      nil -> :global.trans({term, self()}, fn -> load_once(term, load) end, [node()])
      seed -> seed
    end
  end

  defp load_once(term, load) do
    case :persistent_term.get(term, nil) do
      nil ->
        seed = load.()
        :persistent_term.put(term, seed)
        seed

      seed ->
        seed
    end
  end

  defp pem(label, der) do
    "-----BEGIN #{label}-----\n#{Base.encode64(der)}\n-----END #{label}-----\n"
  end

  defp public_key(seed) do
    {public_key, _private_key} =
      guard_seed(fn -> :crypto.generate_key(:eddsa, :ed25519, seed) end)

    public_key
  end

  defp key(public_key) do
    %{
      key_id: key_id(public_key),
      fingerprint: fingerprint(public_key),
      public_key: public_key
    }
  end

  # {public key, date or nil} for each revoked key. An entry is a 32-byte key,
  # alone or in a tuple with its date; anything else is dropped. A key listed
  # twice keeps its first place and its earliest known date.
  defp revoked(config) do
    entries = revoked_entries(config)
    dates = earliest_dates(entries)

    for {public_key, _date} <- Enum.uniq_by(entries, &elem(&1, 0)),
        do: {public_key, Map.fetch!(dates, public_key)}
  end

  defp revoked_entries(config) do
    for entry <- list_option(config, :revoked),
        {<<_::binary-size(32)>>, _date} = revoked <- [revoked_entry(entry)],
        do: revoked
  end

  defp earliest_dates(entries) do
    Enum.reduce(entries, %{}, fn {public_key, date}, dates ->
      Map.update(dates, public_key, date, &earliest(&1, date))
    end)
  end

  defp revoked_entry({public_key, date}), do: {public_key, if(iso_date?(date), do: date)}
  defp revoked_entry(public_key), do: {public_key, nil}

  # A map tagged as a Date passes is_struct/2, and Date.compare/2 would then
  # raise with its contents: only a valid ISO date counts.
  defp iso_date?(%Date{calendar: Calendar.ISO, year: year, month: month, day: day})
       when is_integer(year) and is_integer(month) and is_integer(day),
       do: Calendar.ISO.valid_date?(year, month, day)

  defp iso_date?(_other), do: false

  defp earliest(nil, date), do: date
  defp earliest(date, nil), do: date
  defp earliest(first, second), do: Enum.min([first, second], Date)

  defp revoked?(config, public_key) do
    config |> revoked() |> Enum.any?(&(elem(&1, 0) == public_key))
  end

  defp revoked_key({public_key, date}) do
    %{key_id: key_id(public_key), revoked_on: date}
  end

  # The configured order, without duplicates, the current key or a revoked key.
  defp previous(config, hidden) do
    for <<_::binary-size(32)>> = public_key <- list_option(config, :previous),
        public_key not in hidden,
        uniq: true,
        do: key(public_key)
  end
end
