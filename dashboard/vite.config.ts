import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Relative base so the same build works under `vite dev` and FastAPI's /analytics mount.
export default defineConfig({
  base: './',
  plugins: [react(), tailwindcss()],
  resolve: { alias: { '@': path.resolve(import.meta.dirname, './src') } },
  // ponytail: one ~850 kB bundle served from localhost; split Recharts out if this ever ships over a network.
  build: { chunkSizeWarningLimit: 1000 },
})
