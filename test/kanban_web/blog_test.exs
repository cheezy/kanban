defmodule KanbanWeb.BlogTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Blog
  alias KanbanWeb.Blog.Authors
  alias KanbanWeb.Blog.Loader

  @images_dir Path.expand("../../priv/static/images/blog", __DIR__)

  defp write_post(dir, name, lines, body \\ "Body.\n") do
    dir
    |> Path.join(name)
    |> File.write!("---\n" <> Enum.join(lines, "\n") <> "\n---\n\n" <> body)
  end

  defp front_matter(slug, date, extra \\ []) do
    [
      "date: '#{date}'",
      "title: 'Post #{slug}'",
      "author: cheezy",
      "slug: '#{slug}'",
      ~s(description: "About #{slug}.")
    ] ++ extra
  end

  describe "posts/0" do
    test "lists the two copied posts, newest first, with DateTime dates" do
      assert [first, second] = Blog.posts()

      assert first.slug == "tw-retreat-response"
      assert first.title == "The future of software engineering: My Thoughts - Part 1"
      assert first.date == ~U[2026-03-18 17:47:00Z]
      assert first.tags == ["AI", "Continuous Delivery"]
      assert first.author == "cheezy"

      assert second.slug == "how-much"
      assert second.title == "How Much Should I Spend?"
      assert second.date == ~U[2026-02-05 12:39:01Z]
      assert second.tags == ["AI", "Agile", "Continuous Delivery"]
      assert second.author == "cheezy"

      for post <- Blog.posts() do
        assert %DateTime{} = post.date
        assert String.length(post.description) in 150..160
        assert post.html =~ "<p>"
        refute Map.has_key?(post, :draft)
      end
    end

    test "renders how-much's two images with alt text from /images/blog/" do
      {:ok, post} = Blog.fetch("how-much")

      assert post.html =~
               ~s(<img loading="lazy" src="/images/blog/one-developer-cost.png" alt="Cost for one developer" />)

      assert post.html =~
               ~s(<img loading="lazy" src="/images/blog/one-developer-with-ai.png" alt="Cost increase for one developer with AI" />)

      assert @images_dir |> Path.join("one-developer-cost.png") |> File.regular?()
      assert @images_dir |> Path.join("one-developer-with-ai.png") |> File.regular?()
    end

    # Besides the post's own links, the only hrefs are the "#id" anchors the
    # renderer adds to each heading, and each must point at a heading id.
    test "contains only http(s) and mailto links and no raw HTML" do
      for post <- Blog.posts() do
        ids =
          for [id] <- Regex.scan(~r/<h\d id="([^"]*)"/, post.html, capture: :all_but_first),
              do: id

        for [href] <- Regex.scan(~r/href="([^"]*)"/, post.html, capture: :all_but_first) do
          case href do
            "#" <> id -> assert id in ids
            _ -> assert href =~ ~r/\A(https?|mailto):/
          end
        end

        refute post.html =~ "<script"
      end
    end
  end

  describe "fetch/1" do
    test "returns both copied posts by slug" do
      assert {:ok, %{slug: "tw-retreat-response"}} = Blog.fetch("tw-retreat-response")
      assert {:ok, %{slug: "how-much"}} = Blog.fetch("how-much")
    end

    test "returns :error for an unknown slug and for a path" do
      assert Blog.fetch("nope") == :error
      assert Blog.fetch("../x") == :error
      assert Blog.fetch("priv/blog/posts/how-much.md") == :error
    end
  end

  describe "posts_by_tag/1" do
    test "compares tags case-insensitively" do
      assert "ai" |> Blog.posts_by_tag() |> Enum.map(& &1.slug) == [
               "tw-retreat-response",
               "how-much"
             ]

      assert "AGILE" |> Blog.posts_by_tag() |> Enum.map(& &1.slug) == ["how-much"]
      assert Blog.posts_by_tag("Elixir") == []
    end
  end

  describe "author/1" do
    test "resolves cheezy with public profile details only" do
      assert {:ok, author} = Blog.author("cheezy")
      assert author.name == "Jeff \"Cheezy\" Morgan"
      assert author.avatar == "/images/blog/authors/cheezy.jpg"
      assert Enum.map(author.links, & &1.label) == ["LinkedIn", "GitHub"]
      refute inspect(author) =~ "@"

      assert @images_dir |> Path.join("authors/cheezy.jpg") |> File.regular?()
    end

    test "returns :error for an unknown author" do
      assert Blog.author("nobody") == :error
      assert Authors.all() |> Enum.map(& &1.id) == ["cheezy"]
    end
  end

  describe "__mix_recompile__?/0" do
    test "is false while the posts and images on disk are unchanged" do
      refute Blog.__mix_recompile__?()
    end
  end

  describe "Loader" do
    @describetag :tmp_dir

    test "empty directory gives no posts", %{tmp_dir: dir} do
      assert Loader.load_posts(dir) == []
      assert dir |> Path.join("missing") |> Loader.load_posts() == []
    end

    test "skips drafts and sorts newest first", %{tmp_dir: dir} do
      write_post(dir, "a.md", front_matter("older", "2026-01-01T00:00:00-05:00"))
      write_post(dir, "b.md", front_matter("newer", "2026-02-01T00:00:00-05:00"))

      write_post(
        dir,
        "c.md",
        front_matter("hidden", "2026-03-01T00:00:00-05:00", ["draft: true"])
      )

      assert dir |> Loader.load_posts() |> Enum.map(& &1.slug) == ["newer", "older"]
    end

    test "raises naming the file on an unknown author", %{tmp_dir: dir} do
      lines = front_matter("x", "2026-01-01T00:00:00Z") |> List.replace_at(2, "author: nobody")
      write_post(dir, "bad.md", lines)

      error = assert_raise ArgumentError, fn -> Loader.load_posts(dir) end
      assert error.message =~ "bad.md: unknown author \"nobody\""
    end

    test "raises naming the file on an unsafe body", %{tmp_dir: dir} do
      write_post(
        dir,
        "bad.md",
        front_matter("x", "2026-01-01T00:00:00Z"),
        "[x](javascript:alert(1))\n"
      )

      error = assert_raise ArgumentError, fn -> Loader.load_posts(dir) end
      assert error.message =~ "bad.md: link"
    end

    test "raises on two posts with the same slug, naming both files", %{tmp_dir: dir} do
      write_post(dir, "a.md", front_matter("same", "2026-01-01T00:00:00Z"))
      write_post(dir, "b.md", front_matter("same", "2026-02-01T00:00:00Z"))

      error = assert_raise ArgumentError, fn -> Loader.load_posts(dir) end
      assert error.message =~ ~s(two posts share the slug "same": )
      assert error.message =~ ~r/a\.md, .*b\.md\z/
    end

    test "raises when a draft shares its slug with a published post", %{tmp_dir: dir} do
      write_post(dir, "live.md", front_matter("same", "2026-01-01T00:00:00Z"))

      write_post(
        dir,
        "draft.md",
        front_matter("same", "2026-02-01T00:00:00Z", ["draft: true"])
      )

      error = assert_raise ArgumentError, fn -> Loader.load_posts(dir) end
      assert error.message =~ ~s(two posts share the slug "same")
      assert error.message =~ "draft.md"
      assert error.message =~ "live.md"
    end

    test "raises when two drafts share a slug", %{tmp_dir: dir} do
      write_post(dir, "a.md", front_matter("same", "2026-01-01T00:00:00Z", ["draft: true"]))
      write_post(dir, "b.md", front_matter("same", "2026-02-01T00:00:00Z", ["draft: true"]))

      assert_raise ArgumentError, ~r/two posts share the slug "same"/, fn ->
        Loader.load_posts(dir)
      end
    end

    test "loaded posts carry no internal :path or :draft key", %{tmp_dir: dir} do
      write_post(dir, "a.md", front_matter("a", "2026-01-01T00:00:00Z"))

      assert [post] = Loader.load_posts(dir)
      refute Map.has_key?(post, :path)
      refute Map.has_key?(post, :draft)
    end

    test "listing_hash/2 changes when a post is added", %{tmp_dir: dir} do
      before = Loader.listing_hash(dir, @images_dir)
      write_post(dir, "a.md", front_matter("a", "2026-01-01T00:00:00Z"))

      refute Loader.listing_hash(dir, @images_dir) == before
    end
  end
end
