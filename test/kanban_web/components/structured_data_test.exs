defmodule KanbanWeb.StructuredDataTest do
  @moduledoc """
  Contract tests for the schema.org JSON-LD blocks (W2893): the
  `KanbanWeb.SeoComponents.structured_data/1` component, the Organization block
  on the home page, the SoftwareApplication block on the pricing page, and the
  `KanbanWeb.Pricing` prices both the pricing page and its block read.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.PageHTML
  alias KanbanWeb.Pricing
  alias KanbanWeb.SeoComponents

  @locales ~w(de en es fr ja pt zh)

  @ld_selector ~s(script[type="application/ld+json"])

  # Every PageController GET page except the two that carry a block, plus a
  # page from outside PageController.
  @other_paths KanbanWeb.Router
               |> Phoenix.Router.routes()
               |> Enum.filter(&(&1.plug == KanbanWeb.PageController and &1.verb == :get))
               |> Enum.map(& &1.path)
               |> Enum.reject(&(&1 in ["/", "/pricing"]))
               |> Enum.concat(["/users/log-in"])

  defp render_block(data, nonce \\ nil) do
    assigns = %{data: data, nonce: nonce}

    rendered_to_string(~H"""
    <SeoComponents.structured_data data={@data} nonce={@nonce} />
    """)
  end

  defp ld_scripts(html), do: html |> LazyHTML.from_document() |> LazyHTML.query(@ld_selector)

  # The raw text of every JSON-LD script in the page, in document order.
  defp ld_bodies(html) do
    ~r{<script type="application/ld\+json"[^>]*>(.*?)</script>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp ld_blocks(html), do: html |> ld_bodies() |> Enum.map(&Jason.decode!/1)

  defp header_nonce(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)
    {policy, nonce}
  end

  describe "structured_data/1" do
    test "a value containing a closing script tag is escaped and cannot end the block" do
      hostile = "</script><script>alert(1)</script><!--"
      html = render_block(%{"@context" => "https://schema.org", "name" => hostile})

      # The only closing tag is the component's own, and no new element starts.
      assert length(String.split(html, "</script>")) == 2
      refute html =~ "<script>alert"
      refute html =~ "<!--"
      assert html =~ "\\u003C\\/script>"

      assert [%{"name" => ^hostile}] = ld_blocks(html)
    end

    test "escapes a hostile key as well as a hostile value" do
      html = render_block(%{"</script>" => "x"})

      assert length(String.split(html, "</script>")) == 2
      assert [%{"</script>" => "x"}] = ld_blocks(html)
    end

    test "renders the nonce it is given and none when it is nil" do
      [with_nonce] =
        %{"a" => 1} |> render_block("n1") |> ld_scripts() |> LazyHTML.attribute("nonce")

      assert with_nonce == "n1"

      assert %{"a" => 1} |> render_block() |> ld_scripts() |> LazyHTML.attribute("nonce") == []
    end

    test "encode_json_ld/1 round-trips through Jason" do
      data = %{"url" => "https://example.test/a/b", "text" => "a < b & c > d"}
      encoded = SeoComponents.encode_json_ld(data)

      refute encoded =~ "<"
      # Every slash is escaped as \/.
      refute encoded =~ ~r{(?<!\\)/}
      assert Jason.decode!(encoded) == data
    end
  end

  describe "home page" do
    test "the home page renders one Organization JSON-LD block with name, url and logo",
         %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert [block] = ld_blocks(html)
      assert block["@type"] == "Organization"
      assert block["name"] == "Stride"
      assert block["url"] == SeoComponents.canonical_url("/")
      assert String.starts_with?(block["logo"], KanbanWeb.Endpoint.static_url())
      assert block["logo"] =~ ~r{/images/logos/abstract-s-motion(-[0-9a-f]+)?\.svg}
      assert block["sameAs"] == [KanbanWeb.MarketingClosing.github_url()]
      refute Map.has_key?(block, "aggregateRating")
      refute Map.has_key?(block, "review")
    end
  end

  describe "pricing page" do
    test "the pricing page renders a SoftwareApplication block whose offers match the prices on the page",
         %{conn: conn} do
      html = conn |> get(~p"/pricing") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert [block] = ld_blocks(html)
      assert block["@type"] == "SoftwareApplication"
      assert block["applicationCategory"] == "BusinessApplication"
      refute Map.has_key?(block, "aggregateRating")
      refute Map.has_key?(block, "review")

      offers = block["offers"]
      assert length(offers) == length(Pricing.fixed_price_plans())
      assert Enum.map(offers, & &1["name"]) == ["Free", "Organization"]

      # The plan priced on request is in the price list but never offered.
      assert Enum.any?(Pricing.plans(), &is_nil(&1.amount))
      refute Enum.any?(offers, &(&1["name"] =~ "250"))

      [free, organization] = offers
      assert free["price"] == "0"
      assert document |> LazyHTML.query("#plan-free h2") |> LazyHTML.text() =~ "Free"

      plan = Pricing.plan!(:organization)
      assert organization["price"] == Integer.to_string(plan.amount)
      assert organization["priceCurrency"] == plan.currency
      assert organization["priceSpecification"]["price"] == organization["price"]
      assert organization["priceSpecification"]["billingDuration"] == "P1M"

      page_price = document |> LazyHTML.query("#organization-price") |> LazyHTML.text()
      assert page_price =~ Pricing.price_label(plan)
      assert page_price =~ organization["price"]
      assert page_price =~ organization["priceCurrency"]
    end

    test "GET /pricing and compare each offer price with the price text on the page",
         %{conn: conn} do
      english = conn |> get(~p"/pricing") |> html_response(200) |> ld_bodies()
      plan = Pricing.plan!(:organization)

      for locale <- @locales do
        html = build_conn() |> get(~p"/pricing?locale=#{locale}") |> html_response(200)

        # The block is byte-for-byte the same in every locale.
        assert ld_bodies(html) == english, "block differs in #{locale}"

        [%{"offers" => [_free, organization]}] = ld_blocks(html)

        page_price =
          html
          |> LazyHTML.from_document()
          |> LazyHTML.query("#organization-price")
          |> LazyHTML.text()

        label =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> Pricing.price_label(plan) end)

        assert page_price =~ label, "page price is not #{inspect(label)} in #{locale}"
        assert page_price =~ organization["price"], "offer price missing in #{locale}"
      end
    end

    test "pricing_structured_data/1 leaves out a plan with no fixed price" do
      plans = [
        %{key: :a, name: "A", amount: 5, currency: "CAD", unit: nil},
        %{key: :b, name: "B", amount: nil, currency: nil, unit: nil}
      ]

      assert %{"offers" => [offer]} = PageHTML.pricing_structured_data(plans)
      assert offer["name"] == "A"
      assert offer["price"] == "5"
      refute Map.has_key?(offer, "priceSpecification")
    end
  end

  describe "both blocks" do
    test "the block decodes as JSON with the schema.org context" do
      for path <- ["/", "/pricing"] do
        html = build_conn() |> get(path) |> html_response(200)
        assert [%{"@context" => "https://schema.org"}] = ld_blocks(html)
      end
    end

    test "the JSON-LD script tag carries the request CSP nonce" do
      for path <- ["/", "/pricing"] do
        conn = get(build_conn(), path)
        {policy, nonce} = header_nonce(conn)

        assert conn |> html_response(200) |> ld_scripts() |> LazyHTML.attribute("nonce") == [
                 nonce
               ]

        [script_src] = Regex.run(~r/script-src[^;]*/, policy)
        refute script_src =~ "unsafe-inline"
      end
    end

    test "pages other than home and pricing render no JSON-LD" do
      for path <- @other_paths do
        html = build_conn() |> get(path) |> html_response(200)
        assert ld_bodies(html) == [], "#{path} renders JSON-LD"
      end
    end
  end

  describe "KanbanWeb.Pricing" do
    test "plan!/1 raises for an unknown plan" do
      assert_raise ArgumentError, ~r/unknown plan :nope/, fn -> Pricing.plan!(:nope) end
    end

    test "price_label/1 is translated" do
      plan = Pricing.plan!(:organization)

      assert Pricing.price_label(plan) == "$12 CAD"

      assert Gettext.with_locale(KanbanWeb.Gettext, "de", fn -> Pricing.price_label(plan) end) ==
               "12 CAD"
    end

    test "fixed_price_plans/0 keeps only the plans with an amount and a currency" do
      assert Enum.map(Pricing.fixed_price_plans(), & &1.key) == [:free, :organization]
    end
  end
end
