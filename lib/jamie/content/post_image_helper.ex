defmodule Jamie.Content.PostImageHelper do
  @moduledoc """
  Helpers for working with images in posts.
  """

  @doc """
  Takes the markdown from a post and returns a list of the images contained
  """

  @spec md_images(String.t()) :: [String.t()]
  def md_images(markdown) do
    # build the regex
    ~r/!\[.*?\]\(https:\/\/media\.jamiecurle\.com\/(?<path>.+)\)/
    |> Regex.scan(markdown, capture: :all_names)
    |> List.flatten()
  end
end
