defmodule Membrane.SRTLT.StatsTest do
  use ExUnit.Case, async: true

  alias Membrane.SRTLT.Stats

  @sample_json ~s({"sid":1026451247,"timepoint":"2026-03-16T11:28:42.379495+0100","time":1837,"window":{"flow":8192,"congestion":8192,"flight":0},"link":{"rtt":0.032,"bandwidth":12.5,"maxBandwidth":1000},"send":{"packets":10,"packetsUnique":10,"packetsLost":2,"packetsDropped":1,"packetsRetransmitted":3,"packetsFilterExtra":0,"bytes":14560,"bytesUnique":14560,"bytesDropped":0,"byteAvailBuf":12288000,"msBuf":0,"mbitRate":1.5,"sendPeriod":10},"recv":{"packets":100,"packetsUnique":100,"packetsLost":5,"packetsDropped":3,"packetsRetransmitted":7,"packetsBelated":2,"packetsFilterExtra":0,"packetsFilterSupply":0,"packetsFilterLoss":0,"bytes":150000,"bytesUnique":150000,"bytesLost":0,"bytesDropped":0,"byteAvailBuf":12285000,"msBuf":1,"mbitRate":0.653184,"msTsbPdDelay":120}})

  describe "parse/1" do
    test "parses valid SRT stats JSON" do
      assert {:ok, m} = Stats.parse(@sample_json)

      assert m.send_bytes == 14_560
      assert m.send_packets == 10
      assert m.send_packets_lost == 2
      assert m.send_packets_dropped == 1
      assert m.send_packets_retransmitted == 3
      assert m.send_mbit_rate == 1.5

      assert m.recv_bytes == 150_000
      assert m.recv_packets == 100
      assert m.recv_packets_lost == 5
      assert m.recv_packets_dropped == 3
      assert m.recv_packets_retransmitted == 7
      assert m.recv_packets_belated == 2
      assert m.recv_mbit_rate == 0.653184
      assert m.recv_ms_buf == 1

      assert m.link_rtt == 0.032
      assert m.link_bandwidth == 12.5
    end

    test "returns :error for non-JSON string" do
      assert Stats.parse("SRT source connected") == :error
    end

    test "returns :error for empty string" do
      assert Stats.parse("") == :error
    end

    test "returns :error for invalid JSON" do
      assert Stats.parse("{invalid json}") == :error
    end

    test "returns :error for JSON without send/recv keys" do
      assert Stats.parse(~s({"foo": "bar"})) == :error
    end

    test "handles missing optional keys gracefully" do
      json = ~s({"send":{"bytes":100},"recv":{"bytes":200}})
      assert {:ok, m} = Stats.parse(json)

      assert m.send_bytes == 100
      assert m.send_packets == 0
      assert m.send_mbit_rate == 0.0
      assert m.recv_bytes == 200
      assert m.recv_packets_belated == 0
      assert m.link_rtt == 0.0
      assert m.link_bandwidth == 0.0
    end

    test "handles whitespace-padded line" do
      assert {:ok, m} = Stats.parse("  #{@sample_json}  \n")
      assert m.recv_bytes == 150_000
    end

    test "returns :error for nil" do
      assert Stats.parse(nil) == :error
    end
  end

  describe "parse_all/1" do
    test "extracts stats from mixed stderr chunk" do
      chunk = """
      11:28:40.865/*E:SRT.br: readMessage: small dst buffer
      #{@sample_json}
      11:28:41.032/*E:SRT.br: readMessage: small dst buffer
      """

      results = Stats.parse_all(chunk)
      assert length(results) == 1
      assert hd(results).recv_bytes == 150_000
    end

    test "extracts multiple stats objects" do
      json2 = ~s({"send":{"bytes":200},"recv":{"bytes":400}})

      chunk = "#{@sample_json}\n#{json2}\n"
      results = Stats.parse_all(chunk)
      assert length(results) == 2
      assert Enum.at(results, 0).send_bytes == 14_560
      assert Enum.at(results, 1).send_bytes == 200
    end

    test "returns empty list for non-stats content" do
      assert Stats.parse_all("just some log line\nanother line\n") == []
    end
  end

  describe "emit/3" do
    test "emits telemetry event with prefix ++ [:stats]" do
      ref = make_ref()
      test_pid = self()

      handler_id = "test-stats-emit-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:test, :srt, :stats],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      measurements = %{send_bytes: 100, recv_bytes: 200}
      metadata = %{host: "10.0.0.1", port: 9000}

      Stats.emit(measurements, [:test, :srt], metadata)

      assert_receive {:telemetry, ^ref, [:test, :srt, :stats], ^measurements, ^metadata}
    end
  end
end
