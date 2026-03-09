defmodule Membrane.SRTLT.SourceTest do
  use ExUnit.Case, async: false

  alias Membrane.Testing.MockResourceGuard
  alias Membrane.SRTLT.Source

  @process_cleanup_tag :srtlt_source_process_cleanup

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
      buffering_packets: 10
    }
  end

  test "retries with exponential backoff before first payload" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Source.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 123}}

    # First failure: 100ms delay, next becomes 200ms
    {actions, state} =
      Source.handle_info(
        {:DOWN, 123, :process, self(), {:exit_status, 1}},
        ctx,
        state
      )

    assert actions == []
    assert state.command_ref == nil
    assert is_reference(state.retry_timer_ref)
    assert state.retry_delay_ms == 200

    assert_receive {MockResourceGuard, ^resource_guard, {:unregister, @process_cleanup_tag}},
                   1_000

    _ = Process.cancel_timer(state.retry_timer_ref)

    # Second failure: 200ms delay, next becomes 400ms
    state = %{state | retry_timer_ref: nil, command_ref: %{pid: self(), ospid: 456}}

    {actions, state} =
      Source.handle_info(
        {:DOWN, 456, :process, self(), {:exit_status, 1}},
        ctx,
        state
      )

    assert actions == []
    assert is_reference(state.retry_timer_ref)
    assert state.retry_delay_ms == 400

    _ = Process.cancel_timer(state.retry_timer_ref)
  end

  test "emits disconnected and eos after payload had been received" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Source.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 321}, received_data?: true}

    {actions, state} =
      Source.handle_info(
        {:DOWN, 321, :process, self(), :port_closed},
        ctx,
        state
      )

    assert [notify_parent: {:source_state, :disconnected}, end_of_stream: :output] = actions
    assert state.eos_sent?
    assert state.retry_timer_ref == nil
  end

  test "close notification emits eos and is idempotent" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Source.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 789}, received_data?: true}

    # First close
    {actions, state} = Source.handle_parent_notification(:close, ctx, state)
    assert [end_of_stream: :output] = actions
    assert state.eos_sent?

    # Second close is a no-op
    {actions, _state} = Source.handle_parent_notification(:close, ctx, state)
    assert actions == []
  end

  test "no retry when eos already sent" do
    resource_guard = MockResourceGuard.start_link_supervised!()
    ctx = %{resource_guard: resource_guard}

    {[], state} = Source.handle_init(%{}, default_opts())
    state = %{state | eos_sent?: true, command_ref: %{pid: self(), ospid: 111}}

    {actions, state} =
      Source.handle_info(
        {:DOWN, 111, :process, self(), :normal},
        ctx,
        state
      )

    assert actions == []
    assert state.retry_timer_ref == nil
  end

  test "stdout emits connected notification and buffer when playing" do
    {[], state} = Source.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 555}}

    payload = "ts-data-bytes"

    {actions, state} =
      Source.handle_info(
        {:stdout, 555, payload},
        %{playback: :playing},
        state
      )

    assert [
             notify_parent: {:source_state, :connected},
             buffer: {:output, %Membrane.Buffer{payload: ^payload}}
           ] = actions

    assert state.received_data?
    assert state.notified_connected?
    assert state.retry_delay_ms == 100

    # Second stdout: no connected notification
    {actions, _state} =
      Source.handle_info(
        {:stdout, 555, "more-data"},
        %{playback: :playing},
        state
      )

    assert [buffer: {:output, %Membrane.Buffer{payload: "more-data"}}] = actions
  end

  test "stdout before playing emits connected notification without buffer" do
    {[], state} = Source.handle_init(%{}, default_opts())
    state = %{state | command_ref: %{pid: self(), ospid: 666}}

    {actions, state} =
      Source.handle_info(
        {:stdout, 666, "early-data"},
        %{playback: :stopped},
        state
      )

    assert [notify_parent: {:source_state, :connected}] = actions
    assert state.received_data?
  end
end
