defmodule KanbanWeb.API.Me.PageParams do
  @moduledoc """
  Reads the `page` query param of the person API's paged reads (the column
  read, W2759, and the goals list, W2762): an integer from 1 to 10,000, 1
  when it is not sent. Anything else is `{:error, {:bad_request, message}}`,
  rendered as `400` by `KanbanWeb.API.Me.FallbackController`.
  """

  @max_page 10_000

  @doc "The highest page a paged read accepts."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  @doc "Returns `{:ok, page}` or `{:error, {:bad_request, message}}`."
  @spec parse(map()) :: {:ok, pos_integer()} | {:error, {:bad_request, String.t()}}
  def parse(%{"page" => page}) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page >= 1 and page <= @max_page -> {:ok, page}
      _invalid -> bad_page()
    end
  end

  def parse(%{"page" => _page}), do: bad_page()
  def parse(_params), do: {:ok, 1}

  defp bad_page, do: {:error, {:bad_request, "page must be an integer from 1 to #{@max_page}."}}
end
