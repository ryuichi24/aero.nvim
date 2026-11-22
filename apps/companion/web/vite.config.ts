import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: { alias: { '@': new URL('./src', import.meta.url).pathname } },
  plugins: [react(), tailwindcss()],
  worker: { format: 'es' },
  server: {
    proxy: { '/api': { target: 'http://127.0.0.1:8765', changeOrigin: false } },
  },
  test: { environment: 'jsdom', restoreMocks: true, setupFiles: ['./src/test/setup.ts'] },
});
