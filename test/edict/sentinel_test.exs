defmodule Edict.SentinelTest do
  use ExUnit.Case, async: true

  @edict_config %{config_module: Edict.Test.Config}

  # A sentinel denial that re-enters the before_send chain recurses without
  # bound. The heap cap kills the test process within seconds instead of
  # letting it exhaust the machine's memory.
  @tag timeout: 5_000
  test "an undeclared request is denied with a 403 at send time" do
    Process.flag(:max_heap_size, %{size: 12_500_000, kill: true, error_logger: false})

    conn =
      Plug.Test.conn(:get, "/legacy")
      |> Plug.Conn.assign(:edict_config, @edict_config)
      |> Edict.Sentinel.call(Edict.Sentinel.init([]))
      |> Plug.Conn.send_resp(200, "ok")

    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
    assert conn.halted
    assert conn.private[:edict] == nil
  end

  test "a stamped request passes through unchanged" do
    conn =
      Plug.Test.conn(:get, "/things/7")
      |> Plug.Conn.assign(:edict_config, @edict_config)
      |> Edict.Sentinel.call(Edict.Sentinel.init([]))
      |> Plug.Conn.put_private(:edict, %{decision: :allow})
      |> Plug.Conn.send_resp(200, "ok")

    assert conn.status == 200
    assert conn.resp_body == "ok"
    refute conn.halted
  end
end
