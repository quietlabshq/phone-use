export const LIMITS = { request: 256 * 1024, frame: 384 * 1024, chunk: 192 * 1024, retained: 8 * 1024 * 1024, pending: 32, claims: 4096, deadline: 120_000, metadata: 128 * 1024, credentials: 256, headers: 16 * 1024 } as const;
export type HeadersList = [string, string][];
export interface Credential { digest: string; scopes: string[]; expiresAt: number | null }
export interface Catalog { version: string; hash: string; tools: unknown[] }
export interface Envelope { v: 1; dispatchID: string; requestID: string; deadline: number; method: string; path: '/mcp' | '/leases/release'; headers: HeadersList; body: string }
export interface Dispatch extends Envelope { type: 'dispatch'; generation: string }
export interface Hello { v: 1; type: 'hello'; generation: string; revision: number; credentials: Credential[]; catalog: Catalog }
export interface Credentials { v: 1; type: 'credentials'; generation: string; revision: number; credentials: Credential[] }
export interface ResultStart { v: 1; type: 'result_start'; generation: string; dispatchID: string; requestID: string; status: number; headers: HeadersList }
export interface ResultChunk { v: 1; type: 'result_chunk'; generation: string; dispatchID: string; requestID: string; sequence: number; body: string }
export interface ResultEnd { v: 1; type: 'result_end'; generation: string; dispatchID: string; requestID: string }
export interface Failure { v: 1; type: 'failure'; generation: string; dispatchID: string; requestID: string; outcome: 'not_started' | 'unknown' }
export const encode = (bytes: Uint8Array): string => { let text = ''; for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i, i + 8192)); return btoa(text); };
export function decode(value: string): Uint8Array { if (typeof value !== 'string' || value.length % 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw new Error('Invalid base64'); return Uint8Array.from(atob(value), c => c.charCodeAt(0)); }
export const bytes = (value: string): number => new TextEncoder().encode(value).length;
export const digest = async (value: string): Promise<string> => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))), b => b.toString(16).padStart(2, '0')).join('');
export const secret = (): string => encode(crypto.getRandomValues(new Uint8Array(32))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
export const bearer = (headers: Headers): string | undefined => /^Bearer ([A-Za-z0-9._~+/-]+={0,})$/.exec(headers.get('authorization') ?? '')?.[1];
export function validHeaders(value: unknown): value is HeadersList { return Array.isArray(value) && value.length <= 128 && bytes(JSON.stringify(value)) <= LIMITS.headers && value.every(h => Array.isArray(h) && h.length === 2 && typeof h[0] === 'string' && typeof h[1] === 'string' && /^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(h[0]) && !/[\r\n\0]/.test(h[1])); }
export async function readBounded(request: Request, limit: number): Promise<Uint8Array> { const reader = request.body?.getReader(); if (!reader) return new Uint8Array(); const chunks: Uint8Array[] = []; let size = 0; try { while (true) { const item = await reader.read(); if (item.done) break; size += item.value.byteLength; if (size > limit) { await reader.cancel(); throw new Error('Body too large'); } chunks.push(item.value); } } finally { reader.releaseLock(); } const output = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.byteLength; } return output; }
// Extract only the top-level JSON-RPC ID token. Never round a numeric ID through JSON.parse/stringify.
export class DuplicateRPCID extends Error {}

// Keep the raw JSON token so large numeric IDs never pass through JS number precision.
export function rpcID(body: Uint8Array): string {
  const source = new TextDecoder().decode(body);
  try { JSON.parse(source); } catch { return 'null'; }
  let depth = 0;
  let seen = false;
  let id = 'null';
  for (let i = 0; i < source.length; i++) {
    if (source[i] === '"') {
      const start = i++;
      while (i < source.length) {
        if (source[i] === '\\') i += 2;
        else if (source[i] === '"') break;
        else i++;
      }
      if (depth !== 1 || JSON.parse(source.slice(start, i + 1)) !== 'id') continue;
      let j = i + 1;
      while (j < source.length && /\s/.test(source[j])) j++;
      if (source[j++] !== ':') continue;
      if (seen) throw new DuplicateRPCID('Duplicate top-level JSON-RPC id');
      seen = true;
      while (j < source.length && /\s/.test(source[j])) j++;
      const match = /^("(?:[^"\\]|\\.)*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|null)/.exec(source.slice(j));
      if (match) id = match[0];
    } else if (source[i] === '{' || source[i] === '[') depth++;
    else if (source[i] === '}' || source[i] === ']') depth--;
  }
  return id;
}
export function failure(outcome: 'not_started' | 'unknown', id = 'null', status = 503): Response { return new Response(`{"jsonrpc":"2.0","id":${id},"error":{"code":-32000,"message":"Relay ${outcome}","data":{"outcome":"${outcome}","retrySafe":${outcome === 'not_started'}}}}`, { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } }); }
