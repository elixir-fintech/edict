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

  test "a denial keeps the pipeline's headers and drops the handler's" do
    # Plug merges response cookies after the before_send callbacks, so
    # anything added after the sentinel would still reach the client.
    conn =
      Plug.Test.conn(:get, "/legacy")
      # The pipeline, before the sentinel: security headers survive.
      |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
      |> Plug.Conn.assign(:edict_config, @edict_config)
      |> Edict.Sentinel.call(Edict.Sentinel.init([]))
      # The denied handler, after the sentinel: dropped.
      |> Plug.Conn.put_resp_header("x-leak", "secret")
      |> Plug.Conn.put_resp_cookie("session", "leaked")
      |> Plug.Conn.send_resp(200, "ok")

    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert Plug.Conn.get_resp_header(conn, "x-leak") == []
    assert conn.resp_cookies == %{}
  end

  test "a denial drops the denied handler's session changes" do
    # Plug.Session registers its cookie-writing before_send when the session
    # is fetched in the pipeline — before the sentinel. Reverse callback
    # order means it runs after the sentinel's rewrite, so the session must
    # be marked ignored for its changes to stay out of the cookie.
    session_opts =
      Plug.Session.init(
        store: :cookie,
        key: "edict_test_session",
        encryption_salt: "encrypted at rest",
        signing_salt: "signed",
        log: false
      )

    conn =
      Plug.Test.conn(:get, "/legacy")
      |> Plug.Session.call(session_opts)
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.assign(:edict_config, @edict_config)
      |> Edict.Sentinel.call(Edict.Sentinel.init([]))
      # The denied handler tries to write to the session after the sentinel.
      |> Plug.Conn.put_session(:role, "admin")
      |> Plug.Conn.send_resp(200, "ok")

    assert conn.status == 403
    assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
  end
end
