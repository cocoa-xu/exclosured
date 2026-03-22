# Developer Guide

How to develop, test, and publish Exclosured.

## Development Setup

```sh
# Install prerequisites
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli

# Clone and setup
git clone https://github.com/cocoa-xu/exclosured.git
cd exclosured
mix deps.get

# Compile (builds Rust guest crate + inline WASM tests)
mix compile

# Run tests
mix test

# Format check
mix format --check-formatted

# Compile with warnings as errors (same as CI)
mix compile --force --warnings-as-errors
```

## Project Structure

```
exclosured/
├── lib/                          # Elixir library source
│   ├── exclosured.ex             # Public API
│   ├── exclosured/
│   │   ├── config.ex             # Configuration parsing
│   │   ├── compiler.ex           # cargo + wasm-bindgen pipeline
│   │   ├── manifest.ex           # Incremental compilation
│   │   ├── live_view.ex          # LiveView integration (call, sync, stream_call, fallback)
│   │   ├── inline.ex             # defwasm macro
│   │   ├── events.ex             # Typed event codegen from Rust structs
│   │   ├── events/parser.ex      # Rust struct parser
│   │   ├── protocol.ex           # Binary state sync protocol
│   │   ├── telemetry.ex          # Telemetry events
│   │   └── watcher.ex            # Dev file watcher
│   └── mix/tasks/
│       ├── compile/exclosured.ex # Mix compiler
│       └── exclosured.init.ex    # Scaffolding task
├── native/
│   └── exclosured_guest/         # Rust crate (published to crates.io)
├── priv/static/
│   ├── exclosured_hook.js        # LiveView hook (also in npm package)
│   └── exclosured.js             # Standalone loader
├── npm/                          # npm package source
├── test/                         # ExUnit tests
└── examples/                     # Demo Phoenix apps
```

## Running Examples

Each example is a standalone Phoenix app:

```sh
cd examples/wasm_ai          # or any other demo
mix deps.get
mix compile
mix phx.server                # opens on the port specified in config
```

## Testing

```sh
# All tests (requires Rust toolchain)
mix test

# Specific test file
mix test test/exclosured/config_test.exs

# With coverage
mix test --cover
```

The inline WASM tests (`test/exclosured/inline_test.exs`) compile Rust code at test time, so they require `cargo` and `wasm-bindgen-cli` to be installed.

## Publishing

Exclosured is published to three registries. Always bump versions in sync.

### 1. Rust Guest Crate (crates.io)

The `exclosured_guest` crate is what users add to their Rust WASM modules.

```sh
cd native/exclosured_guest

# Update version in Cargo.toml
# Then:
cargo publish --dry-run    # verify everything looks correct
cargo publish              # publish to crates.io
```

Verify: https://crates.io/crates/exclosured_guest

### 2. npm Package (npmjs.com)

The `exclosured` npm package contains the LiveView hook and standalone loader.

```sh
cd npm

# Update version in package.json
# Then:
npm publish --dry-run      # verify package contents
npm publish                # publish to npm
```

Verify: https://www.npmjs.com/package/exclosured

### 3. Elixir Library (hex.pm)

The main Exclosured library.

```sh
# Update version in mix.exs (@version)
# Then:
mix hex.publish            # publish to hex.pm
mix hex.publish docs       # publish documentation
```

Verify: https://hex.pm/packages/exclosured

### Version Sync Checklist

When releasing a new version:

1. Update `native/exclosured_guest/Cargo.toml` version
2. Update `npm/package.json` version
3. Update `mix.exs` `@version`
4. Update `exclosured_guest = "X.Y"` in `lib/mix/tasks/exclosured.init.ex` (the scaffolding template)
5. Run `mix test` and `mix format --check-formatted`
6. Publish in order: crates.io first, then npm, then hex.pm
7. Tag the git commit: `git tag vX.Y.Z && git push --tags`

## Local Development Overrides

When working on the library itself, you often need to test unpublished changes in a consumer project. Here's how to use local versions instead of the published packages.

### Rust: local `exclosured_guest`

In your WASM module's `Cargo.toml`, replace the crates.io version with a path dependency pointing to your local checkout:

```toml
[dependencies]
# Published version (normal usage):
# exclosured_guest = "0.1"

# Local development override (point to your local clone):
exclosured_guest = { path = "/path/to/exclosured/native/exclosured_guest" }
```

Alternatively, use a Cargo [patch] section in your workspace `Cargo.toml` to override without editing each crate:

```toml
[patch.crates-io]
exclosured_guest = { path = "/path/to/exclosured/native/exclosured_guest" }
```

This overrides `exclosured_guest` globally for the entire workspace. Remove the `[patch]` section before publishing.

### JavaScript: local `exclosured` npm package

Instead of installing from npm, link your local checkout:

```sh
# In the exclosured repo:
cd npm
npm link

# In your consumer project:
cd my_app/assets
npm link exclosured
```

Now `import { ExclosuredHook } from "exclosured"` resolves to your local `npm/` directory. Changes to `npm/index.mjs` take effect immediately without republishing.

To unlink and go back to the published version:

```sh
cd my_app/assets
npm unlink exclosured
npm install exclosured
```

### Elixir: local `exclosured` hex package

In your consumer project's `mix.exs`, replace the hex dependency with a path:

```elixir
defp deps do
  [
    # Published version (normal usage):
    # {:exclosured, "~> 0.1.0"}

    # Local development override:
    {:exclosured, path: "/path/to/exclosured"}
  ]
end
```

Then `mix deps.get` to pick up the local version.

### All three at once

For full end-to-end local development (changing the Elixir library, the Rust guest crate, and the JS hook simultaneously):

1. Set `{:exclosured, path: "/path/to/exclosured"}` in your consumer's `mix.exs`
2. Add `[patch.crates-io]` in your WASM workspace's `Cargo.toml`
3. Run `npm link exclosured` in your consumer's `assets/` directory
4. All changes across all three languages take effect locally without publishing

Remember to undo all overrides before committing or publishing.

### CI

GitHub Actions runs on every push to `main` and every PR:

- Installs Elixir, Rust, wasm32 target, wasm-bindgen-cli
- `mix compile --warnings-as-errors`
- `mix format --check-formatted`
- `mix test`

See `.github/workflows/ci.yml`.
