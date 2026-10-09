# UniBuy: Project Specification (v1)

> Source of truth for the build. Codex must read this file before starting any task.
> If a request conflicts with this spec, stop and ask. Do not guess.

## 1. Overview

UniBuy is a multi-seller marketplace, mainly focused on students but open to anyone selling. UniBuy **only connects buyers and sellers**. It does **not** handle payments between buyers and sellers, delivery, or chat.

- Buyers browse without an account.
- Sellers sign up with email and password, complete onboarding, and manage listings from a dashboard.
- Buyers contact sellers through a **Contact Seller** button that opens WhatsApp.
- Sellers will later pay a subscription (Paystack). **All sellers are on a Free plan for now**, but the subscription structure must exist in the data model from day one.

## 2. Roles

| Role | Account? | Capabilities |
|---|---|---|
| Buyer | No | Browse, search, view listings and seller profiles, contact sellers, post verified reviews, subscribe to email updates, report content |
| Seller | Yes (email + password, verified email) | Manage own profile, products, view own stats and plan |
| Moderator | Yes (created manually) | Handle reports, hide/remove listings and reviews, suspend sellers |
| Super admin | Yes (created manually) | Everything a moderator can do, plus manage categories, plans, settings, and roles |

Admin accounts are never created through public sign-up. Roles live in a separate `user_roles` table that users cannot edit.

## 3. Tech stack

- **Framework:** Next.js (App Router) with TypeScript
- **Database, auth, storage:** Supabase (Postgres, row-level security)
- **Styling:** Tailwind CSS with a small shared component library built from design tokens
- **Hosting:** Vercel
- **Email:** Resend
- **Bot protection:** Cloudflare Turnstile
- **Error tracking:** Sentry
- **Payments (later):** Paystack (subscriptions and webhooks)
- **Design:** Figma (via MCP, or exported frames plus a tokens file)

The site URL must come from an environment variable (no domain yet). Never hard-code URLs.

## 4. User flows

### Buyer
1. Landing page, then the **Go to store** button, then the marketplace.
2. Search and filter (category, city/area, condition, price). Results load lazily (cursor-based pagination).
3. Open a product card to see the product page: images, title, price, condition, description, category, location, seller info, seller reviews.
4. Tap **Contact Seller** to open WhatsApp.
5. Optional: leave a review (email-verified), report a listing, or add their email for updates.
6. The email-update prompt is optional and non-blocking, shown after the buyer has engaged. Never as a popup on arrival.

### Seller
1. Landing page, then **Become a vendor**, then sign up (email and password) and verify email.
2. Onboarding (required before the dashboard unlocks): profile image, display name, unique username, city, area, WhatsApp number, optional campus/school.
3. Dashboard: overview, product management, profile settings, plan card.
4. Public profile page at `/s/{username}`.

## 5. Data model

All tables use UUID primary keys and `created_at` / `updated_at` timestamps unless stated.

### profiles (one per seller, id = auth user id)
username (unique, lowercase, 3-30 chars, letters/numbers/underscore, with a reserved-word list), display_name, avatar_url, about, city, area, campus (optional), whatsapp_number (international format, validated), status (active | suspended), onboarding_completed, listings_visible (boolean, default true).

### user_roles
user_id, role (seller | moderator | super_admin).

### categories
name, slug, sort_order, is_active. Seed: electronics, food, clothes, furniture, home appliances, jewelries, beds, buckets, shoes, others.

### products
seller_id, title, slug (unique), description, price (integer, in kobo), is_negotiable, condition (new | like_new | used), category_id, city, area, status (active | hidden | sold), moderation_status (ok | removed), deleted_at (soft delete).

### product_images
product_id, url, sort_order (first image is the cover).

### product_stats_daily
product_id, date, impressions, views, whatsapp_clicks. One row per product per day. No per-event rows.

### reviews
seller_id, reviewer_email (verified, never public), reviewer_name, rating (1-5), comment, status (pending | published | hidden). Unique (seller_id, reviewer_email). Published immediately, moderated via reports.

### email_subscribers
email (unique), consent_at, confirmed_at (double opt-in), unsubscribed_at, unsubscribe_token, preferred categories/city (optional), bounced_at, source.

### plans
name, price, billing_interval, listing_limit, is_active. Seed one row: Free.

### subscriptions
seller_id, plan_id, status (active | grace | expired | cancelled), started_at, current_period_end, grace_ends_at, last_payment_at, paystack_reference. Every new seller automatically gets a Free subscription (no end date).

### app_settings
billing_enabled (false for now), grace_period_days (5).

### reports
target_type (product | review | seller), target_id, reason, details, reporter_email (optional), status, handled_by.

### email_outbox
type, recipient, payload, status, attempts, dedupe_key, sent_at.

### seller_notification_preferences
seller_id, a toggle per optional email type.

### audit_logs
actor_id, action, target_type, target_id, details.

## 6. Visibility rules

A product appears publicly only if **all** are true:
1. `status` is `active` (sold items may show with a Sold label)
2. `moderation_status` is `ok`
3. `deleted_at` is null
4. The seller's `listings_visible` is true and the seller is not suspended

Hiding by subscription expiry only flips `profiles.listings_visible`. It never changes product rows, so renewing restores everything instantly.

A seller whose plan is expired keeps a **visible profile page** with a "no listings available right now" message, marked `noindex`.

## 7. Listing limit

Each plan has a `listing_limit`. **Active and hidden products count toward the limit. Sold products do not.** Deleted products do not count. Enforce this in the database, not only in the UI.

## 8. Subscription lifecycle (for when billing starts)

- `billing_enabled = false`: every seller is treated as active; nothing is ever hidden.
- When enabled: `active` then, at period end with no payment, `grace` (5 days, from `grace_period_days`), then `expired` (listings hidden). Renewal sets `active` and restores visibility.
- Paystack webhooks are the source of truth (verify signature, idempotent handling). A daily scheduled job also enforces transitions and triggers reminder emails.
- Dashboard shows the plan and a countdown calculated on the server in Lagos time. The Free plan shows "Free plan, no expiry".
- Expired sellers keep dashboard access so they can renew.

## 9. Seller dashboard

- **Plan card:** plan name, status, days remaining (or grace days left).
- **Stat cards** with 7-day / 30-day / all-time selector: total products (active, hidden, sold), impressions, views, WhatsApp ("contact") clicks.
- **Products list:** thumbnail, title, price, status, per-product stats. Actions: edit, hide/unhide, mark as sold, delete (with confirmation, soft delete).
- **Profile settings**, including WhatsApp number, plus a link to preview the public profile.

## 10. Analytics

- **Impression:** a card was visible in the viewport. Counted once per product per visitor session.
- **View:** the product page was opened.
- **WhatsApp click:** Contact Seller was tapped. Label it "contact clicks" in the UI.
- Events are batched in the browser, sent in a single request, and applied as counter increments to `product_stats_daily`.
- Ignore bots and crawlers, ignore the seller viewing their own products, and rate-limit the endpoint.
- No personal data is stored in events.
- Keep daily rows for 12 months, then roll up to monthly.

## 11. Email system

All emails go through `email_outbox`, processed by a background job via Resend, with retries and dedupe keys. App code never sends email directly during a user action.

**Sellers:** email verification, welcome and finish-onboarding reminder, new review (optional), listing removed or account suspended, report received (optional), monthly stats (optional). Billing emails (later): receipt, renewal reminders at 7/3/1 days, payment failed, grace started, listings hidden, reactivated.

**Buyers who subscribe:** double opt-in confirmation, review verification code, weekly digest of new listings (by chosen category/city). Every update email has a one-click unsubscribe. Bounce and complaint webhooks mark addresses invalid.

Transactional emails and update emails are kept separate.

## 12. Security requirements

- Row-level security on every table. Public read only for public fields. Sellers touch only their own rows.
- The seller's WhatsApp number is **never** returned in public profile or product queries. The Contact Seller button calls a server route that applies bot checks and rate limits, logs the click, and returns the `wa.me` link. Collect the **phone number**, not a pasted link.
- Reviews, reports, subscriptions, and tracking go through server routes with validation, rate limits, and Turnstile where needed.
- Validate all input on the server (use a schema validation library). Never trust the client.
- Secrets only in environment variables, never in code or the browser bundle. The Supabase service key is server-only.
- Safe image uploads: type and size limits, server-side checks, compressed output, files stored under the owner's folder.
- Roles are checked on the server and in database rules, not just by hiding UI.
- Admin: separate `/admin` area, two-factor authentication required, every action written to `audit_logs`, soft deletes only.

## 13. SEO and performance requirements

- Server-rendered pages for marketplace, product, and seller profile pages.
- Clean URLs: `/s/{username}`, `/product/{slug}`.
- Unique titles and meta descriptions, Open Graph tags, structured data (Product, Review/AggregateRating where valid), `sitemap.xml`, `robots.txt`.
- Marketplace uses lazy loading with **cursor-based pagination**, never page numbers.
- Optimized, lazy-loaded images with fixed dimensions to avoid layout shift. Use the framework's image component.
- Database indexes: products (status, created_at desc), (category_id, status, created_at), (seller_id), (city, area), unique (slug), full-text on title and description; profiles unique (username); reviews (seller_id, status) and unique (seller_id, reviewer_email); product_stats_daily (product_id, date).
- Target Lighthouse scores above 90 on mobile for performance, SEO, accessibility, and best practices.

## 14. Admin (v1, keep small)

Sellers (search, suspend/reinstate), listings (hide/remove), reviews (hide), reports queue, categories (add/rename/reorder), email subscribers (view/export), dashboard counts. Plans and billing controls come later.

## 15. Build phases

0. Scope, stack, data model (done)
1. Design system, project setup, `AGENTS.md`, security foundation
2. Landing page
3. Seller auth and onboarding
4. Public seller profile
5. Seller dashboard and listings
6. Marketplace and product detail
7. SEO layer, performance, analytics
8. Email system
9. Admin
10. Subscription structure, then Paystack when billing starts
11. Security review, testing, deploy

Build **one page or feature at a time**. Commit working code after each step.

## 16. Decisions log

- Buyers have no accounts; reviews are email-verified (one-time code or link), one per email per seller, published immediately and moderated by reports.
- Price stored in kobo as an integer.
- Condition options: New, Like New, Used.
- Sellers can be anyone, not only students. Campus/school is an optional field.
- All sellers are Free for now; billing structure is built but switched off.
- Grace period is 5 days (configurable setting).
- Expired sellers keep a visible, noindexed profile.
- Hidden products count toward the listing limit; sold products do not.
- No domain yet; use `NEXT_PUBLIC_SITE_URL`.
