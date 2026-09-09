defmodule Jamie.Repo.Migrations.MovePostImagesIntoPostsPrefix do
  use Ecto.Migration
  import Ecto.Query

  # Post images used to be signed straight into the bucket root, so their public
  # URLs look like https://media.jamiecurle.com/<uuid>.png. Since the "upload
  # posts into /posts/" change new uploads land under posts/, and the objects for
  # older posts are being copied there too - so the URLs already stored in the
  # database have to follow.
  #
  # Two columns need it. `markdown` holds the URL exactly as it was inserted by
  # the editor. `html` is a stored render of that markdown, and by the time it is
  # saved Jamie.Markdown.rewrite_image_urls/1 has pushed the src through the
  # Cloudflare resizer, so it reads
  #   https://media.jamiecurle.com/cdn-cgi/image/<params>/<uuid>.png
  # The optional cdn-cgi segment in the patterns below covers both shapes.
  #
  # Matching is anchored on a UUID sitting directly after the host (or after the
  # resizer params). That is the shape the uploader produces and nothing else
  # does, so opengraph/..., bookmark assets and anything already under posts/ are
  # all left alone - and re-running this is a no-op, because after the rewrite
  # the segment following the host is "posts", not a UUID.

  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @extension "[a-zA-Z0-9]+"

  def up, do: rewrite_posts(&add_prefix/1)

  def down, do: rewrite_posts(&remove_prefix/1)

  @doc """
  Rewrites root-level image URLs in `text` to sit under the posts/ prefix.
  """
  def add_prefix(nil), do: nil

  def add_prefix(text) do
    Regex.replace(
      ~r{(https://#{host()}/(?:cdn-cgi/image/[^/"\s]+/)?)(#{@uuid}\.#{@extension})},
      text,
      "\\1posts/\\2"
    )
  end

  @doc """
  The inverse of `add_prefix/1` - moves posts/ image URLs back to the root.
  """
  def remove_prefix(nil), do: nil

  def remove_prefix(text) do
    Regex.replace(
      ~r{(https://#{host()}/(?:cdn-cgi/image/[^/"\s]+/)?)posts/(#{@uuid}\.#{@extension})},
      text,
      "\\1\\2"
    )
  end

  defp host do
    Application.get_env(:jamie, :images)[:host]
    |> Regex.escape()
  end

  # Deliberately schemaless and changeset-free: running Post.changeset/2 here
  # would re-slugify the title and recompute og_hash as a side effect, which has
  # nothing to do with moving an image.
  defp rewrite_posts(fun) do
    from(p in "posts", select: {p.id, p.markdown, p.html})
    |> repo().all()
    |> Enum.each(fn {id, markdown, html} ->
      new_markdown = fun.(markdown)
      new_html = fun.(html)

      if {new_markdown, new_html} != {markdown, html} do
        from(p in "posts", where: p.id == ^id)
        |> repo().update_all(set: [markdown: new_markdown, html: new_html])
      end
    end)
  end
end
