defmodule Edict.Test.RouterFactory do
  @moduledoc """
  Compiles throwaway routers for the router feature steps.

  `compile/1` and `try_compile/1` build a router module from a body declared
  inside one scope; `request/2` dispatches a test conn through a compiled
  router, mirroring what an endpoint does.
  """

  @spec compile(String.t()) :: module()
  def compile(body) do
    module = "Edict.Features.Routers.Compiled#{System.unique_integer([:positive])}"

    [{compiled, _binary}] =
      Code.compile_string("""
      defmodule #{module} do
        use Phoenix.Router, helpers: false
        use Edict.Router

        scope "/" do
          pipe_through([])
          #{body}
        end
      end
      """)

    compiled
  end

  @spec try_compile(String.t()) :: {:ok, module()} | {:error, Exception.t()}
  def try_compile(body) do
    {:ok, compile(body)}
  rescue
    e in CompileError -> {:error, e}
  end

  @doc """
  Compiles an `edict` block with one controller route for `action`.

  `route_opts` become the route's own options, for example
  `permission: :billing`.
  """
  @spec compile_edict_route(String.t(), String.t(), keyword()) :: module()
  def compile_edict_route(entity_type, action, route_opts) do
    compile("""
    edict :#{entity_type}, [param: "project_id"] do
      get "/things/:project_id", Edict.Test.EchoPlug, :#{action}#{format_opts(route_opts)}
    end
    """)
  end

  @doc """
  Compiles a plain Phoenix router that does not `use Edict.Router`.
  """
  @spec compile_plain_router(String.t()) :: module()
  def compile_plain_router(body) do
    module = "Edict.Features.Routers.Plain#{System.unique_integer([:positive])}"

    [{compiled, _binary}] =
      Code.compile_string("""
      defmodule #{module} do
        use Phoenix.Router, helpers: false

        scope "/" do
          pipe_through([])
          #{body}
        end
      end
      """)

    compiled
  end

  @doc "Dispatches a GET request through a compiled router."
  @spec request(module(), String.t()) :: Plug.Conn.t()
  def request(router, path) do
    Plug.Test.conn(:get, path)
    |> Plug.Conn.put_private(:phoenix_router, router)
    |> router.call(router.init(nil))
  end

  defp format_opts([]), do: ""

  defp format_opts(opts),
    do: ", " <> Enum.map_join(opts, ", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)
end
