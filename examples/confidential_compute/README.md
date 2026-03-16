# Confidential Compute: Sensitive Data Never Leaves the Browser

**Port 4006** | `cd examples/confidential_compute && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

A password strength checker and SSN validator that process sensitive data entirely in the browser's WASM sandbox. The server only receives computed results (strength score, masked SSN), never the raw password or SSN. A visual data-flow diagram on the page makes this explicit.

This demo uses **inline `defwasm`** with `~S` sigils for Rust code containing escaped quotes.

## Why Use Exclosured Here?

### The problem

Your application handles sensitive user data: passwords, government IDs, health records, financial details. Processing them server-side means:
- The data traverses the network (interceptable, even with TLS)
- Your server sees the raw data (liability, compliance burden)
- A server breach exposes all processed data
- You must comply with GDPR/HIPAA/PCI for data-in-transit and data-at-rest

### Alternative approaches

| Approach | Trade-off |
|---|---|
| **Server-side processing** | Simplest, but the server sees everything. You're responsible for protecting it. Compliance overhead. |
| **Client-side JavaScript** | Data stays local, but JS is inspectable, modifiable, and slow. No compile-time guarantees. |
| **Client-side WASM (manual)** | Data stays local, near-native speed, harder to tamper with. But you build the bridge yourself. |
| **Exclosured `defwasm`** | Data stays local, Rust type safety, and the Elixir module declares exactly what the server receives. |

### What Exclosured adds

The key insight: the Elixir module IS the documentation of the privacy boundary.

```elixir
defwasm :check_password, args: [input: :binary] do
  ~S"""
  // This code runs in the browser. Input never leaves
  // Only the score/label is returned to the caller
  """
end

# In the LiveView, the server only sees:
def handle_event("pw_checked", %{"score" => 5, "label" => "strong"}, socket)
# Never: %{"password" => "MyS3cr3t!"}
```

A security reviewer reads one file and sees:
1. What Rust code runs on the client (the `defwasm` body)
2. What the server receives (the `handle_event` params)
3. That there is no code path where raw data reaches the server

## Pros and Cons

**Pros:**
- **Structural guarantee**: the server literally cannot see the raw data. It's not a policy promise, it's a code-level impossibility.
- Reduces compliance scope: data that never leaves the browser isn't "data in transit" or "data at rest" on your server
- WASM sandbox is harder to tamper with than plain JavaScript (no source maps, compiled binary)
- Small binaries (16KB), negligible load time overhead
- The `~S` sigil preserves Rust escape sequences, so JSON building with `\"` works naturally

**Cons:**
- The server cannot verify the computation; it trusts the client's result. For password strength, this is fine (the user is the one who cares). For regulatory validation, you may need server-side verification too.
- If the user disables JavaScript/WASM, the feature doesn't work. You need a fallback or a hard requirement.
- WASM is harder to tamper with than JS, but not impossible. A determined attacker can still modify the binary. This is client-side processing, not a hardware enclave.
- Debugging WASM is harder than debugging Elixir. Stack traces are less readable.
- The mutable buffer pattern (write result back into input) requires careful size management.

## When to Choose This Pattern

- You handle PII, credentials, health data, or financial data
- You want to minimize your compliance surface area
- The processing is self-contained (no server-side data needed)
- You can accept client-reported results (or pair with server-side verification for critical paths)
- You want a clear, auditable privacy boundary in your codebase

## Important Note

Client-side processing is a **defense-in-depth** measure, not a silver bullet. For high-stakes scenarios (e.g., actual cryptographic key derivation), combine this with:
- Server-side validation of the result format
- Rate limiting on the endpoint receiving results
- Certificate pinning / CSP headers to prevent WASM binary tampering
- A real cryptographic library (ring, RustCrypto) in a full Cargo workspace instead of inline `defwasm`
