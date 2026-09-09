defmodule Mix.Tasks.R2.MovePostImages do
  @shortdoc "Moves post images from the bucket root into the posts/ prefix"

  @moduledoc """
  Moves post images from the root of the R2 bucket into the posts/ prefix.

  R2 speaks the S3 API, and that includes CopyObject - so a move is a
  server-side copy followed by a delete and the bytes never leave Cloudflare.

  Only UUID-named objects sitting directly in the bucket root are touched. That
  is the shape the post uploader produces and nothing else does, so opengraph/,
  bookmarks/ and anything already under posts/ are left alone.

  The steps are separate so the originals can stay put until the database
  migration has run and the site has been eyeballed:

      mix r2.move_post_images plan     # what would move
      mix r2.move_post_images copy     # root -> posts/, originals kept
      mix r2.move_post_images verify   # every copy present and the same size
      mix ecto.migrate                 # now point the posts at the new URLs
      mix r2.move_post_images delete   # finally, drop the originals

  `copy` and `verify` are safe to re-run. `delete` re-checks the copies itself
  and asks before doing the one irreversible thing; pass `--yes` to skip the
  prompt.

  Bucket and credentials come from the usual environment variables:
  CF_ACCESS_KEY_ID, CF_SECRET_ACCESS_KEY, CF_BUCKET and CF_S3_HOST.
  """

  use Mix.Task

  alias Jamie.Service

  @storage Service.get!(:r2)

  @prefix "posts/"

  # A key that is a bare UUID plus an extension, with no directory in front.
  @root_uuid_key ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-zA-Z0-9]+$/

  # DeleteObjects takes at most 1000 keys per request.
  @batch_size 1000

  @requirements ["app.start"]

  @impl Mix.Task
  def run(["plan"]), do: plan()
  def run(["copy"]), do: copy()
  def run(["verify"]), do: verify()
  def run(["delete"]), do: delete(confirm?: true)
  def run(["delete", "--yes"]), do: delete(confirm?: false)

  def run(_args) do
    Mix.raise("Usage: mix r2.move_post_images plan|copy|verify|delete [--yes]")
  end

  defp plan do
    images = root_images()

    Enum.each(images, fn {key, size} ->
      shell("#{key} -> #{@prefix}#{key}  (#{bytes(size)})")
    end)

    total = images |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    shell("\n#{count(images)}, #{bytes(total)} total")
  end

  defp copy do
    images = root_images()
    already_there = copied_images()

    {copied, skipped} =
      images
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {{key, size}, index}, {copied, skipped} ->
        destination = @prefix <> key

        # Copying twice is harmless, but there's no point paying for it.
        if already_there[destination] == size do
          shell("[#{index}/#{length(images)}] #{destination} already there, skipping")
          {copied, skipped + 1}
        else
          shell("[#{index}/#{length(images)}] copying #{key} -> #{destination}")
          {:ok, _} = @storage.copy_file(key, destination)
          {copied + 1, skipped}
        end
      end)

    shell("\ncopied #{copied}, already present #{skipped}")
  end

  defp verify do
    images = root_images()

    case mismatches(images) do
      [] ->
        shell("all #{count(images)} copied and matching - safe to delete")

      mismatches ->
        Enum.each(mismatches, &report_mismatch/1)
        Mix.raise("#{length(mismatches)} of #{length(images)} object(s) failed verification")
    end
  end

  defp report_mismatch({key, expected, actual}) do
    found = if actual, do: bytes(actual), else: "absent"
    shell("MISMATCH #{key}: expected #{bytes(expected)}, #{found}")
  end

  defp delete(confirm?: confirm?) do
    images = root_images()

    # Deleting the originals is the irreversible step, so re-check the copies
    # here rather than trusting that `verify` was run.
    case mismatches(images) do
      [] -> :ok
      [{key, _, _} | _] -> Mix.raise("#{key} is missing or a different size - run copy first")
    end

    if confirm? and not Mix.shell().yes?("Delete #{count(images)} from the bucket root?") do
      Mix.raise("aborted")
    end

    keys = Enum.map(images, &elem(&1, 0))
    total = length(keys)

    keys
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.each(fn {batch, batch_number} ->
      {:ok, _} = @storage.delete_files(batch)
      shell("deleted #{min(batch_number * @batch_size, total)}/#{total}")
    end)

    shell("\ndeleted #{count(images)}")
  end

  defp root_images do
    @storage.list_objects()
    |> Enum.filter(fn {key, _size} -> Regex.match?(@root_uuid_key, key) end)
    |> Enum.sort()
  end

  defp copied_images, do: Map.new(@storage.list_objects(@prefix))

  # Root objects whose copy under posts/ is absent or a different size, as
  # {destination_key, expected_size, actual_size_or_nil}.
  defp mismatches(images) do
    copies = copied_images()

    images
    |> Enum.map(fn {key, size} -> {@prefix <> key, size, copies[@prefix <> key]} end)
    |> Enum.reject(fn {_key, size, actual} -> actual == size end)
  end

  defp count(images), do: "#{length(images)} object(s)"

  defp bytes(size) do
    formatted =
      size
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    "#{formatted} bytes"
  end

  defp shell(message), do: Mix.shell().info(message)
end
