# Edict

Cached authorization for Phoenix applications.

Edict maintains a per-user authorization document in an ETS-backed cache (Cachex).
Instead of loading authorization context on every request, permission checks read
from the cached document with sub-microsecond latency. Documents are automatically
invalidated when roles change, with cross-node support via Phoenix.PubSub.

## Installation

Add `edict` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:edict, "~> 0.1"}
  ]
end
```

Then run:

```bash
mix edict.install
mix ecto.migrate
```

See the documentation for setup and usage.
