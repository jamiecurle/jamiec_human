defmodule Jamie.PostImagesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jamie.PostImages
  alias Jamie.Support.FakeR2

  @uuid_png "0f0d4bb4-1f2a-4a3c-9a41-6a2b7c8d9e01.png"
  @uuid_jpg "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d.jpg"

  # Everything here that isn't a bare UUID in the root must survive untouched.
  @untouched [
    "posts/9a9a9a9a-1111-2222-3333-444444444444.png",
    "opengraph/cf69675124bddb8f7a455e7da5505f93.png",
    "bookmarks/example.com/favicon.ico",
    "not-a-uuid.png"
  ]

  setup do
    for key <- [@uuid_png, @uuid_jpg | @untouched] do
      FakeR2.put_file("contents of #{key}", key)
    end

    :ok
  end

  defp keys, do: FakeR2.list_objects() |> Enum.map(&elem(&1, 0))

  # Each step prints as it goes, so capture the output and the return value.
  # The result has to be posted back rather than rebound - an assignment inside
  # the capture_io closure doesn't escape it.
  defp run(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> {result, output}
    after
      0 -> flunk("the step under test never returned")
    end
  end

  describe "plan/0" do
    test "lists only the root UUID images" do
      {_result, output} = run(&PostImages.plan/0)

      assert output =~ "#{@uuid_png} -> posts/#{@uuid_png}"
      assert output =~ "#{@uuid_jpg} -> posts/#{@uuid_jpg}"
      assert output =~ "2 object(s)"

      for key <- @untouched, do: refute(output =~ "#{key} ->")
    end

    test "changes nothing" do
      before = keys()
      run(&PostImages.plan/0)

      assert keys() == before
    end
  end

  describe "copy/0" do
    test "copies the root images under posts/ and leaves the originals" do
      run(&PostImages.copy/0)

      assert "posts/#{@uuid_png}" in keys()
      assert "posts/#{@uuid_jpg}" in keys()
      assert @uuid_png in keys()
      assert @uuid_jpg in keys()
    end

    test "leaves everything that isn't a root UUID alone" do
      run(&PostImages.copy/0)

      for key <- @untouched, do: assert(key in keys())
      refute "posts/not-a-uuid.png" in keys()
      refute "posts/posts/9a9a9a9a-1111-2222-3333-444444444444.png" in keys()
    end

    test "skips images that have already been copied" do
      run(&PostImages.copy/0)
      {_result, output} = run(&PostImages.copy/0)

      assert output =~ "copied 0, already present 2"
    end
  end

  describe "verify/0" do
    test "passes once everything has been copied" do
      run(&PostImages.copy/0)
      {result, output} = run(&PostImages.verify/0)

      assert result == :ok
      assert output =~ "all 2 object(s) copied and matching"
    end

    test "reports a copy that is missing" do
      run(&PostImages.copy/0)
      FakeR2.delete_files(["posts/#{@uuid_png}"])

      {result, output} = run(&PostImages.verify/0)

      assert {:error, message} = result
      assert message =~ "1 of 2 object(s) failed verification"
      expected = byte_size("contents of #{@uuid_png}")
      assert output =~ "MISMATCH posts/#{@uuid_png}: expected #{expected} bytes, absent"
    end

    test "reports a copy whose size doesn't match" do
      run(&PostImages.copy/0)
      FakeR2.put_file("truncated", "posts/#{@uuid_png}")

      {result, output} = run(&PostImages.verify/0)

      assert {:error, _} = result
      assert output =~ "MISMATCH posts/#{@uuid_png}"
    end
  end

  describe "delete/0" do
    test "removes the originals once they've been copied" do
      run(&PostImages.copy/0)
      {result, _output} = run(&PostImages.delete/0)

      assert result == :ok
      refute @uuid_png in keys()
      refute @uuid_jpg in keys()
      assert "posts/#{@uuid_png}" in keys()
      assert "posts/#{@uuid_jpg}" in keys()
    end

    test "leaves everything that isn't a root UUID alone" do
      run(&PostImages.copy/0)
      run(&PostImages.delete/0)

      for key <- @untouched, do: assert(key in keys())
    end

    test "refuses to delete when the copies aren't there" do
      {result, _output} = run(&PostImages.delete/0)

      assert {:error, message} = result
      assert message =~ "run copy first"
      assert @uuid_png in keys()
      assert @uuid_jpg in keys()
    end

    test "refuses to delete when only some of the copies are there" do
      run(&PostImages.copy/0)
      FakeR2.delete_files(["posts/#{@uuid_jpg}"])

      {result, _output} = run(&PostImages.delete/0)

      assert {:error, _} = result
      assert @uuid_png in keys()
      assert @uuid_jpg in keys()
    end
  end
end
