defmodule Jamie.Content.PostImageHelper.Test do
  use Jamie.DataCase, async: true

  alias Jamie.Content

  alias Jamie.Content.PostImageHelper
  alias Jamie.Support.ContentFixtures

  describe "r2_post_images" do
    test "ensure we don't include bookmark images or open graph" do
      # actually, infact, how about we just move everything over to  /posts/
      # so do that work and then come back and finish up here
    end
  end

  describe "md_images" do
    test "works as expected with jamiecurle.com and others" do
      # make a post
      {:ok, post} =
        ContentFixtures.post_attrs(
          status: :published,
          markdown: ContentFixtures.markdown_with_images_from_jc_and_others()
        )
        |> Content.create_post()

      # get the images
      images = PostImageHelper.md_images(post.markdown)

      # and it matches what we expect
      assert images == [
               "somepath/7ef11ccb-0347-4f38-920f-3889d837fdf4.jpeg"
             ]
    end

    test "works as expected with all jamiecurle.com" do
      # make a post
      {:ok, post} =
        ContentFixtures.post_attrs(
          status: :published,
          markdown: ContentFixtures.markdown_with_images()
        )
        |> Content.create_post()

      # get the images
      images = PostImageHelper.md_images(post.markdown)

      # and it matches what we expect
      assert images == [
               "somepath/7ef11ccb-0347-4f38-920f-3889d837fdf4.jpeg",
               "1ed61e8a-09e8-47e8-95fa-fad1c1c471d1.jpeg"
             ]
    end
  end
end
