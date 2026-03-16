defmodule Membrane.SRTLT.SinkTest do
  use ExUnit.Case, async: false

  alias Membrane.Testing.MockResourceGuard
  alias Membrane.SRTLT.Sink
  require Membrane.Pad

  defp default_opts do
    %{
      host: "127.0.0.1",
      port: 9711,
      mode: :caller,
      latency_ms: 100,
      peer_latency_ms: nil,
      rcv_latency_ms: nil,
      transtype: "live",
      stream_id: "test-stream",
      passphrase: nil,
      chunk_size_bytes: 1316,
      buffering_packets: 10,
      telemetry_prefix: [:membrane, :srtlt]
    }
  end

  test "retries with exponential backoff when process exits before connected" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 123}}

    # First failure: 100ms delay, next becomes 200ms
    {actions, state} =
      Sink.handle_info(
        {:DOWN, 123, :process, self(), {:exit_status, 1}},
        ctx,
        state
      )

    assert actions == []
    assert state.command_ref == nil
    assert is_reference(state.retry_timer_ref)
    assert state.retry_delay_ms == 200

    _ = Process.cancel_timer(state.retry_timer_ref)

    # Second failure: 200ms delay, next becomes 400ms
    state = %{state | retry_timer_ref: nil, command_ref: %{pid: self(), ospid: 456}}

    {actions, state} =
      Sink.handle_info(
        {:DOWN, 456, :process, self(), {:exit_status, 1}},
        ctx,
        state
      )

    assert actions == []
    assert is_reference(state.retry_timer_ref)
    assert state.retry_delay_ms == 400

    _ = Process.cancel_timer(state.retry_timer_ref)
  end

  test "emits disconnected notification and retries when connected process exits" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 321}, connected?: true}

    {actions, state} =
      Sink.handle_info(
        {:DOWN, 321, :process, self(), :port_closed},
        ctx,
        state
      )

    assert [notify_parent: {:sink_state, :disconnected}] = actions
    refute state.connected?
    assert is_reference(state.retry_timer_ref)

    _ = Process.cancel_timer(state.retry_timer_ref)
  end

  test "no retry after EOS received" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 789}, eos_received?: true}

    {actions, state} =
      Sink.handle_info(
        {:DOWN, 789, :process, self(), :normal},
        ctx,
        state
      )

    assert actions == []
    assert state.retry_timer_ref == nil
  end

  test "EOS after connected emits disconnected" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Sink.handle_init(%{}, default_opts())

    state = %{
      state
      | command_ref: %{pid: self(), ospid: 790},
        eos_received?: true,
        connected?: true
    }

    {actions, _state} =
      Sink.handle_info(
        {:DOWN, 790, :process, self(), :normal},
        ctx,
        state
      )

    assert [notify_parent: {:sink_state, :disconnected}] = actions
  end

  test "retry_connect is ignored after EOS" do
    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | eos_received?: true}

    {actions, state} = Sink.handle_info(:retry_connect, %{}, state)
    assert actions == []
    assert state.retry_timer_ref == nil
  end

  test "stderr with connected message emits connected notification" do
    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 555}}

    {actions, state} =
      Sink.handle_info(
        {:stderr, 555, "SRT target connected\n"},
        %{},
        state
      )

    assert [notify_parent: {:sink_state, :connected}] = actions
    assert state.connected?
    assert state.retry_delay_ms == 100

    # Second connected message: no duplicate notification
    {actions, _state} =
      Sink.handle_info(
        {:stderr, 555, "SRT target connected\n"},
        %{},
        state
      )

    assert actions == []
  end

  test "stderr with accepted message emits connected notification (listener mode)" do
    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 556}}

    {actions, state} =
      Sink.handle_info(
        {:stderr, 556, "Accepted SRT target connection\n"},
        %{},
        state
      )

    assert [notify_parent: {:sink_state, :connected}] = actions
    assert state.connected?
  end

  test "stderr with stats JSON emits telemetry" do
    ref = make_ref()
    test_pid = self()
    handler_id = "sink-test-stats-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:membrane, :srtlt, :stats],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stats_json =
      ~s({"send":{"bytes":1000,"packets":10,"packetsLost":0,"packetsDropped":0,"packetsRetransmitted":0,"mbitRate":0.5},"recv":{"bytes":0,"packets":0,"packetsLost":0,"packetsDropped":0,"packetsRetransmitted":0,"packetsBelated":0,"mbitRate":0.0,"msBuf":0},"link":{"rtt":0.1,"bandwidth":10.0}})

    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 557}}

    Sink.handle_info({:stderr, 557, stats_json}, %{}, state)

    assert_receive {:telemetry, ^ref, measurements, metadata}
    assert measurements.send_bytes == 1000
    assert metadata.host == "127.0.0.1"
  end

  test "buffer dropped when no process running logs warning" do
    {[], state} = Sink.handle_init(%{}, default_opts())
    assert state.command_ref == nil

    {actions, _state} =
      Sink.handle_buffer(
        :input,
        %Membrane.Buffer{payload: "data"},
        %{},
        state
      )

    assert actions == []
  end

  test "handle_end_of_stream marks eos and cancels retry" do
    resource_guard = MockResourceGuard.start_link_supervised!()

    {[], state} = Sink.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 558}}
    state = %{state | retry_timer_ref: Process.send_after(self(), :retry_connect, 60_000)}

    {actions, state} =
      Sink.handle_end_of_stream(
        Membrane.Pad.ref(:input, 0),
        %{resource_guard: resource_guard},
        state
      )

    assert actions == []
    assert state.eos_received?
    assert state.retry_timer_ref == nil
  end
end
