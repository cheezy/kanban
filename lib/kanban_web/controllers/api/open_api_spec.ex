defmodule KanbanWeb.API.OpenApiSpec do
  @moduledoc """
  Loads the hand-written OpenAPI 3.1 document served at `GET /api/openapi.json`
  (W2225).

  The document lives at `priv/openapi/stride-api.json` and is read at **runtime**
  through `Application.app_dir/2`, never at compile time from the repo root:
  a compile-time read bakes a build-machine path into the release, which does
  not exist in production.

  The raw bytes are cached in `:persistent_term` after the first successful
  read, so the file is read once per VM. A failed read is never cached — a
  deploy that restores the file recovers without a restart.

  The path is a fixed literal. Nothing about it is derived from request input.
  """

  @key {__MODULE__, :body}
  @relative_path "priv/openapi/stride-api.json"

  @doc "Absolute path of the spec inside the running application's priv dir."
  @spec path() :: Path.t()
  def path, do: Application.app_dir(:kanban, @relative_path)

  @doc """
  Returns the raw spec bytes, reading and caching them on first use.
  """
  @spec fetch() :: {:ok, binary()} | {:error, File.posix()}
  def fetch do
    case :persistent_term.get(@key, nil) do
      nil -> load_and_cache()
      body -> {:ok, body}
    end
  end

  defp load_and_cache do
    with {:ok, body} <- File.read(path()) do
      :persistent_term.put(@key, body)
      {:ok, body}
    end
  end
end
