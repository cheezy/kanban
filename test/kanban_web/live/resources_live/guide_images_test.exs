defmodule KanbanWeb.ResourcesLive.GuideImagesTest do
  @moduledoc """
  Guards the screenshots the Resources guides point at: each one must exist
  under priv/static, be a PNG in images/resources/guides, and declare the
  size it really is. The page reserves the declared size before the image
  loads, so a wrong size makes the page jump. Every PNG in that folder must
  also be used by some guide, so a replaced screenshot doesn't linger.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.ResourcesLive.HowToData

  @static_root Path.expand("../../../../priv/static", __DIR__)
  @guides_dir "/images/resources/guides/"

  # The defaults KanbanWeb.ResourcesLive.Components applies when a step leaves
  # a size out: 1280x720 for `image`, 640x360 for each entry in `images`.
  @image_default {1280, 720}
  @images_default {640, 360}

  describe "the guides' images" do
    test "every image a guide references exists under priv/static" do
      assert missing(HowToData.all_how_tos()) == []
    end

    test "every referenced image is a PNG under images/resources/guides" do
      assert misplaced(HowToData.all_how_tos()) == []
    end

    test "declared image_width/image_height match the PNG header" do
      assert size_mismatches(HowToData.all_how_tos()) == []
    end

    test "no PNG in images/resources/guides is unreferenced" do
      assert unreferenced(HowToData.all_how_tos(), guide_pngs()) == []
    end
  end

  describe "the checks themselves" do
    test "reports the guide id and step title of a missing image" do
      guide =
        guide("demo-guide", [
          %{title: "Open the Form", content: "", image: "/images/resources/guides/nope.png"}
        ])

      assert missing([guide]) == [
               ~s(demo-guide step "Open the Form": /images/resources/guides/nope.png does not exist under priv/static)
             ]
    end

    test "reports a size that doesn't match the PNG, naming the guide and step" do
      guide =
        guide("demo-guide", [
          %{
            title: "Save",
            content: "",
            image: "/images/resources/guides/adding-task-step-1.png",
            image_width: 517,
            image_height: 263
          }
        ])

      assert size_mismatches([guide]) == [
               ~s(demo-guide step "Save": /images/resources/guides/adding-task-step-1.png declares 517x263 but is 560x160)
             ]
    end

    test "applies the component's default size when a step leaves it out" do
      guide =
        guide("demo-guide", [
          %{
            title: "Read",
            content: "",
            images: [%{url: "/images/resources/guides/adding-task-step-1.png"}]
          }
        ])

      assert size_mismatches([guide]) == [
               ~s(demo-guide step "Read": /images/resources/guides/adding-task-step-1.png declares 640x360 but is 560x160)
             ]
    end

    test "flags an image outside images/resources/guides or not a PNG" do
      guide =
        guide("demo-guide", [
          %{title: "Elsewhere", content: "", image: "/images/logo.png"},
          %{title: "Vector", content: "", image: "/images/resources/guides/diagram.svg"}
        ])

      assert misplaced([guide]) == [
               ~s(demo-guide step "Elsewhere": /images/logo.png is not a PNG under /images/resources/guides/),
               ~s(demo-guide step "Vector": /images/resources/guides/diagram.svg is not a PNG under /images/resources/guides/)
             ]
    end

    test "guides with no images pass" do
      guide =
        guide("demo-guide", [
          %{title: "Plain", content: "Text only", image: nil},
          %{title: "No key", content: "Text only"}
        ])

      assert missing([guide]) == []
      assert misplaced([guide]) == []
      assert size_mismatches([guide]) == []
    end

    test "reports a PNG in the folder that no guide uses, from either image key" do
      guide =
        guide("demo-guide", [
          %{title: "One", content: "", image: "/images/resources/guides/used-single.png"},
          %{
            title: "Many",
            content: "",
            images: [%{url: "/images/resources/guides/used-many.png"}]
          }
        ])

      pngs =
        Enum.map(
          ~w(used-single.png used-many.png left-over.png),
          &static_path(@guides_dir <> &1)
        )

      assert unreferenced([guide], pngs) == [
               "/images/resources/guides/left-over.png is in the folder but no guide uses it"
             ]
    end
  end

  defp guide(id, steps), do: %{id: id, steps: steps}

  # One {guide id, step title, url, declared {w, h}} per image in the guides.
  defp image_slots(guides) do
    for guide <- guides, step <- guide.steps, slot <- step_slots(step) do
      {guide.id, step.title, slot}
    end
  end

  defp step_slots(step), do: single_slot(step) ++ multiple_slots(step)

  defp single_slot(%{image: url} = step) when is_binary(url),
    do: [{url, declared(step[:image_width], step[:image_height], @image_default)}]

  defp single_slot(_step), do: []

  defp multiple_slots(step) do
    for image <- step[:images] || [] do
      {image.url, declared(image[:width], image[:height], @images_default)}
    end
  end

  defp declared(width, height, {default_width, default_height}),
    do: {width || default_width, height || default_height}

  defp missing(guides) do
    for {id, title, {url, _size}} <- image_slots(guides),
        path = static_path(url),
        not File.regular?(path) do
      "#{id} step #{inspect(title)}: #{url} does not exist under priv/static"
    end
  end

  defp misplaced(guides) do
    for {id, title, {url, _size}} <- image_slots(guides),
        not (String.starts_with?(url, @guides_dir) and String.ends_with?(url, ".png")) do
      "#{id} step #{inspect(title)}: #{url} is not a PNG under #{@guides_dir}"
    end
  end

  defp size_mismatches(guides) do
    for {id, title, {url, {width, height}}} <- image_slots(guides),
        path = static_path(url),
        File.regular?(path),
        {actual_width, actual_height} = png_size!(path),
        {width, height} != {actual_width, actual_height} do
      "#{id} step #{inspect(title)}: #{url} declares #{width}x#{height} " <>
        "but is #{actual_width}x#{actual_height}"
    end
  end

  defp unreferenced(guides, pngs) do
    used =
      guides
      |> image_slots()
      |> MapSet.new(fn {_id, _title, {url, _size}} -> static_path(url) end)

    for path <- pngs, path not in used do
      "#{@guides_dir}#{Path.basename(path)} is in the folder but no guide uses it"
    end
  end

  defp guide_pngs, do: [@static_root, @guides_dir, "*.png"] |> Path.join() |> Path.wildcard()

  defp static_path(url), do: Path.join(@static_root, url)

  # A PNG starts with an 8-byte signature and then the IHDR chunk, whose
  # first eight data bytes are the width and height as big-endian integers.
  defp png_size!(path) do
    case File.read!(path) do
      <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _length::32, "IHDR", width::32, height::32,
        _rest::binary>> ->
        {width, height}

      _other ->
        flunk("#{path} is not a PNG")
    end
  end
end
