defmodule Mix.Tasks.R2.MovePostImages do
  @shortdoc "Moves post images from the bucket root into the posts/ prefix"

  @moduledoc """
  Moves post images from the root of the R2 bucket into the posts/ prefix.

      mix r2.move_post_images plan     # what would move
      mix r2.move_post_images copy     # root -> posts/, originals kept
      mix r2.move_post_images verify   # every copy present and the same size
      mix ecto.migrate                 # now point the posts at the new URLs
      mix r2.move_post_images delete   # finally, drop the originals

  `delete` asks before doing the one irreversible thing; pass `--yes` to skip
  the prompt.

  Bucket and credentials come from the usual environment variables:
  CF_ACCESS_KEY_ID, CF_SECRET_ACCESS_KEY, CF_BUCKET and CF_S3_HOST.

  There is no mix in production. This is a convenience wrapper for running
  locally - see `Jamie.PostImages` for what it actually does, and
  `Jamie.Release.move_post_images/1` for the same thing from a release eval.
  """

  use Mix.Task

  alias Jamie.PostImages

  @requirements ["app.start"]

  @impl Mix.Task
  def run(["plan"]), do: report(PostImages.plan())
  def run(["copy"]), do: report(PostImages.copy())
  def run(["verify"]), do: report(PostImages.verify())
  def run(["delete", "--yes"]), do: report(PostImages.delete())

  def run(["delete"]) do
    if Mix.shell().yes?("Delete the originals from the bucket root?") do
      report(PostImages.delete())
    else
      Mix.raise("aborted")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix r2.move_post_images plan|copy|verify|delete [--yes]")
  end

  defp report(:ok), do: :ok
  defp report({:error, message}), do: Mix.raise(message)
end
