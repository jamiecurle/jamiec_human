defmodule Jamie.PostImages do
  @moduledoc """
  Moves post images from the root of the R2 bucket into the posts/ prefix.

  Post images used to be signed straight into the bucket root, so their public
  URLs look like https://media.jamiecurle.com/<uuid>.png. New uploads land under
  posts/, and this walks the older objects over to join them.

  R2 speaks the S3 API, and that includes CopyObject - so a move is a
  server-side copy followed by a delete and the bytes never leave Cloudflare.

  Only UUID-named objects sitting directly in the bucket root are touched. That
  is the shape the post uploader produces and nothing else does, so opengraph/,
  bookmarks/ and anything already under posts/ are left alone.

  The steps are separate so the originals can stay put until the database
  migration has run and the site has been eyeballed. `copy/0` and `verify/0` are
  safe to re-run; `delete/0` re-checks the copies itself, but does not ask - the
  caller is responsible for confirming before it is called.

  This lives here rather than in the mix task because there is no mix in
  production. `Jamie.Release` calls it from a release eval, and
  `Mix.Tasks.R2.MovePostImages` is a thin wrapper for running it locally.

  Every function prints its progress and returns `:ok`, or `{:error, message}`
  if it could not finish.
  """

  alias Jamie.Service

  @storage Service.get!(:r2)

  @prefix "posts/"

  # A key that is a bare UUID plus an extension, with no directory in front.
  @root_uuid_key ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-zA-Z0-9]+$/

  # DeleteObjects takes at most 1000 keys per request.
  @batch_size 1000

  @doc """
  Lists the objects that would move, without touching anything.
  """
  def plan do
    images = root_images()

    Enum.each(images, fn {key, size} ->
      say("#{key} -> #{@prefix}#{key}  (#{bytes(size)})")
    end)

    total = images |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    say("\n#{count(images)}, #{bytes(total)} total")
  end

  @doc """
  Copies the root images under posts/, leaving the originals in place.
  """
  def copy do
    images = root_images()
    already_there = copied_images()

    {copied, skipped} =
      images
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {{key, size}, index}, {copied, skipped} ->
        destination = @prefix <> key

        # Copying twice is harmless, but there's no point paying for it.
        if already_there[destination] == size do
          say("[#{index}/#{length(images)}] #{destination} already there, skipping")
          {copied, skipped + 1}
        else
          say("[#{index}/#{length(images)}] copying #{key} -> #{destination}")
          {:ok, _} = @storage.copy_file(key, destination)
          {copied + 1, skipped}
        end
      end)

    say("\ncopied #{copied}, already present #{skipped}")
  end

  @doc """
  Checks that every root image has a copy under posts/ of the same size.
  """
  def verify do
    images = root_images()

    case mismatches(images) do
      [] ->
        say("all #{count(images)} copied and matching - safe to delete")

      mismatches ->
        Enum.each(mismatches, &report_mismatch/1)
        {:error, "#{length(mismatches)} of #{length(images)} object(s) failed verification"}
    end
  end

  @doc """
  Deletes the root originals. Does not ask - confirm before calling.
  """
  def delete do
    images = root_images()

    # Deleting the originals is the irreversible step, so re-check the copies
    # here rather than trusting that `verify/0` was run.
    case mismatches(images) do
      [] -> delete_all(images)
      [{key, _, _} | _] -> {:error, "#{key} is missing or a different size - run copy first"}
    end
  end

  defp delete_all(images) do
    keys = Enum.map(images, &elem(&1, 0))
    total = length(keys)

    keys
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.each(fn {batch, batch_number} ->
      {:ok, _} = @storage.delete_files(batch)
      say("deleted #{min(batch_number * @batch_size, total)}/#{total}")
    end)

    say("\ndeleted #{count(images)}")
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

  defp report_mismatch({key, expected, actual}) do
    found = if actual, do: bytes(actual), else: "absent"
    say("MISMATCH #{key}: expected #{bytes(expected)}, #{found}")
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

  # IO.puts rather than Mix.shell, so this works inside a release eval.
  defp say(message) do
    IO.puts(message)
  end
end
