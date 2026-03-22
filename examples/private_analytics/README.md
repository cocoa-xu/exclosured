# Private Analytics: E2E Encrypted Data Room

**Port 4011** | `cd examples/private_analytics && mix deps.get && mix compile && mix phx.server`

## What This Demonstrates

A private data analytics room where one user (the owner) loads a CSV dataset into DuckDB-WASM in their browser. They can share encrypted views with other users in real-time. All data is end-to-end encrypted using AES-256-GCM. The server relays opaque encrypted blobs and cannot read any data.

Viewers can submit SQL queries (if granted editor permission), which get encrypted, relayed to the owner, executed on the owner's DuckDB, and the results are encrypted and broadcast back.

## Key Features

- **E2E encryption**: AES-256-GCM in Rust WASM (`aes-gcm` crate). The encryption key lives only in URL fragments, never reaching the server.
- **Role-based access**: owner generates separate view/edit URLs with unique cryptographic tokens. The server verifies roles via SHA-256 token hashes without seeing the actual tokens or keys.
- **Real-time SQL relay**: editors submit encrypted SQL to the owner's browser for execution. Results broadcast to all viewers.
- **Paginated results**: large datasets paginate via LIMIT/OFFSET on the owner's DuckDB.
- **Rate limiting**: server-side sliding window limits broadcast frequency to prevent flooding.
- **Dual themes**: light and dark mode with a single toggle.
- **SQL syntax highlighting**: real-time keyword coloring in the query editor.

## Security Architecture

```
URL fragment:  #<room_key_b64>.<role_token_b64>
                 |                |
                 |                +-- hashed, sent to server for role verification
                 |
                 +-- never leaves the browser (used for AES encrypt/decrypt)
```

The server stores `hash(viewer_token)` and `hash(editor_token)` when the room is created. When a user joins, they send `hash(their_token)` to the server. The server matches it to determine the role. The server never sees the room key, the raw tokens, or any decrypted data.

## Exclosured Features Used

| Feature | Usage |
|---|---|
| Rust WASM (Cargo workspace) | `aes-gcm` + `sha2` crates for encryption and token hashing |
| `exclosured::emit` | WASM emits encrypted results to LiveView |
| Telemetry | Encryption/decryption timing |
| Fallback | If Rust WASM fails, could fall back to Web Crypto API |
| LiveView PubSub | Room management, encrypted blob relay |

## How to Use

1. Open `http://localhost:4011`
2. Click "Create Room"
3. Upload a CSV file (drag and drop or file picker)
4. Write SQL queries in the editor
5. Share the view/edit URL with others (the URL fragment contains the encryption key)
6. Other users open the link and see the encrypted results decrypted in their browser
