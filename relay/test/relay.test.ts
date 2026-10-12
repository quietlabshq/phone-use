import { abortAllDurableObjects, env, SELF, evictDurableObject, runInDurableObject } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { bearer, digest, encode, rpcID } from '../src/protocol';
import worker from '../src/index';
import catalogFixture from '../fixtures/catalog.json';

const base = 'https://relay.example';
let mac = 'test-mac';
const admin = 'test-admin-secret-only';
const adminPath = () => `${base}/admin/macs/${mac}`;
const request = (url: string, method: string, token?: string, body?: string): Request => new Request(url, { method, headers: token ? { authorization: `Bearer ${token}` } : {}, body });
const adminCall = (action: string, method = 'POST') => SELF.fetch(request(`${adminPath()}/${action}`, method, admin));
const statusOf = async (response: Response): Promise<number> => { const status = response.status; await response.arrayBuffer(); return status; };
const stub = () => (env as unknown as { MACS: DurableObjectNamespace }).MACS.get((env as unknown as { MACS: DurableObjectNamespace }).MACS.idFromName(mac));
const waitMessage = (socket: WebSocket): Promise<Record<string, unknown>> => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('WebSocket message timeout')), 2000);
  socket.addEventListener('message', event => { clearTimeout(timer); resolve(JSON.parse(event.data as string)); }, { once: true });
});
const pair = async () => {
  const created = await adminCall('pair');
  expect(created.status).toBe(200);
  const { token, expiresAt } = await created.json() as { token: string; expiresAt: number };
  const response = await SELF.fetch(request(`${base}/daemon/${mac}/pair`, 'POST', token));
  expect(response.status).toBe(200);
  return { token, expiresAt, daemonSecret: (await response.json() as { daemonSecret: string }).daemonSecret };
};
const connect = async (daemonSecret: string) => {
  const response = await SELF.fetch(new Request(`${base}/daemon/${mac}/connect`, { headers: { authorization: `Bearer ${daemonSecret}`, upgrade: 'websocket' } }));
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  socket.accept();
  const connected = await waitMessage(socket);
  expect(connected.type).toBe('connected');
  return { socket, generation: connected.generation as string };
};
const waitForRevision = async (revision: number) => {
  await vi.waitFor(async () => {
    const response = await adminCall('status', 'GET');
    expect((await response.json() as { revision: number }).revision).toBe(revision);
  }, { timeout: 2000, interval: 10 });
};
const hello = async (socket: WebSocket, generation: string, clientToken: string) => {
  socket.send(JSON.stringify({ v: 1, type: 'hello', generation, revision: 1, credentials: [{ digest: await digest(clientToken), scopes: ['PHONE-1'], expiresAt: null }], catalog: { version: 'test-1', hash: 'a'.repeat(64), tools: [{ name: 'phone_screenshot' }] } }));
  await waitForRevision(1);
};

beforeEach(() => { mac = `test-${crypto.randomUUID()}`; });
afterEach(async () => { await statusOf(await adminCall('revoke')); });

describe('relay protocol', () => {
  it('accepts the Swift MCP catalog golden fixture unchanged', async () => {
    expect(await digest(JSON.stringify(catalogFixture.tools))).toBe(catalogFixture.hash);
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    socket.send(JSON.stringify({ v: 1, type: 'hello', generation, revision: 1, credentials: [], catalog: { ...catalogFixture, version: 'phone-use-0.1.0' } }));
    await waitForRevision(1);
    const status = await adminCall('status', 'GET');
    expect((await status.json() as { catalog: unknown }).catalog).toEqual({ ...catalogFixture, version: 'phone-use-0.1.0' });
    socket.close();
  });
  it('accepts the exact RFC6750 base64 token and preserves large JSON-RPC IDs', () => {
    expect(bearer(new Headers({ authorization: 'Bearer A+/9==' }))).toBe('A+/9==');
    expect(rpcID(new TextEncoder().encode('{"params":{"id":3},"id":900719925474099312345,"method":"x"}'))).toBe('900719925474099312345');
  });

  it('rejects duplicate top-level JSON-RPC IDs before dispatch while allowing nested IDs', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    await hello(socket, generation, 'client-token');
    const body = '{"jsonrpc":"2.0","id":1,"params":{"id":3},"id":2,"method":"tools/call"}';
    socket.addEventListener('message', event => {
      const dispatch = JSON.parse(event.data as string) as { type: string; dispatchID: string; requestID: string };
      if (dispatch.type === 'dispatch') socket.send(JSON.stringify({ v: 1, type: 'failure', generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: 'unknown' }));
    });
    const response = await SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', 'client-token', body));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Duplicate JSON-RPC id' } });
    expect(await runInDurableObject(stub(), async (_instance, state) => state.storage.get('claims'))).toBeUndefined();
    socket.close();
  });

  it('consumes pairing once, expires it, and revokes the distinct daemon credential', async () => {
    const created = await adminCall('pair');
    const { token } = await created.json() as { token: string };
    const first = await SELF.fetch(request(`${base}/daemon/${mac}/pair`, 'POST', token));
    const { daemonSecret } = await first.json() as { daemonSecret: string };
    expect(daemonSecret).not.toBe(token);
    expect(await statusOf(await SELF.fetch(request(`${base}/daemon/${mac}/pair`, 'POST', token)))).toBe(401);
    const status = await adminCall('status', 'GET');
    expect((await status.json() as { paired: boolean }).paired).toBe(true);
    await (await adminCall('revoke')).arrayBuffer();
    expect(await statusOf(await SELF.fetch(new Request(`${base}/daemon/${mac}/connect`, { headers: { authorization: `Bearer ${daemonSecret}`, upgrade: 'websocket' } })))).toBe(401);
    const fresh = await adminCall('pair');
    const freshToken = (await fresh.json() as { token: string }).token;
    await runInDurableObject(stub(), async (_instance, state) => {
      const meta = await state.storage.get<Record<string, unknown>>('meta');
      await state.storage.put('meta', { ...meta, pairing: { digest: await digest(freshToken), expiresAt: Date.now() - 1 } });
    });
    await evictDurableObject(stub());
    expect((await SELF.fetch(request(`${base}/daemon/${mac}/pair`, 'POST', freshToken))).status).toBe(401);
  });

  it('rejects a daemon connect request without a WebSocket upgrade', async () => {
    const { daemonSecret } = await pair();
    const response = await SELF.fetch(request(`${base}/daemon/${mac}/connect`, 'GET', daemonSecret));
    expect(response.status).toBe(426);
    await response.arrayBuffer();
  });

  it('routes authenticated MCP results, including ordinary image bytes, and rejects revoked clients', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'A+/9==';
    await hello(socket, generation, client);
    const body = '{"jsonrpc":"2.0","id":900719925474099312345,"method":"tools/call","params":{"name":"phone_screenshot"}}';
    const resultPromise = SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, body));
    const dispatch = await waitMessage(socket);
    expect(dispatch.type).toBe('dispatch');
    expect(dispatch.path).toBe('/mcp');
    expect(dispatch.headers).toContainEqual(['host', 'relay.example']);
    const image = JSON.stringify({ jsonrpc: '2.0', id: 'image', result: { content: [{ type: 'image', data: encode(new Uint8Array([1, 2, 3])), mimeType: 'image/png' }] } });
    const common = { v: 1, generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID };
    socket.send(JSON.stringify({ ...common, type: 'result_start', status: 200, headers: [['content-type', 'application/json']] }));
    socket.send(JSON.stringify({ ...common, type: 'result_chunk', sequence: 0, body: encode(new TextEncoder().encode(image)) }));
    socket.send(JSON.stringify({ ...common, type: 'result_end' }));
    const result = await resultPromise;
    expect(result.status).toBe(200);
    expect(await result.text()).toBe(image);
    socket.send(JSON.stringify({ v: 1, type: 'credentials', generation, revision: 2, credentials: [] }));
    await waitForRevision(2);
    expect((await SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, body))).status).toBe(401);
    socket.close();
  });

  it('forwards only MCP protocol headers and the external Host', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const pending = SELF.fetch(new Request(`${base}/mac/${mac}/mcp`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${client}`,
        'mcp-session-id': 'session-1',
        'mcp-protocol-version': '2025-11-25',
        origin: 'https://client.example',
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
        cookie: 'private-cookie',
        'cf-ray': 'edge-metadata',
        'x-custom': 'unrelated',
      },
      body: '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
    }));
    const dispatch = await waitMessage(socket);
    expect(dispatch.headers).toEqual([
      ['host', 'relay.example'],
      ['accept', 'application/json, text/event-stream'],
      ['authorization', `Bearer ${client}`],
      ['content-type', 'application/json'],
      ['mcp-protocol-version', '2025-11-25'],
      ['mcp-session-id', 'session-1'],
      ['origin', 'https://client.example'],
    ]);
    socket.send(JSON.stringify({ v: 1, type: 'failure', generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: 'not_started' }));
    await (await pending).arrayBuffer();
    socket.close();
  });

  it('preserves a large JSON-RPC ID in an unknown-outcome response', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const id = 'x'.repeat(9000);
    const pending = SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call' })));
    const dispatch = await waitMessage(socket);
    expect(dispatch.type).toBe('dispatch');
    socket.send(JSON.stringify({ v: 1, type: 'failure', generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: 'unknown' }));
    const response = await pending;
    expect(response.status).toBe(200);
    expect((await response.json() as { id: string }).id).toBe(id);
    socket.close();
  });

  it('preserves a large JSON-RPC ID when the DO fetch itself fails', async () => {
    const id = 'y'.repeat(9000);
    const failingEnv = {
      MACS: {
        idFromName: () => 'test-object',
        get: () => ({ fetch: async () => { throw new Error('DO unavailable'); } }),
      },
    } as unknown as Parameters<typeof worker.fetch>[1];
    const response = await worker.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', 'client-token', JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call' })), failingEnv);
    expect(response.status).toBe(200);
    const result = await response.json() as { id: string; error: { data: { outcome: string } } };
    expect(result.id).toBe(id);
    expect(result.error.data.outcome).toBe('unknown');
  });

  it('keeps dispatch claims through DO reconstruction and reports duplicate outcome as unknown', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const envelope = { v: 1, dispatchID: crypto.randomUUID(), requestID: crypto.randomUUID(), deadline: Date.now() + 10_000, method: 'POST', path: '/mcp', headers: [['authorization', `Bearer ${client}`]], body: encode(new TextEncoder().encode('{"jsonrpc":"2.0","id":7,"method":"tools/list"}')) };
    const forward = () => stub().fetch(new Request('https://internal/_dispatch', { method: 'POST', headers: { authorization: `Bearer ${client}` }, body: JSON.stringify(envelope) }));
    const first = forward();
    const dispatch = await waitMessage(socket);
    socket.send(JSON.stringify({ v: 1, type: 'failure', generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: 'unknown' }));
    const firstResult = await first;
    expect(firstResult.status).toBe(200);
    await firstResult.arrayBuffer();
    await evictDurableObject(stub(), { webSockets: 'hibernate' });
    const duplicate = await forward();
    expect(duplicate.status).toBe(200);
    expect((await duplicate.json() as { error: { data: { outcome: string } } }).error.data.outcome).toBe('unknown');
    socket.close();
  });

  it('reports a claimed duplicate as unknown after a hard DO restart with no daemon', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const envelope = { v: 1, dispatchID: crypto.randomUUID(), requestID: crypto.randomUUID(), deadline: Date.now() + 10_000, method: 'POST', path: '/mcp', headers: [['authorization', `Bearer ${client}`]], body: encode(new TextEncoder().encode('{"jsonrpc":"2.0","id":7,"method":"tools/call"}')) };
    const forward = () => stub().fetch(new Request('https://internal/_dispatch', { method: 'POST', headers: { authorization: `Bearer ${client}` }, body: JSON.stringify(envelope) }));
    const first = forward();
    const dispatch = await waitMessage(socket);
    socket.send(JSON.stringify({ v: 1, type: 'failure', generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: 'unknown' }));
    await (await first).arrayBuffer();
    await abortAllDurableObjects();
    const response = await forward();
    expect(response.status).toBe(200);
    expect((await response.json() as { error: { data: { outcome: string } } }).error.data.outcome).toBe('unknown');
    socket.close();
  });

  it('reports a pending public request as unknown on hard restart and never resends its claim', async () => {
    const { daemonSecret } = await pair();
    const first = await connect(daemonSecret);
    const client = 'client-token';
    await hello(first.socket, first.generation, client);
    const pending = SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, '{"jsonrpc":"2.0","id":42,"method":"tools/call"}'));
    const dispatch = await waitMessage(first.socket);
    const envelope = {
      v: dispatch.v,
      dispatchID: dispatch.dispatchID,
      requestID: dispatch.requestID,
      deadline: dispatch.deadline,
      method: dispatch.method,
      path: dispatch.path,
      headers: dispatch.headers,
      body: dispatch.body,
    };
    await abortAllDurableObjects();
    const lost = await pending;
    expect(lost.status).toBe(200);
    expect((await lost.json() as { id: number; error: { data: { outcome: string } } })).toEqual(expect.objectContaining({ id: 42, error: expect.objectContaining({ data: expect.objectContaining({ outcome: 'unknown' }) }) }));
    const second = await connect(daemonSecret);
    await hello(second.socket, second.generation, client);
    const duplicate = await stub().fetch(new Request('https://internal/_dispatch', { method: 'POST', headers: { authorization: `Bearer ${client}` }, body: JSON.stringify(envelope) }));
    expect(duplicate.status).toBe(200);
    expect((await duplicate.json() as { error: { data: { outcome: string } } }).error.data.outcome).toBe('unknown');
    expect(await runInDurableObject(stub(), instance => (instance as unknown as { pending: Map<string, unknown> }).pending.size)).toBe(0);
    second.socket.close();
  });

  it('does not label an expired duplicate dispatch as safe to retry', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const envelope = { v: 1, dispatchID: crypto.randomUUID(), requestID: crypto.randomUUID(), deadline: Date.now() + 300, method: 'POST', path: '/mcp', headers: [['authorization', `Bearer ${client}`]], body: encode(new TextEncoder().encode('{"jsonrpc":"2.0","id":7,"method":"tools/call"}')) };
    const forward = () => stub().fetch(new Request('https://internal/_dispatch', { method: 'POST', headers: { authorization: `Bearer ${client}` }, body: JSON.stringify(envelope) }));
    const first = forward();
    const dispatch = await waitMessage(socket);
    socket.send(JSON.stringify({ v: 1, type: 'failure', generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: 'unknown' }));
    await (await first).arrayBuffer();
    await new Promise(resolve => setTimeout(resolve, 320));
    const duplicate = await forward();
    expect(duplicate.status).toBe(200);
    expect((await duplicate.json() as { error: { data: { outcome: string; retrySafe: boolean } } }).error.data).toEqual({ outcome: 'unknown', retrySafe: false });
    socket.close();
  });

  it('treats a not_started frame after a response begins as an unknown outcome', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const pending = SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, '{"jsonrpc":"2.0","id":123,"method":"tools/call"}'));
    const dispatch = await waitMessage(socket);
    const common = { v: 1, generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID };
    socket.send(JSON.stringify({ ...common, type: 'result_start', status: 200, headers: [['content-type', 'application/json']] }));
    socket.send(JSON.stringify({ ...common, type: 'failure', outcome: 'not_started' }));
    const response = await pending;
    expect(response.status).toBe(200);
    const result = await response.json() as { id: number; error: { data: { outcome: string; retrySafe: boolean } } };
    expect(result.id).toBe(123);
    expect(result.error.data).toEqual({ outcome: 'unknown', retrySafe: false });
    socket.close();
  });

  it('reports a pending command as unknown when a new daemon generation replaces its socket', async () => {
    const { daemonSecret } = await pair();
    const first = await connect(daemonSecret);
    const client = 'client-token';
    await hello(first.socket, first.generation, client);
    const pending = SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, '{"jsonrpc":"2.0","id":55,"method":"tools/call"}'));
    await waitMessage(first.socket);
    const second = await connect(daemonSecret);
    expect(second.generation).not.toBe(first.generation);
    const response = await pending;
    expect(response.status).toBe(200);
    expect((await response.json() as { id: number; error: { data: { outcome: string } } }).error.data.outcome).toBe('unknown');
    second.socket.close();
  });

  it('restores a hibernated socket only with its current generation and accepts a later credential revision', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    await hello(socket, generation, 'old-client');
    await evictDurableObject(stub(), { webSockets: 'hibernate' });
    socket.send(JSON.stringify({ v: 1, type: 'credentials', generation, revision: 2, credentials: [{ digest: await digest('new-client'), scopes: ['PHONE-1'], expiresAt: null }] }));
    await waitForRevision(2);
    const status = await adminCall('status', 'GET');
    expect(await status.json()).toEqual(expect.objectContaining({ connected: true, revision: 2, credentialCount: 1 }));
    expect(await statusOf(await SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', 'old-client', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')))).toBe(401);
    socket.close();
  });

  it('bounds public request bodies before sending a command', async () => {
    const body = 'x'.repeat(256 * 1024 + 1);
    const response = await SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', 'client-token', body));
    expect(response.status).toBe(413);
    await response.arrayBuffer();
  });

  it('rejects an explicitly out-of-scope phone before dispatch', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"phone_tap","arguments":{"phone_id":"PHONE-2","x":1,"y":1}}}';
    socket.addEventListener('message', event => {
      const dispatch = JSON.parse(event.data as string) as { type: string; dispatchID: string; requestID: string };
      if (dispatch.type === 'dispatch') socket.send(JSON.stringify({ v: 1, type: 'failure', generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: 'unknown' }));
    });
    const response = await SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, body));
    expect(response.status).toBe(403);
    await response.arrayBuffer();
    socket.close();
  });

  it('admits exactly 32 simultaneous commands and rejects 8 excess requests', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const sent: Record<string, unknown>[] = [];
    socket.addEventListener('message', event => { sent.push(JSON.parse(event.data as string)); });
    const completed: { status: number; outcome: string }[] = [];
    const jobs = Array.from({ length: 40 }, (_, i) => SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, `{"jsonrpc":"2.0","id":${i},"method":"tools/call"}`)).then(async response => {
      const status = response.status;
      const outcome = (await response.json() as { error: { data: { outcome: string } } }).error.data.outcome;
      const result = { status, outcome };
      completed.push(result);
      return result;
    }));
    await vi.waitFor(() => expect(completed).toHaveLength(8), { timeout: 5000, interval: 10 });
    await vi.waitFor(() => expect(sent.filter(frame => frame.type === 'dispatch')).toHaveLength(32), { timeout: 5000, interval: 10 });
    expect(completed).toEqual(Array(8).fill({ status: 503, outcome: 'not_started' }));
    socket.close();
    const results = await Promise.all(jobs);
    expect(results.filter(result => result.status === 503)).toHaveLength(8);
    expect(results.filter(result => result.status === 200 && result.outcome === 'unknown')).toHaveLength(32);
  });

  it('counts response chunks while pending and releases them after transfer', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const pending = SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'));
    const dispatch = await waitMessage(socket);
    const common = { v: 1, generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID };
    socket.send(JSON.stringify({ ...common, type: 'result_start', status: 200, headers: [['content-type', 'application/json']] }));
    socket.send(JSON.stringify({ ...common, type: 'result_chunk', sequence: 0, body: encode(new TextEncoder().encode('{"result":"abc"}')) }));
    await vi.waitFor(async () => expect(await runInDurableObject(stub(), instance => (instance as unknown as { retained: number }).retained)).toBeGreaterThan(0), { timeout: 2000, interval: 10 });
    socket.send(JSON.stringify({ ...common, type: 'result_end' }));
    const response = await pending;
    expect(await response.text()).toBe('{"result":"abc"}');
    const released = await runInDurableObject(stub(), instance => (instance as unknown as { retained: number }).retained);
    expect(released).toBe(0);
    socket.close();
  });

  it('reports an oversized post-execution result as unknown and releases its retained bytes', async () => {
    const { daemonSecret } = await pair();
    const { socket, generation } = await connect(daemonSecret);
    const client = 'client-token';
    await hello(socket, generation, client);
    const pending = SELF.fetch(request(`${base}/mac/${mac}/mcp`, 'POST', client, '{"jsonrpc":"2.0","id":17,"method":"tools/call"}'));
    const dispatch = await waitMessage(socket);
    const common = { v: 1, generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID };
    socket.send(JSON.stringify({ ...common, type: 'result_start', status: 200, headers: [['content-type', 'application/json']] }));
    const body = encode(new Uint8Array(192 * 1024));
    for (let sequence = 0; sequence < 43; sequence++) socket.send(JSON.stringify({ ...common, type: 'result_chunk', sequence, body }));
    const response = await pending;
    expect(response.status).toBe(200);
    const result = await response.json() as { id: number; error: { data: { outcome: string } } };
    expect(result.id).toBe(17);
    expect(result.error.data.outcome).toBe('unknown');
    expect(await runInDurableObject(stub(), instance => (instance as unknown as { retained: number }).retained)).toBe(0);
    socket.close();
  });
});
