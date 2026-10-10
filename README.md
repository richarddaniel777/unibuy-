# UniBuy

A student-focused marketplace that connects buyers and sellers directly. Buyers browse without an account and contact sellers on WhatsApp. Sellers manage their listings from a dashboard and get a public profile page.

UniBuy only connects people. It does not handle payments between buyers and sellers, delivery, or chat.

## Features

- Marketplace with search, filters, and lazy-loaded listings
- Product pages with condition, price, location, and seller info
- Public seller profiles at `/s/{username}`
- Seller dashboard: manage products, view plan status and basic stats
- Contact Seller button that opens WhatsApp
- Email-verified buyer reviews and optional email updates
- Admin area for moderation
- Subscription-ready plan structure

## Tech stack

- [Next.js](https://nextjs.org/) (App Router) with TypeScript
- [Supabase](https://supabase.com/) (Postgres, auth, storage, row-level security)
- [Tailwind CSS](https://tailwindcss.com/)
- [Vercel](https://vercel.com/) for hosting
- [Resend](https://resend.com/) for email
- [Cloudflare Turnstile](https://www.cloudflare.com/products/turnstile/) for bot protection
- [Sentry](https://sentry.io/) for error tracking

## Getting started

### Prerequisites

- Node.js (current LTS)
- A Supabase project
- Accounts for the services listed above as needed

### Setup

```bash
git clone https://github.com/<your-username>/unibuy.git
cd unibuy
npm install
cp .env.example .env.local
```

Fill in `.env.local` with your own values (see below), then:

```bash
npm run dev
```

The app runs at `http://localhost:3000`.

### Environment variables

See `.env.example` for the full list. Never commit real values.

| Variable | Description |
|---|---|
| `NEXT_PUBLIC_SITE_URL` | Public URL of the site |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase anon (public) key |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service key. **Server only, keep secret** |
| `RESEND_API_KEY` | Email sending |
| `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` | Bot protection |
| `SENTRY_DSN` | Error tracking |

### Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Start the dev server |
| `npm run build` | Production build |
| `npm run lint` | Run ESLint |
| `npm run typecheck` | Run the TypeScript check |

## Project structure

```
src/
  app/                  Routes and pages
  components/
    ui/                 Base components built from design tokens
    shared/             Shared composite components
  lib/
    supabase/           Supabase client helpers
    validation/         Zod schemas
    utils/
  server/               Server-only logic
supabase/
  migrations/           Database migrations (the only way the schema changes)
docs/
  PROJECT_SPEC.md       Full project specification
```

## Documentation

The full specification (data model, security rules, user flows, and build phases) lives in [`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md).

## Security

- Row-level security is enabled on every table
- Seller contact details are never exposed in public queries
- All input is validated on the server
- Secrets live in environment variables only

To report a security issue, please contact the maintainer privately rather than opening a public issue.

## Status

In active development.

## License

All rights reserved.
