defmodule Kanban.Push.LogRedaction do
  @moduledoc """
  Keeps the push credentials out of the log.

  Pigeon and Goth hold the APNs `.p8` key and the FCM service account's
  private key in their child-spec arguments and process state, and OTP prints
  both in supervisor and crash reports when a dispatcher worker or the token
  server exits abnormally or fails to start. `install/0` adds a `:logger`
  primary filter that replaces every line of either private key's body with
  `#{inspect("[REDACTED push credential]")}` in each warning-or-worse event,
  whether the event is still a report term or has already been translated to
  a string.

  It installs nothing when no push credentials are configured, which is
  always the case in dev and test. See docs/push-notifications.md.
  """

  alias Kanban.Push.APNs
  alias Kanban.Push.FCM

  @filter_id :kanban_push_credentials
  @redacted "[REDACTED push credential]"
  @levels [:warning, :error, :critical, :alert, :emergency]

  # A key-body line shorter than this is not distinctive enough to redact on
  # its own; base64 PEM lines are 64 characters, the last one usually shorter.
  @min_fragment 16

  @doc """
  Adds the filter for the configured push keys. Returns `:ok`, also when no
  key is configured (nothing is added) or the filter is already installed.
  """
  @spec install() :: :ok
  def install, do: install(@filter_id, configured_fragments())

  @doc false
  @spec install(atom(), [String.t()]) :: :ok
  def install(_filter_id, []), do: :ok

  def install(filter_id, fragments) do
    case :logger.add_primary_filter(filter_id, {&__MODULE__.filter/2, fragments}) do
      :ok -> :ok
      {:error, {:already_exist, _id}} -> :ok
    end
  end

  @doc "The redactable fragments of every configured push private key."
  @spec configured_fragments() :: [String.t()]
  def configured_fragments do
    apns_key =
      case APNs.config() do
        {:ok, config} -> config[:key]
        {:error, :not_configured} -> nil
      end

    fcm_key =
      case FCM.config() do
        {:ok, config} -> get_in(config, [:service_account, "private_key"])
        {:error, :not_configured} -> nil
      end

    [apns_key, fcm_key] |> Enum.flat_map(&fragments/1) |> Enum.uniq()
  end

  @doc """
  The body lines of a PEM private key: the base64 lines between its
  `-----BEGIN` and `-----END` lines, each at least #{@min_fragment} characters.
  """
  @spec fragments(term()) :: [String.t()]
  def fragments(pem) when is_binary(pem) do
    pem
    |> String.replace("\\n", "\n")
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.starts_with?(&1, "-----") or byte_size(&1) < @min_fragment))
  end

  def fragments(_not_a_key), do: []

  @doc """
  The `:logger` filter: returns the event with every fragment redacted when
  its level is warning or worse, and unchanged otherwise.
  """
  @spec filter(:logger.log_event(), [String.t()]) :: :logger.log_event()
  def filter(%{level: level, msg: msg, meta: meta} = event, fragments) when level in @levels do
    %{event | msg: redact_msg(msg, fragments), meta: redact(meta, fragments)}
  end

  def filter(event, _fragments), do: event

  defp redact_msg({:string, chardata}, fragments) do
    {:string, chardata |> to_binary() |> redact(fragments)}
  end

  defp redact_msg({:report, report}, fragments), do: {:report, redact(report, fragments)}

  defp redact_msg({format, args}, fragments) when is_list(args),
    do: {redact(format, fragments), redact(args, fragments)}

  defp redact_msg(other, fragments), do: redact(other, fragments)

  defp to_binary(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    ArgumentError -> inspect(chardata)
  end

  @doc false
  @spec redact(term(), [String.t()]) :: term()
  def redact(binary, fragments) when is_binary(binary) do
    if String.contains?(binary, fragments),
      do: String.replace(binary, fragments, @redacted),
      else: binary
  end

  def redact(list, fragments) when is_list(list), do: redact_list(list, fragments)

  def redact(tuple, fragments) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> redact_list(fragments) |> List.to_tuple()
  end

  # :maps.map/2 keeps a struct a struct; Map.new/2 would need it enumerable.
  def redact(map, fragments) when is_map(map) do
    :maps.map(fn _key, value -> redact(value, fragments) end, map)
  end

  def redact(other, _fragments), do: other

  # Walks proper and improper lists alike. A charlist (a printable list of
  # integers, as Erlang formatting produces) is turned into a string first,
  # since a fragment inside one is invisible element by element.
  defp redact_list(list, fragments) do
    if List.ascii_printable?(list, :infinity) and list != [] do
      list |> List.to_string() |> redact(fragments) |> String.to_charlist()
    else
      walk(list, fragments)
    end
  end

  defp walk([head | tail], fragments), do: [redact(head, fragments) | walk(tail, fragments)]
  defp walk([], _fragments), do: []
  defp walk(improper_tail, fragments), do: redact(improper_tail, fragments)
end
