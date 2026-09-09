defmodule Jamie.Content do
  @moduledoc """
  The content context boundary.
  """

  import Ecto.Query

  alias Jamie.Accounts.Scope
  alias Jamie.Content.Bookmark
  alias Jamie.Content.{Note, Post}
  alias Jamie.Content.PostImageHelper
  alias Jamie.Content.PostRevision
  alias Jamie.Repo
  alias Jamie.Workers.OgImageCreate

  @snapshot_every 50

  @doc """
  from all the posts in the database get the
  images
  """
  def all_images_in_all_posts do
    # get a nested list of all the images
    {:ok, nested_images} =
      Repo.transaction(fn ->
        Post
        |> select([p], p.markdown)
        |> Repo.stream()
        |> Stream.map(&PostImageHelper.md_images/1)
        |> Enum.to_list()
      end)

    # and now return a unique list
    nested_images
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  update note
  """
  def update_note(%Note{} = note, attrs) do
    case Note.changeset(note, attrs) do
      %{valid?: true} = changeset -> Repo.update(changeset)
      %Ecto.Changeset{} = cs -> {:error, cs}
    end
  end

  @doc """
  gets visible notes.

  Takes a scope and if the user on the scope is not nil then it will return
  all notes of all statuses.
  """
  def get_published_notes(scope \\ nil)

  def get_published_notes(%Scope{user: user}) when not is_nil(user) do
    from(n in Note,
      order_by: [desc: n.published_on]
    )
    |> Repo.all()
  end

  def get_published_notes(_scope) do
    from(n in Note,
      where: n.status == :published,
      order_by: [desc: n.published_on]
    )
    |> Repo.all()
  end

  @doc """
  gets a note for a given id
  """
  def get_note!(id) do
    Repo.get!(Note, id)
  end

  @doc """
  returns a changeset for a note
  """
  def change_note(%Note{} = note, attrs \\ %{}) do
    Note.changeset(note, attrs)
  end

  @doc """
  Creates a note
  """
  def create_note(attrs) do
    case change_note(%Note{}, attrs) do
      %{valid?: true} = changeset -> Repo.insert(changeset)
      changeset -> changeset
    end
  end

  @doc """
  returns a changeset for a post
  """
  def change_post(%Post{} = post, attrs \\ %{}) do
    Post.changeset(post, attrs)
  end

  @doc """
  Creates a post
  """
  def create_post(attrs) do
    case Post.changeset(%Post{}, attrs) do
      %{valid?: true} = changeset ->
        # Insert the post and schedule its og image in the same transaction so
        # the job is only enqueued if the post actually commits.
        Repo.transaction(fn ->
          post = Repo.insert!(changeset)
          schedule_og_image(post.id)
          post
        end)

      changeset ->
        changeset
    end
  end

  @doc """
  Gets a post by slug
  """
  def get_post_by_slug!(slug, %Scope{user: user}) when not is_nil(user) do
    Post
    |> where(slug: ^slug)
    |> Repo.one!()
  end

  def get_post_by_slug!(slug, nil), do: get_post_by_slug!(slug)

  def get_post_by_slug!(slug) do
    Post
    |> where(status: :published)
    |> where(slug: ^slug)
    |> preload(:tags)
    |> Repo.one!()
  end

  @doc """
  Gets a post by id
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
  end

  @doc """
  Updates a post without optimistic locking — the current row's
  `updated_at` is read fresh from the database. Use `update_post/3` from
  user-facing edit flows where stale-write detection matters.
  """
  def update_post(%Post{} = post, attrs) do
    current_updated_at = Repo.one!(from p in Post, where: p.id == ^post.id, select: p.updated_at)
    update_post(post, attrs, current_updated_at)
  end

  @doc """
  Updates a post, rejecting the write with `{:error, :conflict}` when the
  row's `updated_at` no longer matches `last_known_updated_at`. The post
  update and the revision insert run in the same transaction.
  """
  def update_post(%Post{} = post, attrs, last_known_updated_at) do
    changeset = Post.changeset(post, attrs)

    with %{valid?: true} <- changeset,
         {:ok, applied} <- Ecto.Changeset.apply_action(changeset, :update) do
      do_update_with_revision(post, applied, last_known_updated_at)
    else
      %Ecto.Changeset{} = invalid ->
        {:error, %{invalid | action: :update}}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  end

  defp do_update_with_revision(%Post{} = post, %Post{} = applied, last_known_updated_at) do
    # we need the current time and boolean of whether or not the hash has changed
    now = DateTime.utc_now()
    og_hash_changed? = post.og_hash != applied.og_hash

    updates =
      applied
      |> Map.take(Post.fields())
      |> Map.to_list()
      |> Keyword.put(:updated_at, now)

    result =
      Repo.transaction(fn ->
        # update the post
        updated_post = commit_post_update(post.id, last_known_updated_at, updates, applied)

        # only regenerate the og image when the hash actually changed
        if og_hash_changed?, do: schedule_og_image(updated_post.id)

        updated_post
      end)

    # lovely, handle the result and we're done.
    # Remember to broadcast the change on the post to
    # update the post to the latest version for everyone.
    case result do
      {:ok, updated_post} ->
        Phoenix.PubSub.broadcast(
          Jamie.PubSub,
          "post:#{updated_post.id}",
          {:post_updated, updated_post}
        )

        {:ok, updated_post}

      {:error, _} = err ->
        err
    end
  end

  # Enqueue the og image worker a little in the future. The delay gives the
  # post time to settle (and lets rapid successive edits dedupe via the worker's
  # uniqueness window) before we spend effort rendering the image.
  defp schedule_og_image(post_id) do
    %{thing: "post", id: post_id}
    |> OgImageCreate.new(scheduled_at: DateTime.add(DateTime.utc_now(), 20, :second))
    |> Oban.insert!()
  end

  defp commit_post_update(post_id, last_known_updated_at, updates, applied) do
    {count, _} =
      from(p in Post,
        where: p.id == ^post_id and p.updated_at == ^last_known_updated_at
      )
      |> Repo.update_all(set: updates)

    if count == 0, do: Repo.rollback(:conflict), else: finalise_post_update(post_id, applied)
  end

  defp finalise_post_update(post_id, applied) do
    case do_save_revision(post_id, applied.markdown) do
      {:ok, _} -> Repo.get!(Post, post_id)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Gets published posts ordered by published date descending
  """

  def published_posts(%Scope{user: user}) when not is_nil(user) do
    from(p in Post, order_by: [desc: p.published_on])
    |> Repo.all()
  end

  def published_posts(nil) do
    from(p in Post, where: p.status == :published, order_by: [desc: p.published_on])
    |> Repo.all()
  end

  def published_posts do
    from(p in Post, where: p.status == :published, order_by: [desc: p.published_on])
    |> Repo.all()
  end

  @doc """
  Returns the N most recently published posts.
  """
  def latest_published_posts(n) when is_integer(n) and n >= 0 do
    from(p in Post,
      where: p.status == :published,
      order_by: [desc: p.published_on],
      limit: ^n
    )
    |> Repo.all()
  end

  @doc """
  Gets all posts order by date descending
  """
  def all_posts do
    from(p in Post)
    |> order_by(desc: :id)
    |> Repo.all()
  end

  # ----------------------------------------------------------------------
  # Revisions
  # ----------------------------------------------------------------------

  @doc """
  Records a revision for `post_id` containing `new_content`.

  Stores a `diffy` diff against the previous revision, except when there
  is no previous revision, the new revision number is a multiple of
  #{@snapshot_every}, or the serialised diff would be larger than the
  content itself — in which case a full snapshot is stored instead.

  Returns `:ok` if the content is unchanged from the latest revision.
  """
  def save_revision(_current_scope, post_id, new_content) when is_binary(new_content) do
    Repo.transaction(fn ->
      case do_save_revision(post_id, new_content) do
        {:ok, rev_or_nil} -> rev_or_nil
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, nil} -> :ok
      {:ok, %PostRevision{} = rev} -> {:ok, rev}
      {:error, _} = err -> err
    end
  end

  # Returns `{:ok, nil}` when content matches the latest revision (no-op),
  # `{:ok, %PostRevision{}}` on insert, or `{:error, _}`.
  defp do_save_revision(post_id, new_content) do
    last = latest_revision(post_id)

    if last && reconstruct_from(last) == new_content do
      {:ok, nil}
    else
      insert_revision(post_id, last, new_content)
    end
  end

  defp latest_revision(post_id) do
    from(r in PostRevision,
      where: r.post_id == ^post_id,
      order_by: [desc: r.saved_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp insert_revision(post_id, last, new_content) do
    next_number = (last && last.revision_number + 1) || 1
    diff = if last, do: :diffy.diff(reconstruct_from(last), new_content), else: nil

    snapshot? =
      is_nil(last) or
        rem(next_number, @snapshot_every) == 0 or
        diff_payload_size(diff) > byte_size(new_content)

    payload =
      if snapshot?,
        do: %{is_snapshot: true, snapshot: new_content, diff: nil},
        else: %{is_snapshot: false, snapshot: nil, diff: encode_diff(diff)}

    attrs = Map.merge(payload, %{post_id: post_id, saved_at: DateTime.utc_now()})

    %PostRevision{}
    |> PostRevision.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Reconstructs the content as it stood at the given revision id.
  """
  def reconstruct_content(_current_scope, post_revision_id) do
    target = Repo.get!(PostRevision, post_revision_id)
    reconstruct_target(target)
  end

  defp reconstruct_target(%PostRevision{is_snapshot: true, snapshot: snapshot}) do
    snapshot
  end

  defp reconstruct_target(%PostRevision{} = target) do
    snapshot =
      from(r in PostRevision,
        where:
          r.post_id == ^target.post_id and
            r.is_snapshot == true and
            r.saved_at <= ^target.saved_at,
        order_by: [desc: r.saved_at],
        limit: 1
      )
      |> Repo.one!()

    diffs =
      from(r in PostRevision,
        where:
          r.post_id == ^target.post_id and
            r.saved_at > ^snapshot.saved_at and
            r.saved_at <= ^target.saved_at,
        order_by: [asc: r.saved_at]
      )
      |> Repo.all()

    Enum.reduce(diffs, snapshot.snapshot, fn rev, acc ->
      apply_diff(acc, decode_diff(rev.diff))
    end)
  end

  # When reconstructing from the latest known revision (used by save_revision
  # to detect no-op saves), we already have the row in hand — avoid a roundtrip.
  defp reconstruct_from(%PostRevision{is_snapshot: true, snapshot: snapshot}), do: snapshot
  defp reconstruct_from(%PostRevision{} = rev), do: reconstruct_target(rev)

  @doc """
  Lists all revisions for a post, ordered by `saved_at` descending. A
  consuming LiveView should render this collection via `stream/3`.
  """
  def list_revisions(_current_scope, post_id) do
    from(r in PostRevision,
      where: r.post_id == ^post_id,
      order_by: [desc: r.saved_at]
    )
    |> Repo.all()
  end

  @doc """
  Assigns `name` to a revision. If the revision is a diff, it is promoted
  to a snapshot in the same transaction: the content is reconstructed and
  stored, `is_snapshot` is set to true, and the diff is cleared.
  """
  def name_revision(_current_scope, post_revision_id, name) do
    Repo.transaction(fn ->
      rev = Repo.get!(PostRevision, post_revision_id)

      attrs =
        if rev.is_snapshot do
          %{name: name}
        else
          %{
            name: name,
            is_snapshot: true,
            snapshot: reconstruct_target(rev),
            diff: nil
          }
        end

      rev
      |> PostRevision.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} -> updated
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  # ----------------------------------------------------------------------
  # diffy interop
  # ----------------------------------------------------------------------

  defp encode_diff(diff) when is_list(diff) do
    diff
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  defp decode_diff(encoded) when is_binary(encoded) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  # `:diffy` diffs embed the destination text, so reconstruction does not
  # need the previous content — `_prev` is threaded only to make the fold
  # in `reconstruct_target/1` explicit.
  defp apply_diff(_prev, diff) when is_list(diff) do
    :diffy.destination_text(diff)
  end

  # Size of the "change" portion of a diff: bytes inserted + bytes deleted,
  # ignoring `equal` segments. This is what we compare against the new
  # content when deciding to snapshot — the encoded diff itself carries the
  # equal segments verbatim plus serialisation overhead, so it would
  # otherwise be larger than the content on almost every save.
  defp diff_payload_size(nil), do: 0

  defp diff_payload_size(diff) when is_list(diff) do
    Enum.reduce(diff, 0, fn
      {:equal, _}, acc -> acc
      {_op, data}, acc -> acc + byte_size(data)
    end)
  end

  @doc """
  Subscribes to notifications about any bookmark changes.

  The broadcasted messages match the pattern:

    * {:created, %Bookmark{}}
    * {:updated, %Bookmark{}}
    * {:deleted, %Bookmark{}}

  """
  def subscribe_bookmarks do
    Phoenix.PubSub.subscribe(Jamie.PubSub, "bookmarks")
  end

  defp broadcast_bookmark(message) do
    Phoenix.PubSub.broadcast(Jamie.PubSub, "bookmarks", message)
  end

  @doc """
  Returns the list of bookmarks.

  ## Examples

      iex> list_bookmarks()
      [%Bookmark{}, ...]

  """
  def list_bookmarks do
    Repo.all(Bookmark)
  end

  @doc """
  Gets a single bookmark.

  Raises `Ecto.NoResultsError` if the Bookmark does not exist.

  ## Examples

      iex> get_bookmark!(123)
      %Bookmark{}

      iex> get_bookmark!(456)
      ** (Ecto.NoResultsError)

  """
  def get_bookmark!(id) do
    Repo.get!(Bookmark, id)
  end

  @doc """
  Creates a bookmark.

  ## Examples

      iex> create_bookmark(%{field: value})
      {:ok, %Bookmark{}}

      iex> create_bookmark(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_bookmark(attrs) do
    with {:ok, bookmark = %Bookmark{}} <-
           %Bookmark{}
           |> Bookmark.changeset(attrs)
           |> Repo.insert(
             on_conflict: {:replace_all_except, [:id, :inserted_at]},
             conflict_target: :url
           ) do
      broadcast_bookmark({:created, bookmark})
      {:ok, bookmark}
    end
  end

  @doc """
  Updates a bookmark.

  ## Examples

      iex> update_bookmark(bookmark, %{field: new_value})
      {:ok, %Bookmark{}}

      iex> update_bookmark(bookmark, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_bookmark(%Bookmark{} = bookmark, attrs) do
    with {:ok, bookmark = %Bookmark{}} <-
           bookmark
           |> Bookmark.changeset(attrs)
           |> Repo.update() do
      broadcast_bookmark({:updated, bookmark})
      {:ok, bookmark}
    end
  end

  @doc """
  Deletes a bookmark.

  ## Examples

      iex> delete_bookmark(bookmark)
      {:ok, %Bookmark{}}

      iex> delete_bookmark(bookmark)
      {:error, %Ecto.Changeset{}}

  """
  def delete_bookmark(%Bookmark{} = bookmark) do
    with {:ok, bookmark = %Bookmark{}} <-
           Repo.delete(bookmark) do
      broadcast_bookmark({:deleted, bookmark})
      {:ok, bookmark}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking bookmark changes.

  ## Examples

      iex> change_bookmark(bookmark)
      %Ecto.Changeset{data: %Bookmark{}}

  """
  def change_bookmark(%Bookmark{} = bookmark, attrs \\ %{}) do
    Bookmark.changeset(bookmark, attrs)
  end
end
