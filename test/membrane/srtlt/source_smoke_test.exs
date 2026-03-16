defmodule Membrane.SRTLT.SourceSmokeTest do
  use ExUnit.Case, async: false

  alias Membrane.Testing.MockResourceGuard
  alias Membrane.SRTLT.Source

  @process_cleanup_tag :srtlt_source_process_cleanup

  test "starts srt-live-transmit, emits connected notification, and closes cleanly" do
    {tmp_dir, _executable_path, args_path} = create_fake_srt_live_transmit!()
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
      stream_id: "smoke-stream",
      passphrase: "verysecret1234",
      chunk_size_bytes: 1316,
      buffering_packets: 10,
      telemetry_prefix: [:membrane, :srtlt]
    }

    {[], state} = Source.handle_init(%{}, opts)
    {[], state} = Source.handle_setup(%{resource_guard: resource_guard}, state)

    assert %{command_ref: %{ospid: ospid}} = state

    assert_receive {MockResourceGuard, ^resource_guard,
                    {:register, {_cleanup_fun, @process_cleanup_tag}}},
                   1_000

    _ = maybe_drain_stderr(ospid)

    # Verify CLI args written by fake script
    args = read_file_with_retry!(args_path, 2_000)

    assert args =~ "-chunk:1316"
    assert args =~ "-buffering:10"
    assert args =~ "-autoreconnect no"
    assert args =~ "-srctime yes"
    assert args =~ "-loglevel warn"
    assert args =~ "-pf json"
    assert args =~ "file://con"
    assert args =~ "-statsout /dev/stderr"

    # Verify URI parameters
    assert args =~ "mode=caller"
    assert args =~ "latency=400"
    assert args =~ "peerlatency=400"
    assert args =~ "rcvlatency=400"
    assert args =~ "transtype=live"
    assert args =~ "streamid=smoke-stream"
    assert args =~ "passphrase=verysecret1234"

    # Simulate receiving stdout data
    payload = "smoke-ts-payload"

    {actions, state} =
      Source.handle_info(
        {:stdout, ospid, payload},
        %{playback: :playing},
        state
      )

    assert [
             notify_parent: {:source_state, :connected},
             buffer: {:output, %Membrane.Buffer{payload: ^payload}}
           ] = actions

    # Close gracefully
    {actions, state} =
      Source.handle_parent_notification(
        :close,
        %{resource_guard: resource_guard},
        state
      )

    assert [end_of_stream: :output] = actions
    assert state.eos_sent?

    # Idempotent close
    {actions, _state} =
      Source.handle_parent_notification(
        :close,
        %{resource_guard: resource_guard},
        state
      )

    assert actions == []
  end

  test "peer_latency_ms and rcv_latency_ms override latency_ms in URI" do
    {tmp_dir, _executable_path, args_path} = create_fake_srt_live_transmit!()
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
      mode: :listener,
      latency_ms: 350,
      peer_latency_ms: 200,
      rcv_latency_ms: 500,
      transtype: "live",
      stream_id: nil,
      passphrase: nil,
      chunk_size_bytes: 1316,
      buffering_packets: 10,
      telemetry_prefix: [:membrane, :srtlt]
    }

    {[], state} = Source.handle_init(%{}, opts)
    {[], state} = Source.handle_setup(%{resource_guard: resource_guard}, state)

    assert %{command_ref: %{ospid: _ospid}} = state

    args = read_file_with_retry!(args_path, 2_000)

    assert args =~ "latency=350"
    assert args =~ "peerlatency=200"
    assert args =~ "rcvlatency=500"
    assert args =~ "mode=listener"
    refute args =~ "streamid"
    refute args =~ "passphrase"

    # Cleanup
    Source.handle_parent_notification(:close, %{resource_guard: resource_guard}, state)
  end

  # -- Helpers --

  defp maybe_drain_stderr(ospid) do
    receive do
      {:stderr, ^ospid, _payload} -> :ok
    after
      200 -> :ok
    end
  end

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
    tmp_dir = Path.join(System.tmp_dir!(), "srtlt-source-smoke-#{unique}")
    File.mkdir_p!(tmp_dir)

    executable_path = Path.join(tmp_dir, "srt-live-transmit")
    args_path = Path.join(tmp_dir, "args.txt")

    script = """
    #!/bin/sh
    printf '%s\\n' "$*" > "#{args_path}"
    printf '{"send":{"bytes":1},"recv":{"bytes":1}}\\n' 1>&2
    printf 'smoke-ts-payload'
    while true; do
      sleep 1
    done
    """

    File.write!(executable_path, script)
    File.chmod!(executable_path, 0o755)

    {tmp_dir, executable_path, args_path}
  end
end
