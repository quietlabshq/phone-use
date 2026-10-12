import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';
export default defineConfig({ test: { testTimeout: 40_000 }, plugins: [cloudflareTest({ wrangler: { configPath: './wrangler.jsonc' }, miniflare: { bindings: { ADMIN_SECRET: 'test-admin-secret-only' } } })] });
