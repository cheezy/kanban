defmodule KanbanWeb.SelfHostedFontsTest do
  @moduledoc """
  Guards the self-hosted fonts (D402). app.css declares Geist, Geist Mono and
  Silkscreen with @font-face rules pointing at files under priv/static/fonts,
  so no page requests a third-party font host and the CSP can allow fonts only
  from 'self'. priv/static/fonts/README.md records where each file came from.
  """
  use KanbanWeb.ConnCase, async: true

  @static_root Path.expand("../../priv/static", __DIR__)
  @fonts_dir Path.join(@static_root, "fonts")
  @css_path Path.expand("../../assets/css/app.css", __DIR__)
  @google_host ~r/fonts\.googleapis\.com|fonts\.gstatic\.com/

  defp css, do: File.read!(@css_path)
  defp readme, do: @fonts_dir |> Path.join("README.md") |> File.read!()
  defp shipped_fonts, do: @fonts_dir |> Path.join("*.woff2") |> Path.wildcard()

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  # Each @font-face rule as a map of descriptor name to value.
  defp font_faces(css) do
    ~r/@font-face\s*\{([^{}]*)\}/
    |> Regex.scan(strip_comments(css), capture: :all_but_first)
    |> Enum.map(fn [body] -> descriptors(body) end)
  end

  defp descriptors(body) do
    body
    |> String.split(";", trim: true)
    |> Enum.map(&String.split(&1, ":", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [name, value] -> {String.trim(name), String.trim(value)} end)
  end

  defp face_urls(face) do
    ~r/url\(\s*(['"]?)([^'")\s]+)\1\s*\)/
    |> Regex.scan(Map.get(face, "src", ""), capture: :all_but_first)
    |> Enum.map(fn [_quote, url] -> url end)
  end

  # Every @font-face url that is off-site or names no file under priv/static.
  defp missing_files(faces) do
    for face <- faces, url <- face_urls(face), not local_file?(url), do: url
  end

  defp local_file?("/" <> _ = url) do
    not String.starts_with?(url, "//") and
      @static_root |> Path.join(String.trim_leading(url, "/")) |> File.regular?()
  end

  defp local_file?(_url), do: false

  defp faces_without_swap(faces) do
    for face <- faces, Map.get(face, "font-display") != "swap", do: Map.get(face, "font-family")
  end

  # Every @import that loads a remote stylesheet rather than a build input.
  defp remote_imports(css) do
    ~r/@import\s+([^;]+);/
    |> Regex.scan(strip_comments(css), capture: :all_but_first)
    |> Enum.map(fn [target] -> String.trim(target) end)
    |> Enum.filter(&(&1 =~ ~r/url\(|https?:|\/\//))
  end

  defp family(face),
    do: face |> Map.get("font-family", "") |> String.trim("'") |> String.trim("\"")

  defp weight_range(face) do
    face
    |> Map.get("font-weight", "")
    |> String.split()
    |> Enum.map(&String.to_integer/1)
    |> case do
      [low, high] -> low..high
      [weight] -> weight..weight
    end
  end

  describe "app.css @font-face rules" do
    test "Every url() in an app.css @font-face rule points at a file that exists under priv/static/fonts" do
      faces = font_faces(css())

      assert faces != []
      assert missing_files(faces) == []

      for face <- faces, url <- face_urls(face) do
        assert String.starts_with?(url, "/fonts/"), "#{url} is not under /fonts/"
      end
    end

    test "app.css contains no Google Fonts @import or host" do
      refute css() =~ @google_host
      assert remote_imports(css()) == []
    end

    test "every @font-face rule uses font-display: swap" do
      assert faces_without_swap(font_faces(css())) == []
    end

    test "declares the families the --font-sans, --font-mono and --font-pixel tokens name" do
      declared = css() |> font_faces() |> Enum.map(&family/1) |> MapSet.new()

      for token <- ~w(--font-sans --font-mono --font-pixel) do
        [_, first_family] = Regex.run(~r/#{token}:\s*'([^']+)'/, css())
        assert first_family in declared, "#{token} names #{first_family}, which has no @font-face"
      end
    end

    test "every numeric font-weight app.css sets is inside a declared Geist range" do
      [geist] = css() |> font_faces() |> Enum.filter(&(family(&1) == "Geist"))
      range = weight_range(geist)

      weights =
        ~r/font-weight:\s*(\d{3})\s*;/
        |> Regex.scan(
          css() |> strip_comments() |> then(&Regex.replace(~r/@font-face\s*\{[^{}]*\}/, &1, "")),
          capture: :all_but_first
        )
        |> Enum.map(fn [weight] -> String.to_integer(weight) end)
        |> Enum.uniq()

      assert weights != []

      for weight <- weights do
        assert weight in range,
               "font-weight #{weight} is outside Geist's declared #{inspect(range)}"
      end
    end
  end

  describe "priv/static/fonts" do
    test "each woff2 under priv/static/fonts is declared in app.css, listed in README.md, and its family's OFL text ships beside it" do
      declared = css() |> font_faces() |> Enum.flat_map(&face_urls/1) |> MapSet.new()
      readme = readme()

      assert shipped_fonts() != []

      for path <- shipped_fonts() do
        name = Path.basename(path)
        licence = Path.join(@fonts_dir, licence_for(name))

        assert "/fonts/#{name}" in declared, "#{name} is not declared in app.css"
        assert readme =~ "`#{name}`", "#{name} is not listed in README.md"
        assert File.regular?(licence), "#{name} has no #{Path.basename(licence)} beside it"
        assert File.read!(licence) =~ ~r/SIL OPEN FONT LICENSE Version 1\.1/i
      end
    end

    test "README.md records the sha256 of every shipped file" do
      readme = readme()
      files = @fonts_dir |> Path.join("*.{woff2,txt}") |> Path.wildcard()

      assert length(files) == 6

      for path <- files do
        hash = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
        assert readme =~ hash, "README.md does not record the sha256 of #{Path.basename(path)}"
      end
    end
  end

  describe "serving" do
    test "GET /fonts/<a self-hosted file> returns 200 with a font content type", %{conn: conn} do
      urls = css() |> font_faces() |> Enum.flat_map(&face_urls/1)

      assert length(urls) == 4

      for url <- urls do
        response = get(conn, url)

        assert response.status == 200, "#{url} returned #{response.status}"
        assert [content_type] = get_resp_header(response, "content-type")
        assert String.starts_with?(content_type, "font/woff2")
      end
    end

    test "GET /HitMe renders under a self-only font-src", %{conn: conn} do
      conn = get(conn, ~p"/HitMe")

      assert html_response(conn, 200) =~ ~s(id="hitme-hero")
      [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "font-src 'self';"
      refute policy =~ @google_host
    end
  end

  describe "phx.digest" do
    @describetag :tmp_dir

    test "the cache manifest lists every font and the digested app.css points at the digested names",
         %{tmp_dir: tmp_dir} do
      input = Path.join(tmp_dir, "input")
      output = Path.join(tmp_dir, "output")
      css_copy = Path.join(input, "assets/css/app.css")
      css_copy |> Path.dirname() |> File.mkdir_p!()
      File.cp_r!(@fonts_dir, Path.join(input, "fonts"))
      File.cp!(@css_path, css_copy)

      assert :ok = Phoenix.Digester.compile(input, output, true)

      latest = output |> Path.join("cache_manifest.json") |> File.read!() |> Jason.decode!()
      digested_css = output |> Path.join(latest["latest"]["assets/css/app.css"]) |> File.read!()

      for path <- shipped_fonts() do
        name = Path.basename(path)
        digested = latest["latest"]["fonts/#{name}"]

        assert digested =~ ~r/^fonts\/#{Path.rootname(name)}-[0-9a-f]{32}\.woff2$/
        assert output |> Path.join(digested) |> File.regular?()
        assert digested_css =~ "url('/#{digested}?vsn=d')"
        refute digested_css =~ "url('/fonts/#{name}')"
      end
    end
  end

  describe "the checks themselves" do
    @fixture """
    /* a comment with @font-face { src: url('/fonts/Commented.woff2') } inside */
    @import "tailwindcss" source(none);
    @import url('https://fonts.googleapis.com/css2?family=X');
    @import "//cdn.example.test/y.css";
    @font-face {
      font-family: 'Present';
      font-display: swap;
      src: url('/fonts/Geist-Variable.woff2') format('woff2');
    }
    @font-face {
      font-family: "Missing";
      font-display: block;
      src: url(/fonts/Missing.woff2) format('woff2');
    }
    @font-face {
      font-family: 'Offsite';
      src: url("https://cdn.example.test/x.woff2");
    }
    """

    test "missing_files/1 reports missing and off-site files, ignoring comments" do
      assert missing_files(font_faces(@fixture)) == [
               "/fonts/Missing.woff2",
               "https://cdn.example.test/x.woff2"
             ]
    end

    test "faces_without_swap/1 reports faces with another or no font-display" do
      assert faces_without_swap(font_faces(@fixture)) == [~s("Missing"), "'Offsite'"]
    end

    test "remote_imports/1 reports a remote stylesheet but not the tailwind import" do
      assert remote_imports(@fixture) == [
               "url('https://fonts.googleapis.com/css2?family=X')",
               ~s("//cdn.example.test/y.css")
             ]
    end

    test "local_file?/1 accepts only a site-relative path to an existing file" do
      # A protocol-relative url whose path happens to name a shipped file.
      refute local_file?("//fonts/Geist-Variable.woff2")
      refute local_file?("fonts/Geist-Variable.woff2")
      assert local_file?("/fonts/Geist-Variable.woff2")
    end
  end

  defp licence_for("Silkscreen" <> _), do: "Silkscreen-OFL.txt"
  defp licence_for("Geist" <> _), do: "Geist-OFL.txt"
  defp licence_for(name), do: "no licence mapping for #{name}"
end
