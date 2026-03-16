defmodule Membrane.SRTLT.SinkSmokeTest do
  use ExUnit.Case, async: false

  alias Membrane.Testing.MockResourceGuard
  alias Membrane.SRTLT.Sink
  require Membrane.Pad

  @process_cleanup_tag :srtlt_sink_process_cleanup

  test "starts srt-live-transmit with correct args, writes stdin data, and closes on EOS" do
    {tmp_dir, _executable_path, args_path, stdin_path} = create_fake_srt_live_transmit!()
    previous_path = System.get_env("PATH") || ""

    System.put_env("PATH", "#{tmp_dir}:#{previous_path}")

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf(tmp_dir)
    end)

    resource_guard = MockResourceGuard.start_link_supervised!()

    opts = %{
      host: "127.0.0.1",
      port: 9711,
      mode: :caller,
      latency_ms: 400,
      peer_latency_ms: nil,
      rcv_latency_ms: nil,
      transtype: "live",
      stream_id: "smoke-sink",
      passphrase: "verysecret1234",
      chunk_size_bytes: 1316,
      buffering_packets: 10,
      telemetry_prefix: [:membrane, :srtlt]
    }

    {[], state} = Sink.handle_init(%{}, opts)
    {[], state} = Sink.handle_setup(%{resource_guard: resource_guard}, state)

    assert %{command_ref: %{ospid: _ospid}} = state

    assert_receive {MockResourceGuard, ^resource_guard,
                    {:register, {_cleanup_fun, @process_cleanup_tag}}},
                   1_000

    # Verify CLI args
    args = read_file_with_retry!(args_path, 2_000)

    assert args =~ "-chunk:1316"
    assert args =~ "-buffering:10"
    assert args =~ "-autoreconnect no"
    assert args =~ "-srctime yes"
    assert args =~ "-loglevel warn"
    assert args =~ "-pf json"
    assert args =~ "-statsout /dev/stderr"

    # Verify file://con comes before the SRT URI (source=stdin, target=srt)
    file_con_pos = :binary.match(args, "file://con") |> elem(0)
    srt_uri_pos = :binary.match(args, "srt://") |> elem(0)
    assert file_con_pos < srt_uri_pos

    # Verify URI parameters
    assert args =~ "mode=caller"
    assert args =~ "latency=400"
    assert args =~ "peerlatency=400"
    assert args =~ "rcvlatency=400"
    assert args =~ "transtype=live"
    assert args =~ "streamid=smoke-sink"
    assert args =~ "passphrase=verysecret1234"

    # Write data via handle_buffer
    {[], state} =
      Sink.handle_buffer(
        :input,
        %Membrane.Buffer{payload: "hello-srt"},
        %{},
        state
      )

    {[], state} =
      Sink.handle_buffer(
        :input,
        %Membrane.Buffer{payload: "-world"},
        %{},
        state
      )

    # Send EOS
    {[], state} =
      Sink.handle_end_of_stream(
        Membrane.Pad.ref(:input, 0),
        %{resource_guard: resource_guard},
        state
      )

    assert state.eos_received?

    # Wait for process to exit (it reads stdin until EOF then exits)
    assert_receive {:DOWN, _, :process, _, _}, 2_000

    # Verify stdin data was received by the fake script
    stdin_data = read_file_with_retry!(stdin_path, 2_000)
    assert stdin_data == "hello-srt-world"
  end

  test "listener mode URI uses mode=listener" do
    {tmp_dir, _executable_path, args_path, _stdin_path} = create_fake_srt_live_transmit!()
    previous_path = System.get_env("PATH") || ""

    System.put_env("PATH", "#{tmp_dir}:#{previous_path}")

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf(tmp_dir)
    end)

    resource_guard = MockResourceGuard.start_link_supervised!()

    opts = %{
      host: "127.0.0.1",
      port: 9712,
      mode: :listener,
      latency_ms: 200,
      peer_latency_ms: 100,
      rcv_latency_ms: 300,
      transtype: "live",
      stream_id: nil,
      passphrase: nil,
      chunk_size_bytes: 1316,
      buffering_packets: 10,
      telemetry_prefix: nil
    }

    {[], state} = Sink.handle_init(%{}, opts)
    {[], state} = Sink.handle_setup(%{resource_guard: resource_guard}, state)

    args = read_file_with_retry!(args_path, 2_000)

    assert args =~ "mode=listener"
    assert args =~ "latency=200"
    assert args =~ "peerlatency=100"
    assert args =~ "rcvlatency=300"
    refute args =~ "streamid"
    refute args =~ "passphrase"

    # Cleanup
    Sink.handle_terminate_request(%{resource_guard: resource_guard}, state)
  end

  # -- Helpers --

  defp read_file_with_retry!(path, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_file_with_retry(path, deadline)
  end

  defp read_file_with_retry(path, deadline_ms) do
    case File.read(path) do
      {:ok, contents} ->
        contents

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          raise File.Error, reason: :enoent, action: "read file", path: path
        else
          Process.sleep(25)
          read_file_with_retry(path, deadline_ms)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp create_fake_srt_live_transmit! do
    unique = System.unique_integer([:positive, :monotonic])
    tmp_dir = Path.join(System.tmp_dir!(), "srtlt-sink-smoke-#{unique}")
    File.mkdir_p!(tmp_dir)

    executable_path = Path.join(tmp_dir, "srt-live-transmit")
    args_path = Path.join(tmp_dir, "args.txt")
    stdin_path = Path.join(tmp_dir, "stdin.bin")

    # Fake srt-live-transmit that:
    # 1. Writes args to args.txt
    # 2. Emits a "connected" message on stderr
    # 3. Reads stdin until EOF and writes to stdin.bin
    script = """
    #!/bin/sh
    printf '%s\\n' "$*" > "#{args_path}"
    printf 'SRT target connected\\n' 1>&2
    cat > "#{stdin_path}"
    """

    File.write!(executable_path, script)
    File.chmod!(executable_path, 0o755)

    {tmp_dir, executable_path, args_path, stdin_path}
  end
end
