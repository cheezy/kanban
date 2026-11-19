defmodule Kanban.Devices.AppPolicy do
  @moduledoc """
  What the server tells the mobile apps about themselves: the minimum app
  version per platform, and the phone guard limits
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.2, §7.3).

  ## The version header

  Every app request carries `X-Stride-App: ios/1.0.0 (42)` or
  `android/1.0.0 (42)`. `parse_header/1` accepts exactly that shape: the
  platform, a `MAJOR.MINOR.PATCH` version and an optional build number in
  parentheses. The build number is ignored; only the version is compared.

  ## The minimum

  `min_versions/0` reads `config :kanban, :mobile_min_versions` at call time,
  never with `compile_env`, so a deployment raises the minimum with a restart
  rather than a rebuild (`config/runtime.exs` reads it from the environment).
  Each platform has a `min_version` and the `store_url` the app's update
  screen links to. A platform the config leaves out, or gives a version that
  does not parse, keeps the built-in default below.

  `check/1` refuses only a header that parses, for `ios` or `android`, with a
  version strictly below that platform's minimum. A missing header, one that
  does not parse and an unknown platform are all allowed: only the official
  apps send the header, a modified client can send anything, and refusing
  those would lock out curl, scripts and older tools while protecting
  nothing. The minimum exists to move old store builds onto a version the
  API still serves, not to authenticate the client.
  """

  alias Kanban.Reviews.MobileGuard

  @platforms [:ios, :android]

  @defaults %{
    ios: %{min_version: "1.0.0", store_url: "https://apps.apple.com/app/stride"},
    android: %{
      min_version: "1.0.0",
      store_url: "https://play.google.com/store/apps/details?id=com.stridelikeaboss.app"
    }
  }

  # A bounded header: no request can make the regex work on a long string.
  @max_header_bytes 64
  @header_format ~r/\A(ios|android)\/(\d{1,4}\.\d{1,4}\.\d{1,4})(?: \(\d{1,9}\))?\z/

  @type platform :: :ios | :android
  @type min_version :: %{min_version: String.t(), store_url: String.t()}

  @doc """
  The two platforms the apps run on.
  """
  @spec platforms() :: [platform()]
  def platforms, do: @platforms

  @doc """
  The minimum app version and store link for each platform, from
  `config :kanban, :mobile_min_versions` over the built-in defaults.

  A configured `min_version` that does not parse as `MAJOR.MINOR.PATCH`, or a
  `store_url` that is not a non-empty string, falls back to the default, so a
  mistyped value never locks every app out.
  """
  @spec min_versions() :: %{ios: min_version(), android: min_version()}
  def min_versions do
    configured = Application.get_env(:kanban, :mobile_min_versions, %{})
    Map.new(@platforms, &{&1, merge_platform(&1, configured)})
  end

  @doc """
  The phone guard limits: the largest change, in files and lines, the app
  lets a person approve on a phone (design §7.3). Server policy, so the app
  can never raise them. They are `Kanban.Reviews.MobileGuard`'s constants, so
  the limit the app shows is the limit the server enforces.
  """
  @spec phone_limits() :: %{phone_max_files: pos_integer(), phone_max_lines: pos_integer()}
  def phone_limits,
    do: %{
      phone_max_files: MobileGuard.max_files(),
      phone_max_lines: MobileGuard.max_changed_lines()
    }

  @doc """
  Parses an `X-Stride-App` header value into its platform and version.

  Returns `:error` for anything that is not exactly
  `<ios|android>/MAJOR.MINOR.PATCH` with an optional ` (<build>)`, including a
  value over #{@max_header_bytes} bytes and anything that is not a string. It
  never creates an atom.
  """
  @spec parse_header(term()) :: {:ok, platform(), Version.t()} | :error
  def parse_header(value) when is_binary(value) and byte_size(value) <= @max_header_bytes do
    with [platform, version] <- Regex.run(@header_format, value, capture: :all_but_first),
         {:ok, parsed} <- Version.parse(version) do
      {:ok, platform_atom(platform), parsed}
    else
      _ -> :error
    end
  end

  def parse_header(_value), do: :error

  @doc """
  Decides whether a request with these `X-Stride-App` header values may go on.

  Takes the list `Plug.Conn.get_req_header/2` returns. Returns
  `{:outdated, platform, store_url}` only when there is exactly one value, it
  parses, and its version is below the platform's minimum; `:ok` otherwise.
  """
  @spec check([String.t()]) :: :ok | {:outdated, platform(), String.t()}
  def check([value]) do
    case parse_header(value) do
      {:ok, platform, version} -> compare(platform, version)
      :error -> :ok
    end
  end

  def check(_values), do: :ok

  defp compare(platform, version) do
    %{min_version: min_version, store_url: store_url} = Map.fetch!(min_versions(), platform)

    case Version.compare(version, Version.parse!(min_version)) do
      :lt -> {:outdated, platform, store_url}
      _ -> :ok
    end
  end

  defp merge_platform(platform, configured) when is_map(configured) do
    default = Map.fetch!(@defaults, platform)

    case Map.get(configured, platform) do
      %{} = override ->
        %{
          min_version: valid_version(Map.get(override, :min_version), default.min_version),
          store_url: valid_url(Map.get(override, :store_url), default.store_url)
        }

      _ ->
        default
    end
  end

  defp merge_platform(platform, _configured), do: Map.fetch!(@defaults, platform)

  defp valid_version(value, default) when is_binary(value) do
    case Version.parse(value) do
      {:ok, %Version{pre: [], build: nil}} -> value
      _ -> default
    end
  end

  defp valid_version(_value, default), do: default

  defp valid_url(value, _default) when is_binary(value) and byte_size(value) > 0, do: value
  defp valid_url(_value, default), do: default

  defp platform_atom("ios"), do: :ios
  defp platform_atom("android"), do: :android
end
