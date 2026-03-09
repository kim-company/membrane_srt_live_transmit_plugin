defmodule Membrane.SRTLTTest do
  use ExUnit.Case, async: true

  alias Membrane.SRTLT

  describe "build_uri/1" do
    test "builds minimal URI with host and port" do
      assert SRTLT.build_uri(host: "10.0.0.1", port: 9000) == "srt://10.0.0.1:9000"
    end

    test "raises on missing host" do
      assert_raise KeyError, ~r/:host/, fn ->
        SRTLT.build_uri(port: 9000)
      end
    end

    test "raises on missing port" do
      assert_raise KeyError, ~r/:port/, fn ->
        SRTLT.build_uri(host: "10.0.0.1")
      end
    end

    test "appends SRT query parameters in sorted order" do
      uri =
        SRTLT.build_uri(
          host: "192.168.1.10",
          port: 9000,
          mode: :caller,
          latency: 350,
          transtype: "live"
        )

      assert uri == "srt://192.168.1.10:9000?latency=350&mode=caller&transtype=live"
    end

    test "omits nil values" do
      uri =
        SRTLT.build_uri(
          host: "10.0.0.1",
          port: 9000,
          mode: :caller,
          streamid: nil,
          passphrase: nil
        )

      assert uri == "srt://10.0.0.1:9000?mode=caller"
    end

    test "encodes atom values as strings" do
      uri = SRTLT.build_uri(host: "h", port: 1, mode: :listener)
      assert uri =~ "mode=listener"
    end

    test "encodes integer values" do
      uri = SRTLT.build_uri(host: "h", port: 1, latency: 500, rcvlatency: 200)
      assert uri =~ "latency=500"
      assert uri =~ "rcvlatency=200"
    end

    test "encodes string values" do
      uri = SRTLT.build_uri(host: "h", port: 1, streamid: "my-stream")
      assert uri =~ "streamid=my-stream"
    end

    test "ignores unknown keys" do
      uri = SRTLT.build_uri(host: "h", port: 1, bogus_option: "xyz")
      refute uri =~ "bogus"
    end

    test "includes all latency params together" do
      uri =
        SRTLT.build_uri(
          host: "h",
          port: 1,
          latency: 350,
          peerlatency: 350,
          rcvlatency: 350
        )

      query = URI.decode_query(URI.parse(uri).query)
      assert query["latency"] == "350"
      assert query["peerlatency"] == "350"
      assert query["rcvlatency"] == "350"
    end

    test "includes encryption params" do
      uri =
        SRTLT.build_uri(
          host: "h",
          port: 1,
          passphrase: "secret123456",
          pbkeylen: 16
        )

      query = URI.decode_query(URI.parse(uri).query)
      assert query["passphrase"] == "secret123456"
      assert query["pbkeylen"] == "16"
    end

    test "handles full production-like URI" do
      uri =
        SRTLT.build_uri(
          host: "192.168.1.10",
          port: 9000,
          mode: :caller,
          latency: 350,
          peerlatency: 350,
          rcvlatency: 350,
          transtype: "live",
          streamid: "my-stream",
          passphrase: "secret123456"
        )

      parsed = URI.parse(uri)
      assert parsed.scheme == "srt"
      assert parsed.host == "192.168.1.10"
      assert parsed.port == 9000

      query = URI.decode_query(parsed.query)
      assert query["mode"] == "caller"
      assert query["latency"] == "350"
      assert query["peerlatency"] == "350"
      assert query["rcvlatency"] == "350"
      assert query["transtype"] == "live"
      assert query["streamid"] == "my-stream"
      assert query["passphrase"] == "secret123456"
    end
  end
end
