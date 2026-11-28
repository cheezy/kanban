defmodule KanbanWeb.Blog.Authors do
  @moduledoc """
  The people who write blog posts (W2950), keyed by the id a post names in
  its `author` front matter key.

  Every post must name an author listed here; `KanbanWeb.Blog` fails the
  build otherwise. Only public profile details belong here, never an email
  address.
  """

  @type link :: %{label: String.t(), url: String.t()}
  @type author :: %{
          id: String.t(),
          name: String.t(),
          bio: String.t(),
          avatar: String.t(),
          links: [link()]
        }

  @authors [
    %{
      id: "cheezy",
      name: "Jeff \"Cheezy\" Morgan",
      bio: "Software Developer, Continuous Delivery and AI Coach",
      avatar: "/images/blog/authors/cheezy.jpg",
      links: [
        %{label: "LinkedIn", url: "https://www.linkedin.com/in/jeffmorgan5/"},
        %{label: "GitHub", url: "https://github.com/cheezy"}
      ]
    }
  ]

  @by_id Map.new(@authors, &{&1.id, &1})

  @doc """
  Every author, in list order.
  """
  @spec all() :: [author()]
  def all, do: @authors

  @doc """
  Looks an author up by id. Any other value is `:error`.
  """
  @spec fetch(String.t()) :: {:ok, author()} | :error
  def fetch(id), do: Map.fetch(@by_id, id)
end
