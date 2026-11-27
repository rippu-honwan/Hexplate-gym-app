import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Root base because FastAPI serves the compiled build directly at `/` (same as `vite dev`).
export default defineConfig({
  base: '/',
  plugins: [react(), tailwindcss()],
  resolve: { alias: { '@': path.resolve(import.meta.dirname, './src') } },
  // ponytail: one ~850 kB bundle served from localhost; split Recharts out if this ever ships over a network.
  build: { chunkSizeWarningLimit: 1000 },
})
