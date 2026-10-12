# Remote access implementation notes

Richard authorized the code and all locally testable parts of Tasks 13-14 on 2026-09-29. No deployment, new account credentials, second machine, APNs, or physical device is required for this phase's implementation. Those external checks remain explicit handoff items.

## Current status

Task 13 and the locally testable parts of Task 14 are implemented, reviewed, and verified. The release daemon and local Wrangler Worker were exercised together against the iPhone 17 simulator. The historical shutdown documents remain available as records; do not restore the scaffold patch again. See [verification results](../../verification.md), [remote access setup and external status](../../remote-access.md), [Worker deployment instructions](../../../relay/README.md), and the [physical-device test day](../../test-day.md).

## Historical shutdown checkpoint

At shutdown on 2026-09-29, Task 13 was implemented, reviewed, and locally verified; Task 14 remained incomplete. See [the exact checkpoint and recovery instructions](../../handoffs/2026-09-29-shutdown.md) for the state at that time. The relay implementation has since landed.

## Prerequisite

Preserve literal JSON strings at the MCP boundary. SDK 0.12.1 eagerly converts data URLs to binary values and loses their original encoding before typed method dispatch. Use a documented, pinned source correction with its upstream license, and real wire-decoding regression tests. Do not reconstruct a different data URL in the tool adapter.

## Task 13 implementation sequence

- [x] Add process ownership covering CLI actions, standalone stdio, and calibration, with a reusable guard for the forthcoming daemon. A nonblocking per-user advisory file lock held for the process lifetime is an acceptable conservative boundary. Never remove the locked inode. Conflicts fail clearly and direct users to the daemon endpoint or stopping the owner. Test contention and crash release with isolated paths.
- [x] Add credential persistence with random 256-bit tokens, SHA-256 digests, stable IDs, explicit phone scopes, expiry, revocation, and restrictive directory/file permissions. Print bearer secrets only when created. Reauthenticate requests and queued actions so revocation affects existing sessions.
- [x] Extend the existing dispatcher with request identity, device scope, session identity, and deadlines. Filter discovery before implicit device selection; never leak unauthorized device names through hints or errors.
- [x] Share implicit per-phone control leases across all routes. The first mutating action obtains a 60-second idle lease for its credential/session. Conflicting sessions fail clearly. Screenshots share action serialization but do not require control ownership. Expiry must never permit overlapping input. Provide explicit authenticated release and inject the clock for deterministic tests.
- [x] Bound and make the dispatcher queue cancellable: at most 8 waiting calls per phone and 32 globally by default. Remove canceled waiters and recheck deadline, authorization, and lease after acquiring the action lock. Keep complete macros inside the lock. Never infer that an interrupted mutation did not run.
- [x] Add a bounded SwiftNIO HTTP adapter and explicit direct NIO dependency. The SDK provides HTTP MCP transports, not a socket listener. Keep request state isolated per authenticated session; shared transport instances can cross-deliver equal JSON-RPC IDs from different clients. Use SDK request/result types and the shared MCP tool conversion with explicit bounded session/task ownership. The vendored stateful transport retains an unbounded SSE replay history, so return ordinary JSON responses. Streamable HTTP permits JSON responses and GET 405; session ownership remains in the local service.
- [x] Add authenticated `phone-use serve`, local credential commands, and session management. Default to `127.0.0.1:8765`; require explicit opt-in for remote binds and plain insecure development LAN access. Validate Host/Origin, duplicate sensitive headers, session ownership, protocol, and request IDs. Bound headers, bodies, sessions, queued requests, and result streams; support cancellation/backpressure.
- [x] Verify real localhost HTTP initialization, catalog, screenshots, actions, invalid credentials, scope, revocation, duplicate IDs across sessions, leases, expiry, bounded queues, request cancellation, ownership conflicts, and standalone stdio compatibility. Run the simulator flow through the actual listener.
- [x] Document encrypted Tailscale Serve and LAN reverse-proxy TLS routes. Mark real second-machine/Tailscale verification pending because it requires additional access.

## Task 14 implementation sequence

- [x] Add a versioned relay envelope with request IDs, connection generation, absolute deadlines converted to local monotonic deadlines, catalog/version exchange, bounded frames/queues/stream totals, and explicit not-started versus unknown execution outcomes.
- [x] Add an optional outbound daemon WebSocket connection independent of the direct listener. Use capped exponential reconnect backoff with jitter; stop retrying revoked credentials. Never resend an in-flight mutation after disconnect. Feed relay requests through the same authentication, sessions, dispatcher, leases, and process owner as direct HTTP.
- [x] Add a deployable Cloudflare Worker and Durable Object per Mac. The DO owns connection routing and bounded pending requests, never device locks or durable command replay. Route ordinary MCP images directly without required R2 or a database.
- [x] Add admin-authenticated, single-use pairing secrets with five-minute expiry and separate revocable daemon credentials. Client credentials remain authoritative locally; synchronize only their digests/scopes so the relay can reject unauthorized traffic early, and still revalidate at the daemon.
- [x] Add a setup/status page, deployment configuration, and documentation for pairing, MCP URL, revocation, upgrades, and removal. Use the daemon's versioned catalog rather than a second handwritten tool catalog.
- [x] Test the Worker/DO using the local Cloudflare emulator, including storage, pairing, expiry, revocation, stale generations, disconnect/restart, bounded payloads, and unknown outcomes. Verify daemon/direct operation during relay outage and combined direct/relay clients against the simulator.
- [ ] Keep deployment into a real Cloudflare account, second-machine access, Tailscale verification, and physical-device repetition as documented external checks. The Worker persists bounded pairing, routing, credential, catalog, and short-lived dispatch-claim metadata; it does not persist command bodies, results, screenshots, or other media. R2 or a separate database is not required. Any future saved-media storage remains optional with separate retention/access controls.

## Review focus

Cross-session JSON-RPC IDs must not collide. Device scope must apply before default selection. Queued calls must revalidate revocation and deadline. Expired leases cannot interrupt ownership of a running action. A lost response cannot trigger automatic mutation replay. Direct access must survive relay failure. No bearer secrets enter URLs, logs, error bodies, or public setup output.

## HTTP implementation findings

The pinned SDK stateful transport retains every SSE event in `storedEvents`, and its response streams have unbounded default buffers. Its stateless transport has uncancellable response continuations. The SDK server also does not cancel its pending handler tasks in `stop()`. A bounded HTTP service using the SDK request/result types avoids carrying these behaviors into the daemon; do not duplicate the tool catalog or dispatcher. Keep request IDs isolated by session and reject duplicate active IDs. The service must retain per-request identity/deadline context, own and clean up canceled tasks, bound inbound messages/results, and arrange explicit cancellation/deadline handling. Real SDK HTTP-client interoperability tests verify the lifecycle implementation.

An HTTP disconnect is not evidence that input did not run. The [2025-11-25 MCP transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) allows JSON responses, optional GET streams, and optional replay. This implementation does not need response replay or automatic command retry. Preserve unknown-outcome reporting and distinguish explicit cancellation from a lost connection.

## Relay lifecycle findings

Use the Durable Object hibernation WebSocket API. Persist only bounded pairing/daemon credential metadata, connection generation, client digest/scope snapshots, and the versioned catalog. Keep the socket attachment small: identifiers and metadata revisions, below the 16 KiB attachment limit. On wake, restore a socket only after checking its attachment against current stored authorization. See [Cloudflare WebSocket guidance](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).

Pending HTTP handlers and their deadline timers keep active commands out of ordinary idle hibernation. Keep request bodies, response buffers, screenshots, timers, and resolvers in memory only. Bound each Mac to 32 pending requests and 8 MiB aggregate retained payload, in addition to individual frame/body limits. Replace credential snapshots atomically with increasing revisions; do not merge revoked credentials back into existence. The daemon still revalidates every request.

A hard Durable Object restart may prevent cleanup callbacks from running. The outer Worker must turn caught routing failures into a conservative unknown-outcome response, and documentation must explain that a completely lost response is also unknown. No automatic mutation replay or exactly-once guarantee is possible. Idle wake restoration, stale generations, concurrent replacement sockets, late responses, revocation before wake, and oversized post-execution results all need local tests.

Mint each dispatch ID and absolute deadline in the outer Worker, then forward a bounded one-shot `ReadableStream` body without an application retry. Current [workerd retry handling](https://github.com/cloudflare/workerd/blob/main/src/workerd/api/actor-call-retry.c++) fences delivered requests, but also keep a bounded, short-lived DO claim of dispatch ID and expiry before sending over WebSocket. Duplicate claims return an unknown outcome without forwarding. This operational metadata contains no command body, bearer token, image, or result and is not a replay queue. Reject expired requests before admission and never evict an unexpired claim to make room. Test duplicate delivery across DO reconstruction.
