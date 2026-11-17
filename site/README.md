# tapeloop.stream

The project's website: one static page in `public/`, served by a Cloudflare Worker (`src/worker.js`, which also sends
`www.` to the bare domain). Images are the app's own snapshots (`make snapshots`), dark variants.

- Preview: `cd site/public && python3 -m http.server 8765`, then open http://localhost:8765.
- Deploy: `cd site && npx wrangler deploy` with `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` set.
