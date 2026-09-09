defmodule Mix.Tasks.R2.MovePostImagesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jamie.Support.FakeR2
  alias Mix.Tasks.R2.MovePostImages

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

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    :ok
  end

  defp keys, do: FakeR2.list_objects() |> Enum.map(&elem(&1, 0))

  # The task's @requirements would try to boot the app, so drive run/1's body
  # through Mix.Task.run's already-run bookkeeping instead.
  defp run(args) do
    capture_io(fn -> MovePostImages.run(args) end)
    drain_shell()
  end

  defp drain_shell(acc \\ []) do
    receive do
      {:mix_shell, :info, [message]} -> drain_shell([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  describe "plan" do
    test "lists only the root UUID images" do
      output = run(["plan"])

      assert output =~ "#{@uuid_png} -> posts/#{@uuid_png}"
      assert output =~ "#{@uuid_jpg} -> posts/#{@uuid_jpg}"
      assert output =~ "2 object(s)"

      for key <- @untouched, do: refute(output =~ "#{key} ->")
    end

    test "changes nothing" do
      before = keys()
      run(["plan"])

      assert keys() == before
    end
  end

  describe "copy" do
    test "copies the root images under posts/ and leaves the originals" do
      run(["copy"])

      assert "posts/#{@uuid_png}" in keys()
      assert "posts/#{@uuid_jpg}" in keys()
      assert @uuid_png in keys()
      assert @uuid_jpg in keys()
    end

    test "leaves everything that isn't a root UUID alone" do
      run(["copy"])

      for key <- @untouched, do: assert(key in keys())
      refute "posts/not-a-uuid.png" in keys()
      refute "posts/posts/9a9a9a9a-1111-2222-3333-444444444444.png" in keys()
    end

    test "skips images that have already been copied" do
      run(["copy"])
      output = run(["copy"])

      assert output =~ "copied 0, already present 2"
    end
  end

  describe "verify" do
    test "passes once everything has been copied" do
      run(["copy"])

      assert run(["verify"]) =~ "all 2 object(s) copied and matching"
    end

    test "reports a copy that is missing" do
      run(["copy"])
      FakeR2.delete_files(["posts/#{@uuid_png}"])

      capture_io(fn ->
        assert_raise Mix.Error, fn -> MovePostImages.run(["verify"]) end
      end)

      assert drain_shell() =~ "MISMATCH posts/#{@uuid_png}"
    end

    test "reports a copy whose size doesn't match" do
      run(["copy"])
      FakeR2.put_file("truncated", "posts/#{@uuid_png}")

      capture_io(fn ->
        assert_raise Mix.Error, fn -> MovePostImages.run(["verify"]) end
      end)

      assert drain_shell() =~ "MISMATCH posts/#{@uuid_png}"
    end
  end

  describe "delete" do
    test "removes the originals once they've been copied" do
      run(["copy"])
      run(["delete", "--yes"])

      refute @uuid_png in keys()
      refute @uuid_jpg in keys()
      assert "posts/#{@uuid_png}" in keys()
      assert "posts/#{@uuid_jpg}" in keys()
    end

    test "leaves everything that isn't a root UUID alone" do
      run(["copy"])
      run(["delete", "--yes"])

      for key <- @untouched, do: assert(key in keys())
    end

    test "refuses to delete when the copies aren't there" do
      capture_io(fn ->
        assert_raise Mix.Error, fn -> MovePostImages.run(["delete", "--yes"]) end
      end)

      assert @uuid_png in keys()
      assert @uuid_jpg in keys()
    end
  end

  test "an unknown sub-command explains itself rather than doing anything" do
    capture_io(fn ->
      assert_raise Mix.Error, ~r/Usage: mix r2.move_post_images/, fn ->
        MovePostImages.run(["oops"])
      end
    end)

    assert @uuid_png in keys()
  end
end
