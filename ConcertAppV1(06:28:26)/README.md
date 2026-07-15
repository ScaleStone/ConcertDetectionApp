# Serene Therapy AI

A full-stack mental wellness web app prototype with AI chat, journaling, guided breathing, sleep tracking, peer rooms, and pre-response crisis detection.

## Run

```bash
node server.mjs
```

Open [http://localhost:3000](http://localhost:3000).

## Safety Behavior

- Crisis keyword detection runs in `server.mjs` before any AI response is generated.
- Crisis-flagged AI chat, journal, reflection, and peer messages return a prominent resource flow instead of normal therapeutic content.
- An anonymized JSONL audit record is written to `data/crisis-audit.jsonl`.
- The global nav always includes a visible `Talk to a Human` button linked to `988`.

## Production Integration Notes

- Set `ANTHROPIC_API_KEY` to call Claude. The app uses `CLAUDE_MODEL` or defaults to `claude-sonnet-4-20250514`.
- Replace the JSON store with PostgreSQL tables for users, sessions, journals, sleep logs, and community messages.
- Add Redis for session state/rate limits, Clerk/Auth.js for real auth, Stripe webhooks for paid tier status, and OAuth/API connectors for Apple Health, Fitbit, and Oura.
- Meditation buttons currently select placeholder audio. Replace with hosted accessible audio files before deployment.
