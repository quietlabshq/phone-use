# Optional Cloudflare relay

This package is the Worker half of phone-use's optional relay. It runs in a Cloudflare account owned by the operator. The Mac's `phone-use relay pair` and `phone-use serve --relay` commands provide the outbound connector. Local stdio, loopback HTTP, and Tailscale access require no Cloudflare account.

## Local development

From the repository root:

```sh
mise exec node@24.18.0 -- npm ci --prefix relay
mise exec node@24.18.0 -- npm run typecheck --prefix relay
mise exec node@24.18.0 -- npm test --prefix relay
```

The tests use Cloudflare's local Worker and Durable Object emulator, including durable storage and WebSocket hibernation. A development `ADMIN_SECRET` must be supplied through a private `.dev.vars` file before using `npm run dev`; do not commit that file. The test configuration supplies an isolated test-only value.

## Deploy to your account

Authenticate Wrangler to your own Cloudflare account and select the desired account in your local Wrangler configuration. Set a long random admin secret with `wrangler secret put ADMIN_SECRET`, then run `npm run deploy` from this directory. The checked-in `wrangler.jsonc` provisions the `MacRelay` SQLite Durable Object binding and migration. It does not provision R2 or a database. Keep the admin secret in a private secret manager. Do not put it in the deployment config, a URL, or a shared shell command.

Open the Worker's root page. Enter the admin secret in the page and a stable Mac ID containing letters, digits, hyphens, or underscores. The page keeps the secret only in memory and sends it in an Authorization header. It provides status and a five-minute pairing token. The token is single-use. On the Mac, run `phone-use relay pair --origin https://YOUR-WORKER --mac-id YOUR-MAC-ID` and enter the token at the private prompt. The daemon credential is stored in a private local config file and is never printed by `relay status`. Start `phone-use serve --relay` to open the authenticated outbound WebSocket alongside the direct HTTP listener. For a loopback test peer only, pairing supports `--allow-insecure-loopback`.

The public MCP endpoint is `https://YOUR-WORKER/mac/{macID}/mcp`. Give each MCP client a separate phone-use client credential with explicit phone scopes. The daemon's versioned hello and credential update messages transmit only SHA-256 digests, scopes, and expiry metadata. The Worker rejects unknown or expired client credentials; the daemon remains the final authority for revocation and device scope. Client credentials are never the pairing or daemon credential.

The admin page's **Revoke daemon** action disconnects the Mac, removes its credential snapshot and catalog, and invalidates the daemon credential. Rotate client credentials using `phone-use credentials revoke` and a replacement client credential on the Mac; the connector sends a replace-all snapshot with a higher revision. For removal, revoke the daemon, remove client credentials, run `phone-use relay remove` on the Mac, and delete the Worker deployment from your Cloudflare account. Upgrades should preserve the DO binding/class and `v1` migration until a deliberate data migration is available. The Worker accepts wire protocol `v: 1`; the daemon hello advertises its catalog version/hash. The shared golden fixture in `fixtures/catalog.json` is generated from the actual Swift MCP tool list and checked in both Swift and Worker tests. Connectors using another wire version cannot dispatch.

## Routing and outcome semantics

The Durable Object is selected by Mac ID. It owns connection routing, not a phone lock. It persists bounded pairing and daemon authentication metadata, connection generation, credential digest/scope snapshots, the versioned tool catalog supplied by the daemon, and short-lived dispatch ID claims. It never stores request bodies, bearer tokens, screenshots, or results. Ordinary MCP image results travel back in the HTTP response; R2 is not required.

Each public request is forwarded once with a Worker-minted dispatch ID and deadline. A claim is committed before sending it to the daemon. Duplicate delivery returns `unknown` without a second send, even after DO reconstruction. No offline queue or automatic mutation retry exists. A disconnected daemon before admission returns `not_started`. A disconnect or timeout after admission returns `unknown` in a JSON-RPC error with HTTP 200 so MCP clients can read it. A completely lost HTTP response is also an unknown outcome. Inspect the phone before deciding whether to issue a mutating command again. These rules do not promise exactly-once execution.

The Worker forwards only the public `Host`, `Authorization`, `Content-Type`, `Accept`, `Origin`, `MCP-Session-Id`, and `MCP-Protocol-Version` headers to the daemon. Cookies, Cloudflare metadata, and unrelated client headers are omitted. The daemon must explicitly allow the Worker's public Host and any intended Origin. JSON-RPC IDs remain raw JSON tokens through routing and unknown-outcome responses, including large numeric and string IDs.

Requests with duplicate top-level JSON-RPC `id` fields receive HTTP 400 before dispatch. Nested fields named `id` do not affect request identity.

Limits are 256 KiB per public request, 384 KiB per relay frame, 192 KiB per result chunk, 32 pending commands per Mac, 8 MiB retained request and result bytes per Mac, and 4,096 live dispatch claims. Deadlines are at most 120 seconds. Expired claims are pruned; live claims are never evicted to admit new work. Pairing expires after five minutes.

Only the admin page is public without a credential. Admin API calls use the separate `ADMIN_SECRET` Bearer header. The Worker has no vendor-managed account requirement beyond the Cloudflare account chosen by the operator. Real account deployment and physical-phone verification remain pending.
