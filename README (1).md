# Exhale

An adults-only (18+) peer-support app for anonymous, structured conversations — not therapy, not a social feed. Two people are matched by shared topics and language, talk for a finite 25-minute session (text and optional voice), and the conversation is wiped afterward unless both people consent to save it. Every message is screened by an LLM crisis classifier before it's delivered.

## Why it's built this way

- **No feeds, no streaks, no read receipts, no "online" indicators.** The app is designed to avoid the addictive/performative patterns of typical social and chat apps.
- **Ephemeral by default.** Session messages are deleted when a session ends unless *both* participants explicitly consent to save it.
- **Crisis-aware.** Every message is classified by an LLM (Claude Fable 5) plus a keyword safety net *before* it reaches the other person, with a crisis-support card shown when needed.
- **Anonymous accounts.** Auth is Supabase anonymous sign-in — no email or password ever exists for a user.

## Stack

| Layer | Technology |
|---|---|
| Frontend | Expo SDK 54 + expo-router, React Native, `@supabase/supabase-js` |
| Backend | FastAPI (`backend/server.py`) |
| Database / Realtime | Supabase Postgres + Realtime broadcast, strict RLS, private channels |
| Voice | Agora (token endpoint + native voice room; falls back gracefully on web/Expo Go) |
| Crisis detection | Claude Fable 5 via `emergentintegrations` |

## Project structure

```
.
├── backend/
│   ├── server.py          # FastAPI app: matching, chat, consent, voice tokens
│   ├── crisis.py          # LLM + keyword crisis classification
│   ├── e2e_smoke.py       # backend end-to-end smoke test
│   └── requirements.txt
├── frontend/
│   ├── app/
│   │   ├── index.tsx          # entry gate
│   │   ├── onboarding.tsx     # 7-step onboarding
│   │   ├── (tabs)/             # index, journal, resources, settings
│   │   ├── waiting.tsx         # matchmaking waiting room
│   │   ├── session/[matchId].tsx   # live chat session
│   │   ├── voice/[matchId].tsx     # voice room
│   │   ├── reflection.tsx      # post-session reflection
│   │   ├── saved/[matchId].tsx     # saved (consented) conversations
│   │   └── closed.tsx
│   └── package.json
├── supabase_setup.sql     # DB schema, RLS policies, realtime wiring
└── memory/PRD.md          # product & architecture notes
```

## Architecture flow

1. Client sends a message → `POST /api/matches/{id}/messages`
2. Backend verifies the Supabase JWT
3. Message is classified for crisis risk (Claude Fable 5 + keyword safety net)
4. Message is inserted (with any crisis flag)
5. A Postgres trigger broadcasts it over a private Supabase Realtime channel (`match:{id}`) to both clients

Matching itself pairs users by language and topic overlap, respects a 2-day cooldown between the same pair, and is handled via a `match_queue` table and `/api/match/request`.

## API (all under `/api`, Bearer = Supabase access token)

```
GET    /health
GET    /profile
POST   /profile
POST   /match/request
DELETE /match/request
GET    /match/current
GET    /matches/{id}
POST   /matches/{id}/messages
POST   /matches/{id}/consent
POST   /matches/{id}/end
POST   /voice/token
```

## Getting started

### 1. Database

Run `supabase_setup.sql` once in the **Supabase Dashboard → SQL Editor**, then enable **Authentication → Sign In / Up → Anonymous Sign-Ins**.

### 2. Backend

```bash
cd backend
python3 -m venv venv
source venv/bin/activate        # Windows: venv\Scripts\activate
pip install -r requirements.txt
uvicorn server:app --reload --host 0.0.0.0 --port 8001
```

Fill in `backend/.env` first — `server.py` requires `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, `AGORA_APP_ID`, `AGORA_APP_CERTIFICATE`, `MONGO_URL`, `DB_NAME`, and `EMERGENT_LLM_KEY`.

Run backend tests with:

```bash
pytest
```

### 3. Frontend

```bash
cd frontend
yarn install
yarn start
```

Then press `w` (web), `a` (Android), `i` (iOS), or scan the QR code in Expo Go. Fill in `frontend/.env` first — `EXPO_PUBLIC_BACKEND_URL`, `EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.

## Status

- [x] Backend: matching, crisis-checked chat, consent, ephemeral wipe, Agora token endpoint
- [x] Frontend: all screens wired to real backend/Supabase
- [x] Backend + frontend end-to-end tests passing
- [x] Agora voice sessions (native build required for audio; web falls back gracefully)
- [ ] Push notifications (max 1/day) — planned
- [ ] Optional email-link account upgrade — planned

## Notes

- Voice audio needs a native build to actually run — it can't be tested in Expo Go.
- Chat testing requires two real anonymous accounts (e.g. two browser contexts); there is no simulated AI peer.
