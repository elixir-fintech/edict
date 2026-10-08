defmodule Edict.AuditTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Edict.Audit

  @clean ~S"""
  defmodule MyAppWeb.CleanLive do
    use Phoenix.LiveView
    use Edict.Enforcement.Authorize

    edict_entity :project, from: :project_id
    authorize "save", :write

    def handle_event("save", _params, socket), do: {:noreply, socket}
  end
  """

  @gap """
  defmodule MyAppWeb.GapLive do
    use Phoenix.LiveView
    use Edict.Enforcement.Authorize

    edict_entity :project, from: :project_id
    authorize "save", :write

    def handle_event("save", _params, socket), do: {:noreply, socket}
    def handle_event("ping", %{"confirm" => true}, socket), do: {:noreply, socket}
    def handle_event("ping", _params, socket), do: {:noreply, socket}
  end
  """

  @list_form ~S"""
  defmodule MyAppWeb.ListLive do
    use Phoenix.LiveView
    use Edict.Enforcement.Authorize

    edict_entity :project, from: :project_id
    authorize ["save", "publish"], :write

    def handle_event("save", _params, socket), do: {:noreply, socket}
    def handle_event("publish", _params, socket), do: {:noreply, socket}
  end
  """

  @dynamic """
  defmodule MyAppWeb.DynamicLive do
    use Phoenix.LiveView
    use Edict.Enforcement.Authorize

    edict_entity :project, from: :project_id
    authorize "save", :write

    def handle_event("save", _params, socket), do: {:noreply, socket}
    def handle_event(name, _params, socket), do: {:noreply, socket}
  end
  """

  @forgot_use ~S"""
  defmodule MyAppWeb.ForgotUseLive do
    use Phoenix.LiveView

    def handle_event("save", _params, socket), do: {:noreply, socket}
    def handle_event("ping", _params, socket), do: {:noreply, socket}
  end
  """

  @component ~S"""
  defmodule MyAppWeb.ModalComponent do
    use Phoenix.LiveComponent

    def handle_event("close", _params, socket), do: {:noreply, socket}
  end
  """

  @guarded_head ~S"""
  defmodule MyAppWeb.GuardedHeadLive do
    use Phoenix.LiveView
    use Edict.Enforcement.Authorize

    edict_entity :project, from: :project_id
    authorize "save", :write

    def handle_event("save", _params, socket) when is_map(socket), do: {:noreply, socket}
  end
  """

  # A local authorize/2 inside a function body must not read as a declaration.
  @local_helper ~S"""
  defmodule MyAppWeb.SelfGuardedLive do
    use Phoenix.LiveView

    def handle_event("save", _params, socket) do
      authorize("save", :write)
      {:noreply, socket}
    end

    defp authorize(event, _permission), do: event
  end
  """

  test "a declared and handled event leaves the module clean" do
    [finding] = Audit.scan_source(@clean, "clean_live.ex")

    assert finding.module == "MyAppWeb.CleanLive"
    assert finding.path == "clean_live.ex"
    assert finding.uses_authorize? == true
    assert finding.undeclared == []
    assert finding.unverifiable == []
  end

  test "an event handled but never declared is undeclared, once per name" do
    [finding] = Audit.scan_source(@gap, "gap_live.ex")

    assert finding.undeclared == ["ping"]
    assert finding.unverifiable == []
  end

  test "a list declaration declares every event in it" do
    [finding] = Audit.scan_source(@list_form, "list_live.ex")

    assert finding.undeclared == []
    assert finding.unverifiable == []
  end

  test "a dynamic event name is unverifiable, never undeclared" do
    [finding] = Audit.scan_source(@dynamic, "dynamic_live.ex")

    assert finding.undeclared == []
    assert finding.unverifiable == ["name"]
    assert Audit.exit_status([finding]) == :ok
  end

  test "a view that forgot the use has every event undeclared" do
    [finding] = Audit.scan_source(@forgot_use, "forgot_use_live.ex")

    assert finding.uses_authorize? == false
    assert finding.undeclared == ["save", "ping"]
  end

  test "a LiveComponent module is skipped" do
    assert Audit.scan_source(@component, "modal_component.ex") == []
  end

  test "an event name in a guarded clause head is collected" do
    [finding] = Audit.scan_source(@guarded_head, "guarded_head_live.ex")

    assert finding.undeclared == []
  end

  test "an authorize call inside a function body is not a declaration" do
    [finding] = Audit.scan_source(@local_helper, "self_guarded_live.ex")

    assert finding.undeclared == ["save"]
  end

  test "exit status is non-zero exactly when events are undeclared" do
    assert Audit.exit_status(Audit.scan_source(@gap, "gap_live.ex")) == {:shutdown, 1}

    assert Audit.exit_status(Audit.scan_source(@forgot_use, "forgot_use_live.ex")) ==
             {:shutdown, 1}

    assert Audit.exit_status(Audit.scan_source(@clean, "clean_live.ex")) == :ok
    assert Audit.exit_status(Audit.scan_source(@dynamic, "dynamic_live.ex")) == :ok
    assert Audit.exit_status([]) == :ok
  end

  describe "over files" do
    setup do
      dir =
        Path.join([
          System.tmp_dir!(),
          "edict_audit_test",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      write(dir, "plain.ex", "defmodule Plain do\nend\n")

      write(dir, "view.ex", @clean)

      # In scope only by the _live.ex naming convention.
      write(
        dir,
        "wrapper_live.ex",
        """
        defmodule MyAppWeb.WrapperLive do
          use MyAppWeb, :live_view

          def handle_event("ping", _params, socket), do: {:noreply, socket}
        end
        """
      )

      write(dir, "component.ex", @component)

      write(dir, "mixed_live.ex", @component <> "\n" <> @gap)

      %{glob: Path.join(dir, "*.ex"), dir: dir}
    end

    test "find_sources keeps LiveViews and _live.ex files, dropping the rest",
         %{glob: glob, dir: dir} do
      assert Enum.sort(Audit.find_sources(glob)) == [
               Path.join(dir, "mixed_live.ex"),
               Path.join(dir, "view.ex"),
               Path.join(dir, "wrapper_live.ex")
             ]
    end

    test "scan_paths reports only modules with findings, skipping components",
         %{glob: glob, dir: dir} do
      assert Enum.sort_by(Audit.scan_paths(Audit.find_sources(glob)), & &1.path) ==
               [
                 %Audit{
                   path: Path.join(dir, "mixed_live.ex"),
                   module: "MyAppWeb.GapLive",
                   uses_authorize?: true,
                   undeclared: ["ping"],
                   unverifiable: []
                 },
                 %Audit{
                   path: Path.join(dir, "wrapper_live.ex"),
                   module: "MyAppWeb.WrapperLive",
                   uses_authorize?: false,
                   undeclared: ["ping"],
                   unverifiable: []
                 }
               ]
    end

    test "the task exits non-zero when events are undeclared", %{glob: glob} do
      assert catch_exit(Mix.Tasks.Edict.Audit.run([glob])) == {:shutdown, 1}
    end

    test "the task stays at zero when everything is declared", %{dir: dir} do
      write(dir, "only.ex", @clean)

      assert Mix.Tasks.Edict.Audit.run([Path.join(dir, "only.ex")]) == :ok
    end
  end

  defp write(dir, name, contents), do: File.write!(Path.join(dir, name), contents)
end
