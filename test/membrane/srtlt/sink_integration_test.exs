defmodule Membrane.SRTLT.SinkIntegrationTest do
  @moduledoc """
  Integration tests for the Sink element with real srt-live-transmit.
  Run with: mix test --only integration
  """
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline
  alias Membrane.SRTLT.Test.SenderPipeline

  @moduletag :integration

  defp buffer_list(payload, count) do
    Enum.map(1..count, fn _ -> %Membrane.Buffer{payload: payload} end)
  end

  @tag timeout: 15_000
  test "caller sink sends data that arrives at listener source" do
    port = free_port!()
    payload = String.duplicate("A", 1316)

    # Receiver: Source (listener) starts first
    receiver =
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

    Process.sleep(500)

    # Sender: Sink connects as caller, source linked after connection
    {:ok, _sup, sender} =
      SenderPipeline.start_link(
        sink_opts: %Membrane.SRTLT.Sink{
          host: "127.0.0.1",
          port: port,
          mode: :caller,
          latency_ms: 120,
          transtype: "live",
          chunk_size_bytes: 1316,
          buffering_packets: 10
        },
        source_opts: %Membrane.Testing.Source{
          output: buffer_list(payload, 200),
          stream_format: %Membrane.RemoteStream{}
        },
        test_process: self()
      )

    assert_receive {:sender_pipeline, ^sender, {:sink_state, :connected}}, 5_000
    assert_sink_buffer(receiver, :sink, %Membrane.Buffer{payload: _}, 10_000)

    Pipeline.terminate(sender)
    Pipeline.terminate(receiver)
  end

  @tag timeout: 15_000
  test "listener sink sends data that arrives at caller source" do
    port = free_port!()
    payload = String.duplicate("B", 1316)

    # Sender: Sink listens, source linked after connection
    {:ok, _sup, sender} =
      SenderPipeline.start_link(
        sink_opts: %Membrane.SRTLT.Sink{
          host: "127.0.0.1",
          port: port,
          mode: :listener,
          latency_ms: 120,
          transtype: "live",
          chunk_size_bytes: 1316,
          buffering_packets: 10
        },
        source_opts: %Membrane.Testing.Source{
          output: buffer_list(payload, 200),
          stream_format: %Membrane.RemoteStream{}
        },
        test_process: self()
      )

    Process.sleep(500)

    # Receiver: Source connects as caller
    receiver =
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

    assert_receive {:sender_pipeline, ^sender, {:sink_state, :connected}}, 5_000
    assert_sink_buffer(receiver, :sink, %Membrane.Buffer{payload: _}, 10_000)

    Pipeline.terminate(sender)
    Pipeline.terminate(receiver)
  end

  @tag timeout: 20_000
  test "sink emits telemetry stats and disconnected on peer disconnect" do
    port = free_port!()
    payload = String.duplicate("C", 1316)

    ref = make_ref()
    test_pid = self()
    handler_id = "sink-integration-telemetry-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:membrane, :srtlt, :stats],
      fn _event, measurements, _metadata, _config ->
        send(test_pid, {:telemetry_stats, ref, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Receiver (listener) starts first
    receiver =
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

    Process.sleep(500)

    # Sender (caller) connects, source linked after connection
    {:ok, _sup, sender} =
      SenderPipeline.start_link(
        sink_opts: %Membrane.SRTLT.Sink{
          host: "127.0.0.1",
          port: port,
          mode: :caller,
          latency_ms: 120,
          transtype: "live",
          chunk_size_bytes: 1316,
          buffering_packets: 10
        },
        source_opts: %Membrane.Testing.Source{
          output: buffer_list(payload, 500),
          stream_format: %Membrane.RemoteStream{}
        },
        test_process: self()
      )

    assert_receive {:sender_pipeline, ^sender, {:sink_state, :connected}}, 5_000

    # Telemetry stats (stats report every 100 packets)
    assert_receive {:telemetry_stats, ^ref, measurements}, 10_000
    assert is_number(measurements.send_bytes)

    # Kill the receiver — sink should detect disconnect
    Pipeline.terminate(receiver)

    assert_receive {:sender_pipeline, ^sender, {{:sink_state, :disconnected}, :srt_sink}}, 5_000

    Pipeline.terminate(sender)
  end

  # -- Helpers --

  defp free_port! do
    {:ok, socket} = :gen_tcp.listen(0, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
