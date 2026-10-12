# Remote MCP access

`phone-use serve` exposes authenticated Streamable HTTP at `http://127.0.0.1:8765/mcp`. The existing `phone-use mcp` stdio command remains offline and does not require remote credentials.

## Start locally

Get exact phone IDs before starting the daemon:

```sh
phone-use list --simulator
phone-use credentials create --phone YOUR-DEVICE-UDID --expires-at 2026-12-31T00:00:00Z
phone-use serve --simulator
```

Use the actual ID returned by `list`; the ID above is illustrative. Repeat `--phone` to authorize multiple explicit IDs. Wildcards and empty scopes are rejected. Creation prints the ID and bearer secret once. Put the secret in your MCP client's secure header configuration as `Authorization: Bearer <secret>`. Do not put secrets in URLs, shell history, logs, or shared client configurations.

Credentials are stored as SHA-256 digests in `~/.config/phone-use/credentials`, a private directory with private files. `--credentials-directory` selects an alternate private store for isolated testing. It does not bypass the global process ownership lock. Credentials can be managed while the daemon owns the phones:

```sh
phone-use credentials list
phone-use credentials revoke CREDENTIAL-ID
```

Revocation applies to the next HTTP request and is checked again before queued phone operations execute. Local action commands and stdio cannot run concurrently with the daemon. Stop the daemon with SIGINT or SIGTERM; it cancels pending work and waits for backend cleanup before releasing ownership.

## Tailscale HTTPS

Keep the daemon on loopback and explicitly allow the HTTPS authority presented by your proxy:

```sh
phone-use serve --simulator --allowed-host mac-name.tailnet-name.ts.net
tailscale serve --bg http://127.0.0.1:8765
```

Use the HTTPS URL printed by Tailscale, with `/mcp` appended, and the bearer header in your remote MCP client. Tailnet membership does not replace the application credential. Configure Tailscale policy to limit which devices/users can reach the service. See the [official Tailscale Serve reference](https://tailscale.com/docs/reference/tailscale-cli/serve) for HTTPS prerequisites and current command options. No Tailscale configuration or second-machine verification has been performed by this change.

## LAN HTTPS proxy

Run an HTTPS reverse proxy on the Mac with a certificate trusted by your client devices. Preserve `Authorization`, `MCP-Session-Id`, `MCP-Protocol-Version`, `Origin`, and the original `Host`. Forward `/mcp` and `/leases/release` to `http://127.0.0.1:8765`, disable request retries and response caching, and permit responses to finish through the 120-second application deadline plus backend cleanup. Set the exact external authority (include a nondefault port) on the daemon:

```sh
phone-use serve --simulator --allowed-host phone.example.internal
```

For browser clients, also set the exact client origin, for example `--allowed-origin https://client.example.internal`. Origins are denied by default. This does not add CORS support: clients needing cross-origin browser fetch require an appropriately configured trusted proxy. Do not allow arbitrary origins. Forwarded-host headers do not bypass the Host check.

Direct non-loopback cleartext HTTP is development-only and requires both explicit flags:

```sh
phone-use serve --simulator --host 192.168.1.10 --allow-remote --insecure-development-http
```

Anyone who can observe that HTTP connection can read its bearer secret. Use HTTPS for production and untrusted networks.

## Sessions, cancellation, and control

Clients initialize without a session header, retain the server-generated `MCP-Session-Id`, send `notifications/initialized`, and include that session ID plus the negotiated `MCP-Protocol-Version` on subsequent requests. A session is bound to the credential that created it. Current protocol is `2025-11-25`; supported SDK versions are negotiated during initialization. Idle sessions expire after 15 minutes. Expired sessions return 404 and must be initialized anew.

All MCP requests use POST with JSON content and `Accept: application/json, text/event-stream`. Responses are JSON; GET returns 405. This is the JSON response variant of [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports). There are no SSE/replay buffers, resumable requests, server-to-client requests, or automatic input retries. SDK typed lifecycle/tool values and the same catalog/conversion used by stdio are reused; a bounded explicit session/task owner replaces the SDK's unbounded HTTP transport buffers.

A connection loss does not cancel an action and does not prove it failed to execute. Treat a lost mutation response as an unknown outcome, inspect the phone, and decide explicitly what to do next. Send `notifications/cancelled` with the original `requestId` to cancel queued work. Cancellation or deadline expiry after input starts reports an unknown outcome and waits for backend cleanup. Deadlines and control leases continue advancing while the Mac sleeps. Request IDs are scoped to a session, distinguish strings from numbers, and cannot be reused while active.

A valid mutation claims a 60-second idle control lease for that credential/session. Reads do not renew it. To release your own lease explicitly, POST JSON `{"phone_id":"exact-id"}` to `/leases/release` with the same authorization, session, protocol, content-type and accept headers. A different session cannot release it. DELETE `/mcp` closes an idle session and releases its own leases; active sessions return 409 until their requests finish or are cancelled and cleaned up.

## Resource bounds and adapter API

The listener admits at most 64 connections, consumes one request per connection, closes after the response, and disables further reads during execution. Limits are 16 KiB/64 headers, 256 KiB request body, 2 KiB request URI, 64 sessions, 32 active requests including queued calls, and 8 MiB encoded response. Partial input has a 15-second idle timeout, response writes a 30-second drain timeout, and application requests a 120-second deadline. Input idle timers do not terminate active actions. The dispatcher also bounds each phone queue to 8 and the global queue to 32. Discovery refreshes coalesce into one operation; cancellation removes individual discovery waiters without cancelling other clients.

The relay adapter calls the same `HTTPService.handle(RemoteHTTPRequest, deadline:)` entry point. Headers remain ordered tuples so duplicates cannot disappear before validation. An absolute relay deadline is converted to `MonotonicClock.now` seconds and clamped to 120 seconds. Relay disconnect cancels its owned requests and waits for mutation cleanup; a direct HTTP socket disconnect deliberately does not cancel an action. Neither route retries input automatically. The explicit Host/Origin allowlists remain in force. `HTTPListener` supports port zero and exposes the actual bound `port` for local integration tests.

## Optional user-owned Cloudflare relay

The [Worker package](../relay/README.md) provides the relay endpoint, setup page, and Durable Object routing. Deploy it in your own account, set its admin secret, and use the setup page to create a five-minute pairing token for a stable Mac ID. On the Mac, run:

```sh
phone-use relay pair --origin https://YOUR-WORKER --mac-id YOUR-MAC-ID
phone-use relay status
phone-use serve --relay --simulator
```

`relay pair` reads the one-use token from a hidden terminal prompt or standard input. It never accepts the token as a command-line argument. The resulting daemon secret is stored in `~/.config/phone-use/relay/relay.json`, with a private directory and file; status does not show it. `--relay-config-directory` selects a separate private directory for local development. Plain HTTP is refused except with `relay pair --allow-insecure-loopback` to a loopback test server. The daemon sends its credential snapshot, then polls the local store so `credentials create` and `credentials revoke` reach the Worker. Only SHA-256 client token digests, exact phone scopes, and expiry timestamps leave the Mac in this snapshot. Each request is still authenticated and scoped by the local service.

The public MCP URL is `https://YOUR-WORKER/mac/YOUR-MAC-ID/mcp`; clients use their separate scoped client bearer credentials. `serve --relay` starts both the outbound connector and the direct HTTP listener with the same sessions, dispatcher, leases, and process owner. Relay outages do not stop direct HTTP access. The relay's public Host is allowed from the validated paired origin; browser Origins still require explicit `serve --allowed-origin`. The connector reconnects after ordinary outages, does not replay commands after a disconnect, and stops after daemon revocation. If the local credential store cannot produce a valid relay snapshot, the connector closes the relay socket, reports a generic local diagnostic, and waits until the metadata is valid before reconnecting. Direct access continues to use the local credential store.

To revoke the daemon credential, use **Revoke daemon** on the Worker's admin setup page. To remove the local copy, run `phone-use relay remove`; remove does not revoke the remote daemon credential by itself. Re-pair with a new token after revocation. No Cloudflare deployment or external account verification has been performed by this implementation stage.
