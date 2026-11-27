# Hexplate Analytics Dashboard

Vite + React + TypeScript + Tailwind CSS v4 + shadcn/ui + Recharts. Compiled on the Mac to static
files in `dist/`, which the FastAPI server serves read-only at `/` (localhost only; legacy
`/analytics` URLs redirect to `/`). The server machine never runs Node or `vite build`.

```bash
npm install
npm run dev          # local development
npm run build        # type-check (tsc -b) and write dist/
npm run check:data   # assertions for the aggregation layer (Node 22)
```

The server looks for the build at `../dashboard/dist`, or at `$HEXPLATE_ANALYTICS` when set.
Data is generated mock data (`src/data/mock.ts`) until the dashboard is wired to the server.
