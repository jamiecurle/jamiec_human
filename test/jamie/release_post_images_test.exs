defmodule Jamie.ReleasePostImagesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jamie.Release
  alias Jamie.Support.FakeR2

  @uuid_png "0f0d4bb4-1f2a-4a3c-9a41-6a2b7c8d9e01.png"

  setup do
    FakeR2.put_file("contents", @uuid_png)
    :ok
  end

  defp keys, do: FakeR2.list_objects() |> Enum.map(&elem(&1, 0))

  test "copy moves the objects" do
    capture_io(fn -> assert Release.move_post_images("copy") == :ok end)

    assert "posts/#{@uuid_png}" in keys()
  end

  test "delete needs the --yes, because an eval cannot prompt" do
    capture_io(fn -> Release.move_post_images("copy") end)

    assert_raise RuntimeError, ~r/unknown command "delete"/, fn ->
      Release.move_post_images("delete")
    end

    assert @uuid_png in keys()

    capture_io(fn -> assert Release.move_post_images("delete --yes") == :ok end)

    refute @uuid_png in keys()
  end

  test "a failing step raises, so the eval exits non-zero" do
    capture_io(fn ->
      assert_raise RuntimeError, ~r/failed verification/, fn ->
        Release.move_post_images("verify")
      end
    end)
  end
end
