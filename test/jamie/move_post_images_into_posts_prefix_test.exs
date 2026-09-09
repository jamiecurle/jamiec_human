defmodule Jamie.MovePostImagesIntoPostsPrefixTest do
  use ExUnit.Case, async: true

  # Migrations aren't on the compile path, so load it by hand - unless the test
  # database has already been brought up to date, which loads it for us and
  # would otherwise warn about the module being redefined.
  unless Code.ensure_loaded?(Jamie.Repo.Migrations.MovePostImagesIntoPostsPrefix) do
    Code.require_file(
      "../../priv/repo/migrations/20260909090000_move_post_images_into_posts_prefix.exs",
      __DIR__
    )
  end

  alias Jamie.Repo.Migrations.MovePostImagesIntoPostsPrefix, as: Migration

  @uuid "0f0d4bb4-1f2a-4a3c-9a41-6a2b7c8d9e01"

  describe "add_prefix/1" do
    test "moves a root-level markdown image under posts/" do
      markdown = "![a photo](https://media.jamiecurle.com/#{@uuid}.png)"

      assert Migration.add_prefix(markdown) ==
               "![a photo](https://media.jamiecurle.com/posts/#{@uuid}.png)"
    end

    test "moves a resized html src under posts/, keeping the resizer params" do
      html =
        ~s(<img src="https://media.jamiecurle.com/cdn-cgi/image/width=1200,format=auto,quality=85/#{@uuid}.png" alt="a photo">)

      assert Migration.add_prefix(html) ==
               ~s(<img src="https://media.jamiecurle.com/cdn-cgi/image/width=1200,format=auto,quality=85/posts/#{@uuid}.png" alt="a photo">)
    end

    test "leaves images that are already under posts/ alone" do
      markdown = "![a photo](https://media.jamiecurle.com/posts/#{@uuid}.png)"

      assert Migration.add_prefix(markdown) == markdown
    end

    test "leaves opengraph and other prefixed images alone" do
      markdown = """
      ![og](https://media.jamiecurle.com/opengraph/cf69675124bddb8f7a455e7da5505f93.png)
      ![favicon](https://media.jamiecurle.com/bookmarks/example.com/favicon.ico)
      """

      assert Migration.add_prefix(markdown) == markdown
    end

    test "rewrites every image in a post, not just the first" do
      markdown = """
      ![one](https://media.jamiecurle.com/#{@uuid}.png)
      ![two](https://media.jamiecurle.com/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d.jpg)
      """

      assert Migration.add_prefix(markdown) == """
             ![one](https://media.jamiecurle.com/posts/#{@uuid}.png)
             ![two](https://media.jamiecurle.com/posts/1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d.jpg)
             """
    end

    test "is idempotent" do
      markdown = "![a photo](https://media.jamiecurle.com/#{@uuid}.png)"
      once = Migration.add_prefix(markdown)

      assert Migration.add_prefix(once) == once
    end

    test "handles a post with no markdown or html yet" do
      assert Migration.add_prefix(nil) == nil
    end
  end

  describe "remove_prefix/1" do
    test "is the inverse of add_prefix/1 for markdown and html" do
      markdown = "![a photo](https://media.jamiecurle.com/#{@uuid}.png)"

      html =
        ~s(<img src="https://media.jamiecurle.com/cdn-cgi/image/width=1200,format=auto,quality=85/#{@uuid}.png">)

      assert markdown |> Migration.add_prefix() |> Migration.remove_prefix() == markdown
      assert html |> Migration.add_prefix() |> Migration.remove_prefix() == html
    end

    test "leaves opengraph images alone" do
      markdown = "![og](https://media.jamiecurle.com/opengraph/#{@uuid}.png)"

      assert Migration.remove_prefix(markdown) == markdown
    end

    test "handles nil" do
      assert Migration.remove_prefix(nil) == nil
    end
  end
end
