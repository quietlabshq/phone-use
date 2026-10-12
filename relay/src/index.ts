import { DurableObject } from 'cloudflare:workers';
import { bearer, bytes, decode, digest, DuplicateRPCID, encode, failure, LIMITS, readBounded, rpcID, secret, validHeaders, type Catalog, type Credential, type Dispatch, type Envelope, type Failure, type Hello, type ResultChunk, type ResultEnd, type ResultStart } from './protocol';
import { setupHTML } from './setup';

interface Env { MACS: DurableObjectNamespace<MacRelay>; ADMIN_SECRET: string }
interface Pairing { digest: string; expiresAt: number }
interface Metadata {
  pairing?: Pairing;
  daemonDigest?: string;
  generation?: string;
  socketID?: string;
  revision: number;
  credentials: Credential[];
  catalog?: Catalog;
}
interface Claim { id: string; expiresAt: number }
interface Pending {
  rpcID: string;
  requestBytes: number;
  requestID: string;
  generation: string;
  deadline: number;
  retained: number;
  status?: number;
  headers?: [string, string][];
  chunks: Uint8Array[];
  nextSequence: number;
  resolve: (response: Response) => void;
  timer: ReturnType<typeof setTimeout>;
}
const emptyMetadata = (): Metadata => ({ revision: 0, credentials: [] });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAC_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const HEX = /^[0-9a-f]{64}$/;
const FORWARDED_HEADERS = new Set(['accept', 'authorization', 'content-type', 'mcp-protocol-version', 'mcp-session-id', 'origin']);
const noStore = { 'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8' };
const json = (value: unknown, status = 200): Response => new Response(JSON.stringify(value), { status, headers: noStore });
const bad = (status: number): Response => json({ error: status === 401 ? 'Unauthorized' : status === 404 ? 'Not found' : 'Invalid request' }, status);
const duplicateID = (): Response => json({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Duplicate JSON-RPC id' } }, 400);
const equal = (a: string, b: string): boolean => a.length === b.length && [...a].reduce((n, c, i) => n | (c.charCodeAt(0) ^ b.charCodeAt(i)), 0) === 0;
const validCredential = (v: unknown): v is Credential => {
  if (!v || typeof v !== 'object') return false;
  const c = v as Partial<Credential>;
  return typeof c.digest === 'string' && HEX.test(c.digest) && Array.isArray(c.scopes) && c.scopes.length > 0 && c.scopes.length <= 64 && c.scopes.every(s => typeof s === 'string' && s.length > 0 && s.length <= 128 && s !== '*') && (c.expiresAt === null || (typeof c.expiresAt === 'number' && Number.isSafeInteger(c.expiresAt) && c.expiresAt > 0));
};
const validCredentials = (v: unknown): v is Credential[] => Array.isArray(v) && v.length <= LIMITS.credentials && v.every(validCredential) && new Set(v.map(c => c.digest)).size === v.length;
const validCatalog = (v: unknown): v is Catalog => {
  if (!v || typeof v !== 'object') return false;
  const c = v as Partial<Catalog>;
  return typeof c.version === 'string' && c.version.length > 0 && c.version.length <= 64 && typeof c.hash === 'string' && HEX.test(c.hash) && Array.isArray(c.tools) && bytes(JSON.stringify(c)) <= LIMITS.metadata;
};
const validEnvelope = (v: unknown): v is Envelope => {
  if (!v || typeof v !== 'object') return false;
  const e = v as Partial<Envelope>;
  if (e.v !== 1 || typeof e.dispatchID !== 'string' || !UUID.test(e.dispatchID) || typeof e.requestID !== 'string' || !UUID.test(e.requestID) || !Number.isSafeInteger(e.deadline) || (e.path !== '/mcp' && e.path !== '/leases/release') || (e.method !== 'POST' && e.method !== 'DELETE') || !validHeaders(e.headers) || typeof e.body !== 'string') return false;
  if ((e.path === '/leases/release' && e.method !== 'POST') || (e.method === 'DELETE' && e.path !== '/mcp')) return false;
  try { return decode(e.body).byteLength <= LIMITS.request; } catch { return false; }
};
const explicitPhoneID = (envelope: Envelope): string | undefined => {
  try {
    const body = JSON.parse(new TextDecoder().decode(decode(envelope.body))) as Record<string, unknown>;
    const value = envelope.path === '/leases/release'
      ? body.phone_id
      : body.method === 'tools/call'
        ? (body.params as { arguments?: { phone_id?: unknown } } | undefined)?.arguments?.phone_id
        : undefined;
    return typeof value === 'string' ? value : undefined;
  } catch { return undefined; }
};
const frameText = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined;

// Public traffic is deliberately routed through this Worker. DO internal paths are only reached by its binding.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/') return new Response(setupHTML, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'content-security-policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" } });
    const admin = /^\/admin\/macs\/([A-Za-z0-9_-]{1,64})(?:\/(pair|revoke|status))?$/.exec(url.pathname);
    if (admin) {
      const token = bearer(request.headers);
      if (!token || !env.ADMIN_SECRET || !equal(await digest(token), await digest(env.ADMIN_SECRET))) return bad(401);
      const [, macID, action = 'status'] = admin;
      if (!MAC_ID.test(macID)) return bad(404);
      if ((action === 'status' && request.method !== 'GET') || (action !== 'status' && request.method !== 'POST')) return bad(405);
      return env.MACS.get(env.MACS.idFromName(macID)).fetch(new Request(`https://internal/_admin/${action}`, { method: request.method }));
    }
    const pair = /^\/daemon\/([A-Za-z0-9_-]{1,64})\/(pair|connect)$/.exec(url.pathname);
    if (pair) {
      const [, macID, action] = pair;
      if (!MAC_ID.test(macID)) return bad(404);
      if ((action === 'pair' && request.method !== 'POST') || (action === 'connect' && request.method !== 'GET')) return bad(405);
      const token = bearer(request.headers);
      if (!token) return bad(401);
      if (action === 'connect' && request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return bad(426);
      const target = new Request(`https://internal/_daemon/${action}`, { method: request.method, headers: { authorization: `Bearer ${token}`, ...(action === 'connect' ? { upgrade: 'websocket' } : {}) } });
      return env.MACS.get(env.MACS.idFromName(macID)).fetch(target);
    }
    const publicPath = /^\/mac\/([A-Za-z0-9_-]{1,64})(\/mcp|\/leases\/release)$/.exec(url.pathname);
    if (!publicPath) return bad(404);
    const [, macID, path] = publicPath;
    if (!MAC_ID.test(macID) || !((path === '/mcp' && (request.method === 'POST' || request.method === 'DELETE')) || (path === '/leases/release' && request.method === 'POST'))) return bad(405);
    if (!bearer(request.headers)) return bad(401);
    const dispatchID = crypto.randomUUID(), requestID = crypto.randomUUID();
    const deadline = Date.now() + LIMITS.deadline;
    let body: Uint8Array;
    try { body = await readBounded(request, LIMITS.request); } catch { return bad(413); }
    let id = 'null';
    try { if (path === '/mcp') id = rpcID(body); }
    catch (error) { if (error instanceof DuplicateRPCID) return duplicateID(); throw error; }
    const headers: [string, string][] = [['host', url.host], ...[...request.headers].filter(([name]) => FORWARDED_HEADERS.has(name.toLowerCase()))];
    if (!validHeaders(headers)) return bad(431);
    const envelope: Envelope = { v: 1, dispatchID, requestID, deadline, method: request.method, path: path as Envelope['path'], headers, body: encode(body) };
    const payload = JSON.stringify(envelope);
    if (bytes(payload) > LIMITS.frame) return bad(413);
    // This stream is one-shot. There is no application retry if the DO fetch fails.
    const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new TextEncoder().encode(payload)); controller.close(); } });
    try {
      return await env.MACS.get(env.MACS.idFromName(macID)).fetch(new Request('https://internal/_dispatch', { method: 'POST', headers: { authorization: request.headers.get('authorization') ?? '' }, body: stream, duplex: 'half' } as RequestInit));
    } catch {
      return failure('unknown', id, 200);
    }
  },
};

export class MacRelay extends DurableObject<Env> {
  private meta: Metadata = emptyMetadata();
  private socket?: WebSocket;
  private pending = new Map<string, Pending>();
  private retained = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.meta = await ctx.storage.get<Metadata>('meta') ?? emptyMetadata();
      for (const ws of ctx.getWebSockets()) {
        const attachment = ws.deserializeAttachment() as { socketID?: string; generation?: string } | null;
        if (this.meta.daemonDigest && attachment?.socketID === this.meta.socketID && attachment?.generation === this.meta.generation) this.socket = ws;
        else ws.close(4001, 'Stale connection');
      }
    });
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === '/_admin/status') return json({ paired: !!this.meta.daemonDigest, connected: !!this.socket, pairingExpiresAt: this.meta.pairing?.expiresAt ?? null, generation: this.meta.generation ?? null, revision: this.meta.revision, catalog: this.meta.catalog ?? null, credentialCount: this.meta.credentials.length });
    if (path === '/_admin/pair') {
      const token = secret();
      this.meta.pairing = { digest: await digest(token), expiresAt: Date.now() + 5 * 60_000 };
      await this.ctx.storage.put('meta', this.meta);
      return json({ token, expiresAt: this.meta.pairing.expiresAt });
    }
    if (path === '/_admin/revoke') {
      this.failPending('unknown');
      this.socket?.close(4001, 'Revoked');
      this.socket = undefined;
      this.meta = emptyMetadata();
      await this.ctx.storage.put('meta', this.meta);
      return json({ revoked: true });
    }
    if (path === '/_daemon/pair') {
      const token = bearer(request.headers);
      if (!token || !this.meta.pairing || this.meta.pairing.expiresAt <= Date.now() || !equal(await digest(token), this.meta.pairing.digest)) return bad(401);
      const daemon = secret();
      const next = { ...emptyMetadata(), daemonDigest: await digest(daemon) };
      // Storage transaction makes consumption single-use even for concurrent delivery.
      const accepted = await this.ctx.storage.transaction(async tx => {
        const current = await tx.get<Metadata>('meta') ?? emptyMetadata();
        if (!current.pairing || current.pairing.expiresAt <= Date.now() || !equal(current.pairing.digest, await digest(token))) return false;
        await tx.put('meta', next);
        return true;
      });
      if (!accepted) return bad(401);
      this.failPending('unknown');
      this.socket?.close(4001, 'Repaired');
      this.socket = undefined;
      this.meta = next;
      return json({ daemonSecret: daemon });
    }
    if (path === '/_daemon/connect') {
      const token = bearer(request.headers);
      if (!token || !this.meta.daemonDigest || !equal(await digest(token), this.meta.daemonDigest) || request.headers.get('upgrade')?.toLowerCase() !== 'websocket') return bad(401);
      const generation = crypto.randomUUID(), socketID = crypto.randomUUID();
      const pair = new WebSocketPair();
      const client = pair[0], server = pair[1];
      this.ctx.acceptWebSocket(server);
      server.serializeAttachment({ socketID, generation });
      this.failPending('unknown');
      this.socket?.close(4001, 'Superseded');
      this.socket = server;
      this.meta = { ...this.meta, generation, socketID, revision: 0, credentials: [], catalog: undefined };
      await this.ctx.storage.put('meta', this.meta);
      server.send(JSON.stringify({ v: 1, type: 'connected', generation }));
      return new Response(null, { status: 101, webSocket: client });
    }
    if (path === '/_dispatch') return this.dispatch(request);
    return bad(404);
  }

  private async dispatch(request: Request): Promise<Response> {
    let payload: Uint8Array;
    try { payload = await readBounded(request, LIMITS.frame); } catch { return bad(413); }
    let value: unknown;
    try { value = JSON.parse(new TextDecoder().decode(payload)); } catch { return bad(400); }
    if (!validEnvelope(value)) return bad(400);
    const envelope = value;
    let id = 'null';
    try { if (envelope.path === '/mcp') id = rpcID(decode(envelope.body)); }
    catch (error) { if (error instanceof DuplicateRPCID) return duplicateID(); throw error; }
    if (envelope.deadline <= Date.now()) return failure('unknown', id, 200);
    if (envelope.deadline > Date.now() + LIMITS.deadline) return failure('not_started', id);
    const token = bearer(request.headers);
    if (!token) return bad(401);
    const tokenDigest = await digest(token);
    const credential = this.meta.credentials.find(c => equal(c.digest, tokenDigest) && (c.expiresAt === null || c.expiresAt > Date.now()));
    if (!credential || !credential.scopes.length) return bad(401);
    const phoneID = explicitPhoneID(envelope);
    if (phoneID && !credential.scopes.includes(phoneID)) return bad(403);
    // Claim before sending. A duplicate after reconstruction cannot execute twice.
    const admission = await this.ctx.storage.transaction(async tx => {
      const claims = (await tx.get<Claim[]>('claims') ?? []).filter(c => c.expiresAt > Date.now());
      if (claims.some(c => c.id === envelope.dispatchID)) return 'duplicate';
      if (!this.socket || !this.meta.generation || this.meta.revision < 1 || this.pending.size >= LIMITS.pending || this.retained + payload.byteLength > LIMITS.retained || claims.length >= LIMITS.claims) return 'not_started';
      claims.push({ id: envelope.dispatchID, expiresAt: envelope.deadline });
      await tx.put('claims', claims);
      return 'claimed';
    });
    if (admission === 'duplicate') return failure('unknown', id, 200);
    if (admission === 'not_started') return failure('not_started', id);
    if (!this.socket || !this.meta.generation || envelope.deadline <= Date.now() || this.pending.size >= LIMITS.pending || this.retained + payload.byteLength > LIMITS.retained) return failure('unknown', id, 200);
    const generation = this.meta.generation;
    return new Promise<Response>(resolve => {
      const timer = setTimeout(() => this.finish(envelope.dispatchID, failure('unknown', id, 200)), Math.max(1, envelope.deadline - Date.now()));
      this.pending.set(envelope.dispatchID, { rpcID: id, requestBytes: payload.byteLength, requestID: envelope.requestID, generation, deadline: envelope.deadline, retained: payload.byteLength, chunks: [], nextSequence: 0, resolve, timer });
      this.retained += payload.byteLength;
      try { this.socket!.send(JSON.stringify({ ...envelope, type: 'dispatch', generation } satisfies Dispatch)); }
      catch { this.finish(envelope.dispatchID, failure('unknown', id, 200)); }
    });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (ws !== this.socket) return;
    const raw = frameText(message);
    if (!raw || bytes(raw) > LIMITS.frame) { ws.close(1009, 'Frame too large'); this.failPending('unknown'); return; }
    let frame: Record<string, unknown>;
    try { frame = JSON.parse(raw); } catch { ws.close(1003, 'Invalid frame'); this.failPending('unknown'); return; }
    if (!frame || frame.v !== 1 || typeof frame.type !== 'string' || frame.generation !== this.meta.generation) return;
    if (frame.type === 'hello') {
      const hello = frame as unknown as Hello;
      if (this.meta.revision !== 0 || hello.revision !== 1 || !validCredentials(hello.credentials) || !validCatalog(hello.catalog) || bytes(raw) > LIMITS.metadata) { ws.close(1003, 'Invalid hello'); return; }
      this.meta = { ...this.meta, revision: 1, credentials: hello.credentials, catalog: hello.catalog };
      await this.ctx.storage.put('meta', this.meta);
      return;
    }
    if (frame.type === 'credentials') {
      if (this.meta.revision < 1 || !Number.isSafeInteger(frame.revision) || frame.revision !== this.meta.revision + 1 || !validCredentials(frame.credentials) || bytes(raw) > LIMITS.metadata) { ws.close(1003, 'Invalid credentials'); this.failPending('unknown'); return; }
      this.meta = { ...this.meta, revision: frame.revision as number, credentials: frame.credentials };
      await this.ctx.storage.put('meta', this.meta);
      return;
    }
    if (typeof frame.dispatchID !== 'string' || !UUID.test(frame.dispatchID)) return;
    const pending = this.pending.get(frame.dispatchID);
    if (!pending || pending.generation !== frame.generation || pending.requestID !== frame.requestID) return;
    if (frame.type === 'failure') {
      const f = frame as unknown as Failure;
      if (f.outcome !== 'not_started' && f.outcome !== 'unknown') return;
      const outcome = pending.status === undefined ? f.outcome : 'unknown';
      this.finish(f.dispatchID, failure(outcome, pending.rpcID, outcome === 'unknown' ? 200 : 503));
    } else if (frame.type === 'result_start') {
      const start = frame as unknown as ResultStart;
      if (pending.status !== undefined || !Number.isInteger(start.status) || start.status < 200 || start.status > 599 || !validHeaders(start.headers)) { this.finish(start.dispatchID, failure('unknown', pending.rpcID, 200)); return; }
      pending.status = start.status;
      pending.headers = start.headers;
    } else if (frame.type === 'result_chunk') {
      const chunk = frame as unknown as ResultChunk;
      if (pending.status === undefined || chunk.sequence !== pending.nextSequence || typeof chunk.body !== 'string') { this.finish(chunk.dispatchID, failure('unknown', pending.rpcID, 200)); return; }
      let data: Uint8Array;
      try { data = decode(chunk.body); } catch { this.finish(chunk.dispatchID, failure('unknown', pending.rpcID, 200)); return; }
      if (data.byteLength > LIMITS.chunk || this.retained + data.byteLength > LIMITS.retained) { this.finish(chunk.dispatchID, failure('unknown', pending.rpcID, 200)); return; }
      pending.nextSequence++;
      pending.chunks.push(data);
      pending.retained += data.byteLength;
      this.retained += data.byteLength;
    } else if (frame.type === 'result_end') {
      const end = frame as unknown as ResultEnd;
      if (pending.status === undefined) { this.finish(end.dispatchID, failure('unknown', pending.rpcID, 200)); return; }
      const headers = new Headers(pending.headers);
      headers.set('cache-control', 'no-store');
      this.finishResult(end.dispatchID, pending, headers);
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> { if (ws === this.socket) { this.socket = undefined; this.failPending('unknown'); } }
  async webSocketError(ws: WebSocket): Promise<void> { if (ws === this.socket) { this.socket = undefined; this.failPending('unknown'); } }
  private finish(dispatchID: string, response: Response): void {
    const pending = this.pending.get(dispatchID);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(dispatchID);
    this.retained -= pending.retained;
    pending.resolve(response);
  }
  private finishResult(dispatchID: string, pending: Pending, headers: Headers): void {
    clearTimeout(pending.timer);
    this.pending.delete(dispatchID);
    this.retained -= pending.requestBytes;
    const chunks = pending.chunks;
    if (pending.status === 204 || pending.status === 205 || pending.status === 304) {
      for (const chunk of chunks) this.retained -= chunk.byteLength;
      pending.resolve(new Response(null, { status: pending.status, headers }));
      return;
    }
    const relay = this;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        const chunk = chunks.shift();
        if (chunk) { relay.retained -= chunk.byteLength; controller.enqueue(chunk); }
        if (!chunks.length) controller.close();
      },
      cancel() { for (const chunk of chunks) relay.retained -= chunk.byteLength; chunks.length = 0; },
    }, { highWaterMark: 0 });
    pending.resolve(new Response(body, { status: pending.status, headers }));
  }
  private failPending(outcome: 'not_started' | 'unknown'): void { for (const [id, pending] of this.pending) this.finish(id, failure(outcome, pending.rpcID, outcome === 'unknown' ? 200 : 503)); }
}
