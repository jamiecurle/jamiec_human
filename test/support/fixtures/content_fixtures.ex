defmodule Jamie.Support.ContentFixtures do
  @moduledoc """
  Fixtures for the content context.
  """

  import Ecto.Query

  alias Jamie.Content
  alias Jamie.Content.Bookmark
  alias Jamie.Repo

  def markdown_with_images do
    """
    "# Hello, World!
    ![2018.jpeg](https://media.jamiecurle.com/somepath/7ef11ccb-0347-4f38-920f-3889d837fdf4.jpeg)


    Here's a list of some great ideas
    * test the thing
    * deploy the thing
    * use the thing

    ![2020.jpeg](https://media.jamiecurle.com/1ed61e8a-09e8-47e8-95fa-fad1c1c471d1.jpeg)

    """
  end

  def markdown_with_images_from_jc_and_others do
    """
    "# Hello, World!
    ![2018.jpeg](https://media.jamiecurle.com/somepath/7ef11ccb-0347-4f38-920f-3889d837fdf4.jpeg)


    Here's a list of some great ideas
    * test the thing
    * deploy the thing
    * use the thing


    ![2020.jpeg](https://media.not-jamiecurle.com/1ed61e8a-09e8-47e8-95fa-fad1c1c471d1.jpeg)

    """
  end

  @default_note_attrs [
    title: "Basic note",
    markdown: """
    # Hello, World!
    Here's a list of some great ideas
    * test the thing
    * deploy the thing
    * use the thing
    """,
    status: :draft
  ]

  def note_attrs(opts \\ []) do
    @default_note_attrs
    |> Keyword.merge(opts)
    |> Map.new()

    # |> IO.inspect(label: "attrs")
  end

  @default_post_attrs [
    title: "Basic post",
    description: "A lovely description",
    markdown: """
    # Hello, World!
    Here's a list of some great ideas
    * test the thing
    * deploy the thing
    * use the thing
    """,
    status: :draft
  ]

  def post_attrs(opts \\ []) do
    @default_post_attrs
    |> Keyword.merge(opts)
    |> Map.new()
  end

  @default_bookmark_attrs [
    id: 1,
    title: "Some bookmark",
    url: "https://example.com",
    description: "A lovely bookmark",
    favicon: "https://example.com/favicon.ico",
    preview: "https://example.com/preview.png"
  ]

  def bookmark_attrs(opts \\ []) do
    @default_bookmark_attrs
    |> Keyword.merge(opts)
    |> Map.new()
  end

  @doc """
  Generate a bookmark.

  `inserted_at` is a `timestamps()` autofield, so it can't be set through the
  changeset. Pass it in `attrs` and we stamp it directly after insert for tests
  that need a fixed sync date.
  """
  def bookmark_fixture(attrs \\ %{}) do
    {inserted_at, attrs} =
      attrs
      |> Enum.into(bookmark_attrs())
      |> Map.pop(:inserted_at)

    {:ok, bookmark} = Content.create_bookmark(attrs)

    bookmark = maybe_backdate(bookmark, inserted_at)
    {:ok, bookmark}
  end

  defp maybe_backdate(bookmark, nil), do: bookmark

  defp maybe_backdate(bookmark, inserted_at) do
    from(b in Bookmark, where: b.id == ^bookmark.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    Repo.get!(Bookmark, bookmark.id)
  end
end
