defmodule Kanban.OpenSSL3 do
  @moduledoc """
  Finds an OpenSSL 3.0 or later command for the tests tagged `:openssl3`.

  Those tests run the verification command a signed audit export's README
  gives, which needs Ed25519 support in `openssl pkeyutl`. LibreSSL, the
  `openssl` that ships with macOS, does not have it, so it does not count.
  `test/test_helper.exs` excludes the tag where `executable/0` is `nil`.
  """

  @doc """
  The path of the `openssl` on the PATH when `openssl version` reports
  OpenSSL 3.0 or later, otherwise `nil`.
  """
  @spec executable() :: String.t() | nil
  def executable do
    with path when is_binary(path) <- System.find_executable("openssl"),
         {version, 0} <- System.cmd(path, ["version"], stderr_to_stdout: true),
         true <- openssl3?(version) do
      path
    else
      _missing_or_older -> nil
    end
  end

  @doc """
  Whether the output of `openssl version` names OpenSSL 3.0 or later.
  """
  @spec openssl3?(String.t()) :: boolean()
  def openssl3?(version) when is_binary(version) do
    case Regex.run(~r/\AOpenSSL (\d+)\./, version) do
      [_match, major] -> String.to_integer(major) >= 3
      nil -> false
    end
  end

  @doc """
  The ExUnit tags to exclude: `[:openssl3]` unless OpenSSL 3 is installed.
  """
  @spec exclusions() :: [atom()]
  def exclusions, do: if(executable(), do: [], else: [:openssl3])
end
