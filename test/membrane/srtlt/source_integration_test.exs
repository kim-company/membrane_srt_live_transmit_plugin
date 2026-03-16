defmodule Membrane.SRTLT.SourceIntegrationTest do
  @moduledoc """
  Integration tests that require `srt-live-transmit` installed on the system.
  Run with: mix test --only integration
  """
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline

  @moduletag :integration

  @tag timeout: 15_000
  test "listener source receives data from a caller sender" do
    port = free_port!()

    # Start a pipeline with our Source in listener mode
    pipeline =
      Pipeline.start_link_supervised!(
        spec:
          child(:srt_source, %Membrane.SRTLT.Source{
            host: "127.0.0.1",
            port: port,
            mode: :listener,
            latency_ms: 120,
            transtype: "live",
            chunk_size_bytes: 1316,
            buffering_packets: 10
          })
          |> child(:sink, Membrane.Testing.Sink)
      )

    # Give the listener time to bind
    Process.sleep(500)

    # Spawn a caller that sends known data
    sender = spawn_sender!(port)

    # Assert we get connected notification
    assert_pipeline_notified(pipeline, :srt_source, {:source_state, :connected}, 5_000)

    # Assert we receive at least one buffer with data
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: payload}, 5_000)
    assert byte_size(payload) > 0

    # Stop the sender, expect disconnected + EOS
    stop_sender(sender)

    assert_pipeline_notified(pipeline, :srt_source, {:source_state, :disconnected}, 5_000)
    assert_end_of_stream(pipeline, :sink, :input, 5_000)

    Pipeline.terminate(pipeline)
  end

  @tag timeout: 15_000
  test "caller source receives data from a listener sender" do
    port = free_port!()

    # Start a sender in listener mode first
    sender = spawn_listener_sender!(port)

    # Give the listener time to bind
    Process.sleep(500)

    # Start our Source as caller
    pipeline =
      Pipeline.start_link_supervised!(
        spec:
          child(:srt_source, %Membrane.SRTLT.Source{
            host: "127.0.0.1",
            port: port,
            mode: :caller,
            latency_ms: 120,
            transtype: "live",
            chunk_size_bytes: 1316,
            buffering_packets: 10
          })
          |> child(:sink, Membrane.Testing.Sink)
      )

    assert_pipeline_notified(pipeline, :srt_source, {:source_state, :connected}, 5_000)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: payload}, 5_000)
    assert byte_size(payload) > 0

    stop_sender(sender)

    assert_pipeline_notified(pipeline, :srt_source, {:source_state, :disconnected}, 5_000)
    assert_end_of_stream(pipeline, :sink, :input, 5_000)

    Pipeline.terminate(pipeline)
  end

  # -- Helpers --

  defp free_port! do
    {:ok, socket} = :gen_tcp.listen(0, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp spawn_sender!(port, mode \\ :caller) do
    executable =
      System.find_executable("srt-live-transmit") || raise "srt-live-transmit not found"

    uri = "srt://127.0.0.1:#{port}?mode=#{mode}&latency=120&transtype=live"

    # Use exec with a process group so we can kill the entire pipeline (dd + srt-live-transmit).
    # The sender uses -chunk:1316 and payloadsize=1316 to match the receiver.
    {:ok, pid, ospid} =
      :exec.run(
        [
          "/bin/sh",
          "-c",
          "while true; do dd if=/dev/urandom bs=1316 count=1 2>/dev/null; sleep 0.05; done | #{executable} -chunk:1316 -loglevel error file://con \"#{uri}&payloadsize=1316\""
        ],
        [:monitor, :kill_group, {:kill_timeout, 2}, {:group, 0}]
      )

    %{pid: pid, ospid: ospid}
  end

  defp spawn_listener_sender!(port), do: spawn_sender!(port, :listener)

  defp stop_sender(%{ospid: ospid}) do
    _ = :exec.stop(ospid)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
