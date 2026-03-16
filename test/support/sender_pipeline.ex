defmodule Membrane.SRTLT.Test.SenderPipeline do
  @moduledoc """
  Test pipeline that starts a Sink and waits for SRT connection before
  linking a source to feed data.

  The Sink uses `availability: :on_request` for its input pad, allowing
  the pipeline to start the Sink alone. When `{:sink_state, :connected}`
  arrives, the source is spawned and linked dynamically.

  Forwards `{:sender_pipeline, pid, notification}` to the test process.
  """

  use Membrane.Pipeline

  import Membrane.ChildrenSpec

  def start_link(opts) do
    Membrane.Pipeline.start_link(__MODULE__, opts)
  end

  @impl true
  def handle_init(_ctx, opts) do
    spec = child(:srt_sink, opts[:sink_opts])

    {[spec: spec],
     %{
       source_opts: opts[:source_opts],
       test_process: opts[:test_process],
       source_started?: false
     }}
  end

  @impl true
  def handle_child_notification({:sink_state, :connected} = notif, :srt_sink, _ctx, state) do
    send(state.test_process, {:sender_pipeline, self(), notif})

    if state.source_started? do
      {[], state}
    else
      spec =
        child(:test_source, state.source_opts)
        |> get_child(:srt_sink)

      {[spec: spec], %{state | source_started?: true}}
    end
  end

  def handle_child_notification(notif, child, _ctx, state) do
    send(state.test_process, {:sender_pipeline, self(), {notif, child}})
    {[], state}
  end
end
