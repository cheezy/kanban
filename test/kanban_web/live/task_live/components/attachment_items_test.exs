defmodule KanbanWeb.TaskLive.Components.AttachmentItemsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kanban.Attachments.TaskAttachment
  alias KanbanWeb.TaskLive.Components.AttachmentItems
  alias Phoenix.LiveView.UploadConfig
  alias Phoenix.LiveView.UploadEntry

  @prefix "attachments-view-7"

  defp attachment(attrs) do
    struct(
      %TaskAttachment{
        id: 1,
        filename: "screenshot.png",
        content_type: "image/png",
        byte_size: 2048,
        uploaded_by: nil,
        inserted_at: ~N[2026-10-30 10:00:00]
      },
      attrs
    )
  end

  defp render_list(attachments, attrs \\ []) do
    render_component(
      &AttachmentItems.attachment_list/1,
      [attachments: attachments, dom_prefix: @prefix] ++ attrs
    )
  end

  defp entry(attrs) do
    struct(
      %UploadEntry{
        ref: "0",
        upload_ref: "phx-upload",
        upload_config: :files,
        client_name: "photo.png",
        client_type: "image/png",
        client_size: 1024,
        progress: 0,
        valid?: true
      },
      attrs
    )
  end

  defp upload(entries, errors \\ []) do
    %UploadConfig{name: :files, ref: "phx-upload", entries: entries, errors: errors}
  end

  defp render_entries(config),
    do: render_component(&AttachmentItems.upload_entries/1, upload: config)

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  defp attr(html, selector, name),
    do: html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  describe "attachment_list/1 thumbnails" do
    test "renders a thumbnail and a preview overlay for a png attachment" do
      html = render_list([attachment(%{id: 42, filename: "shot.png"})])
      lightbox = "##{@prefix}-attachment-42-lightbox"
      thumb = lightbox <> "-open"

      assert attr(html, "#{thumb} img", "src") == ["/attachments/42/preview"]
      assert attr(html, "#{thumb} img", "loading") == ["lazy"]
      assert attr(html, "#{thumb} img", "alt") == ["shot.png"]

      # A very large image is still drawn as a fixed 40x40 cover-cropped thumbnail,
      # and the full image in the lightbox is bounded by the viewport.
      assert attr(html, "#{thumb} img", "width") == ["40"]
      assert attr(html, "#{thumb} img", "height") == ["40"]
      assert attr(html, "#{thumb} img", "style") |> hd() =~ "object-fit: cover"
      lightbox_img_style = attr(html, "#{lightbox} img", "style") |> hd()
      assert lightbox_img_style =~ "max-width: min(90vw, 1200px)"
      assert lightbox_img_style =~ "max-height: 80vh"
      assert attr(html, thumb, "aria-label") == ["Open preview of shot.png"]
      assert attr(html, thumb, "phx-click") |> hd() =~ "focus_first"

      assert attr(html, lightbox, "role") == ["dialog"]
      assert attr(html, lightbox, "aria-modal") == ["true"]
      assert attr(html, lightbox, "class") == ["hidden"]
      assert attr(html, "#{lightbox} img", "src") == ["/attachments/42/preview"]
      assert attr(html, "#{lightbox} a", "href") == ["/attachments/42/download"]
      assert count(html, "#{lightbox}-close") == 1
      assert html |> doc() |> LazyHTML.query("#{lightbox}-close") |> LazyHTML.text() =~ "Close"
      assert attr(html, "#{lightbox}-backdrop", "phx-click") |> hd() =~ "hide"

      # Tab stays inside the dialog: its panel is a focus_wrap around the controls.
      assert attr(html, "#{lightbox}-panel", "phx-hook") == ["Phoenix.FocusWrap"]
      assert count(html, "#{lightbox}-panel #{lightbox}-content #{lightbox}-close") == 1

      # The Close button is the lightbox's first focusable control, so
      # JS.focus_first lands on it, and nothing binds Escape.
      [first_control | _] =
        html |> doc() |> LazyHTML.query("#{lightbox} button, #{lightbox} a") |> Enum.to_list()

      assert LazyHTML.attribute(first_control, "id") == [
               "#{@prefix}-attachment-42-lightbox-close"
             ]

      refute html =~ "phx-key"
      refute html =~ "phx-window-keydown"

      # The thumbnail replaces the type icon.
      assert count(html, "##{@prefix}-attachment-42 .hero-photo") == 0
    end

    test "renders a thumbnail for every raster type" do
      for type <- ~w(image/png image/jpeg image/gif image/webp) do
        html = render_list([attachment(%{id: 5, content_type: type})])

        assert count(html, "##{@prefix}-attachment-5-lightbox-open img") == 1, type
        assert count(html, "##{@prefix}-attachment-5-lightbox") == 1, type
      end
    end

    test "renders no thumbnail for svg, pdf or text attachments" do
      for {type, icon} <- [
            {"image/svg+xml", "hero-photo"},
            {"application/pdf", "hero-document"},
            {"text/plain", "hero-document-text"},
            {"text/html", "hero-document-text"}
          ] do
        html = render_list([attachment(%{id: 9, filename: "file.png", content_type: type})])

        refute html =~ "/attachments/9/preview", type
        assert count(html, "img") == 0, type
        assert count(html, "[role=dialog]") == 0, type
        assert count(html, ".#{icon}") == 1, type
      end
    end

    test "an attachment with a nil content type gets the generic icon and no thumbnail" do
      html = render_list([attachment(%{id: 3, content_type: nil})])

      assert count(html, ".hero-paper-clip") == 1
      assert count(html, "img") == 0
      refute html =~ "/attachments/3/preview"
    end

    test "an upper-case or parameterised stored type gets no thumbnail" do
      for type <- ["image/PNG", "image/png; charset=binary"] do
        html = render_list([attachment(%{id: 4, content_type: type})])

        assert count(html, "img") == 0, type
      end
    end

    test "overlay ids carry the host prefix, so two hosts never share one" do
      a = attachment(%{id: 11})

      view =
        render_component(&AttachmentItems.attachment_list/1,
          attachments: [a],
          dom_prefix: "attachments-view-7"
        )

      form =
        render_component(&AttachmentItems.attachment_list/1,
          attachments: [a],
          dom_prefix: "attachments-form-7"
        )

      assert count(view <> form, "#attachments-view-7-attachment-11-lightbox") == 1
      assert count(view <> form, "#attachments-form-7-attachment-11-lightbox") == 1
    end

    # A screen reader lists every control on the page out of context, so a row
    # of "Download" and "Delete" links must each say which file they act on.
    test "names the file in every Download and Delete control" do
      html =
        render_list(
          [
            attachment(%{id: 3, filename: "notes.txt", content_type: "text/plain"}),
            attachment(%{id: 4, filename: "shot.png"})
          ],
          can_delete: fn _attachment -> true end
        )

      assert attr(html, ~s(a[href="/attachments/3/download"]), "aria-label") == [
               "Download notes.txt"
             ]

      # The png's row link and its lightbox link both name it.
      assert attr(html, ~s(a[href="/attachments/4/download"]), "aria-label") == [
               "Download shot.png",
               "Download shot.png"
             ]

      assert attr(html, ~s(button[phx-value-id="3"]), "aria-label") == ["Delete notes.txt"]
      assert attr(html, ~s(button[phx-value-id="4"]), "aria-label") == ["Delete shot.png"]
    end

    test "escapes a crafted filename in the alt text and labels" do
      html = render_list([attachment(%{id: 6, filename: ~s("><script>x</script>.png)})])

      refute html =~ "<script>x</script>"

      assert attr(html, "##{@prefix}-attachment-6-lightbox-open img", "alt") == [
               ~s("><script>x</script>.png)
             ]
    end
  end

  describe "show_lightbox/1, hide_lightbox/1 and lightbox_id/2" do
    test "lightbox_id/2 prefixes the attachment id with the host prefix" do
      assert AttachmentItems.lightbox_id("attachments-form-3", %{id: 8}) ==
               "attachments-form-3-attachment-8-lightbox"
    end

    test "show_lightbox/1 shows the overlay and focuses its first control" do
      %Phoenix.LiveView.JS{ops: ops} = AttachmentItems.show_lightbox("lb")

      assert ["show", %{to: "#lb", display: "flex"}] in ops
      assert ["focus_first", %{to: "#lb-content"}] in ops
    end

    test "hide_lightbox/1 hides the overlay and returns focus to its thumbnail" do
      %Phoenix.LiveView.JS{ops: ops} = AttachmentItems.hide_lightbox("lb")

      assert ["hide", %{to: "#lb"}] in ops
      assert ["focus", %{to: "#lb-open"}] in ops
    end
  end

  describe "thumbnail?/1 and staged_preview?/1" do
    test "thumbnail?/1 is true only for the four stored raster types" do
      assert AttachmentItems.thumbnail?(%{content_type: "image/webp"})
      refute AttachmentItems.thumbnail?(%{content_type: "image/svg+xml"})
      refute AttachmentItems.thumbnail?(%{content_type: nil})
      refute AttachmentItems.thumbnail?(%{})
    end

    test "staged_preview?/1 needs a valid entry with a raster client type" do
      preview? = fn attrs -> attrs |> entry() |> AttachmentItems.staged_preview?() end

      assert preview?.(%{client_type: "image/gif"})
      assert preview?.(%{client_type: "image/JPEG"})
      refute preview?.(%{client_type: "image/svg+xml"})
      refute preview?.(%{client_type: "application/pdf"})
      refute preview?.(%{client_type: nil})
      refute preview?.(%{valid?: false})
    end
  end

  describe "upload_entries/1 previews" do
    test "renders a live_img_preview for a staged raster entry" do
      html = render_entries(upload([entry(%{ref: "0", client_name: "photo.png"})]))

      assert attr(html, "#upload-entry-0 img", "data-phx-entry-ref") == ["0"]
      assert attr(html, "#upload-entry-0 img", "alt") == ["photo.png"]
      assert count(html, "#upload-entry-0 .hero-photo") == 0
    end

    test "a staged non-raster entry keeps its icon and gets no preview" do
      html =
        render_entries(
          upload([
            entry(%{ref: "1", client_name: "a.svg", client_type: "image/svg+xml"}),
            entry(%{ref: "2", client_name: "b.pdf", client_type: "application/pdf"})
          ])
        )

      assert count(html, "img") == 0
      assert count(html, "#upload-entry-1 .hero-photo") == 1
      assert count(html, "#upload-entry-2 .hero-document") == 1
    end

    # The bar alone cannot carry the progress: in the light theme its fill is
    # under 3:1 against its own track, so the percentage is shown as text too.
    test "shows each staged entry's progress as text beside its size" do
      html = render_entries(upload([entry(%{ref: "7", client_name: "a.txt", progress: 42})]))

      assert html
             |> doc()
             |> LazyHTML.query("#upload-entry-7-progress")
             |> LazyHTML.text()
             |> String.trim() ==
               "42%"

      assert attr(html, "#upload-entry-7-progress", "aria-hidden") == ["true"]
      assert attr(html, "#upload-entry-7 progress", "value") == ["42"]
    end

    test "draws the progress fill in the gated brand accent" do
      html = render_entries(upload([entry(%{ref: "8", client_name: "b.txt"})]))

      [class] = attr(html, "#upload-entry-8 progress", "class")
      refute class =~ "progress-primary"
      assert [style] = attr(html, "#upload-entry-8 progress", "style")
      assert style =~ "color: var(--stride-orange)"
    end

    test "shows the translated error and no preview for a rejected staged image" do
      rejected = entry(%{ref: "3", client_name: "huge.png", valid?: false})
      html = render_entries(upload([rejected], [{"3", :too_large}]))

      assert count(html, "#upload-entry-3 img") == 0
      assert count(html, "#upload-entry-3 .hero-photo") == 1

      assert html |> doc() |> LazyHTML.query("#upload-entry-3 .upload-error") |> LazyHTML.text() =~
               "This file is larger than the"
    end
  end

  describe "upload_entries/1 names" do
    # The browser sends the name as typed; the server stores it cleaned by
    # Kanban.Attachments.Filename, so the staged row must show that same name.
    test "shows a staged entry under its cleaned name, without bidi overrides or directories" do
      raw = "C:\\fakepath\\invoice\u202Egpj.txt"
      html = render_entries(upload([entry(%{ref: "4", client_name: raw})]))

      refute html =~ "\u202E"
      refute html =~ "fakepath"
      shown = "invoicegpj.txt"
      assert attr(html, "#upload-entry-4 img", "alt") == [shown]
      assert attr(html, "#upload-entry-4 span.truncate", "title") == [shown]

      assert attr(html, "#upload-entry-4 button", "aria-label") == [
               "Cancel upload of " <> shown
             ]

      assert attr(html, "#upload-entry-4 progress", "aria-label") == [
               "Upload progress for " <> shown
             ]
    end

    test "caps a very long staged name at the stored length" do
      raw = String.duplicate("a", 5000) <> ".png"
      html = render_entries(upload([entry(%{ref: "5", client_name: raw})]))

      [title] = attr(html, "#upload-entry-5 span.truncate", "title")
      assert String.length(title) == Kanban.Attachments.Filename.max_codepoints()
      assert String.ends_with?(title, ".png")
    end

    test "shows a placeholder for a name that is blank once cleaned" do
      html = render_entries(upload([entry(%{ref: "6", client_name: "   \u200B "})]))

      assert attr(html, "#upload-entry-6 span.truncate", "title") == ["unnamed file"]
    end
  end
end
