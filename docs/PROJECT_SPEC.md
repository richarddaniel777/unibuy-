# UniBuy: Project Specification (v1.1)

> Source of truth for the build. Codex must read this file before starting any task.
> If a request conflicts with this spec, stop and ask. Do not guess.
> v1.1 reflects the database migrations in /supabase/migrations.

## 1. Overview

UniBuy is a multi-seller marketplace, mainly focused on students but open to anyone selling. UniBuy **only connects buyers and sellers**. It does **not** handle payments between buyers and sellers, delivery, or chat.

- Buyers browse without an account.
- Sellers sign up with email and password, complete onboarding, and manage listings from a dashboard.
- Buyers contact sellers through a **Contact Seller** button that opens WhatsApp.
- Sellers will later pay a subscription (Paystack). **All sellers are on a Free plan for now**, but the subscription structure exists in the data model from day one.

## 2. Roles

| Role | Account? | Capabilities |
|---|---|---|
| Buyer | No | Browse, search, view listings and seller profiles, contact sellers, post verified reviews, subscribe to email updates, report content |
| Seller | Yes (email + password, verified email) | Manage own profile, products, view own stats and plan |
| Moderator | Yes (created manually) | Handle reports, hide/remove listings and reviews, suspend sellers |
| Super admin | Yes (created manually) | Everything a moderator can do, plus manage categories, plans, settings, and roles |

Admin accounts are never created through public sign-up. Roles live in a separate `user_roles` table that users cannot edit. Every new account automatically gets the `seller` role.

## 3. Tech stack

- **Framework:** Next.js (App Router) with TypeScript
- **Database, auth, storage:** Supabase (Postgres, row-level security)
- **Styling:** Tailwind CSS (v4, theme tokens defined in CSS) with a small shared component library
- **Hosting:** Vercel
- **Email:** Resend
- **Bot protection:** Cloudflare Turnstile
- **Error tracking:** Sentry
- **Payments (later):** Paystack (subscriptions and webhooks)
- **Design:** Figma (via MCP, or exported frames plus a tokens file)

The site URL must come from the `NEXT_PUBLIC_SITE_URL` environment variable (no domain yet). Never hard-code URLs.

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

All tables use UUID primary keys and `created_at` / `updated_at` timestamps unless stated. The authoritative definition is in `/supabase/migrations`.

### profiles (one per seller, id = auth user id)
username (unique, lowercase, 3-30 chars, letters/numbers/underscore, reserved-word list), display_name, avatar_url, about, city, area, campus (optional), status (active | suspended), onboarding_completed, listings_visible (boolean, default true).
- Created automatically when an auth user is created.
- **Username is locked once onboarding is complete** (stable URLs and SEO).
- Sellers can edit their own profile fields but can never change `status` or `listings_visible`.

### seller_contacts
seller_id, whatsapp_number (international format, e.g. +234..., validated).
- Stored **separately from profiles** so the number can never appear in public profile queries.
- Only the owner can read or write it from the browser. The Contact Seller server route reads it with the service role and builds the `wa.me` link.

### user_roles
user_id, role (seller | moderator | super_admin). Not editable from the browser.

### categories
name, slug, sort_order, is_active. Seed: electronics, food, clothes, furniture, home appliances, jewelries, beds, buckets, shoes, others.

### products
seller_id, title, slug (unique, never changes), description, price_kobo (integer, in kobo, must be greater than 0), is_negotiable, condition (new | like_new | used), category_id, city, area, status (active | hidden | sold), moderation_status (ok | removed), deleted_at (soft delete), search_vector (generated full-text column).
- Sellers can never change `seller_id`, `slug`, or `moderation_status`.
- Sellers cannot hard-delete; they soft-delete by setting `deleted_at`.
- Sellers cannot edit a product an admin has removed.

### product_images
product_id, path (storage path in the product-images bucket), sort_order (first image is the cover). **Maximum 8 images per product** (enforced in the database).

### product_stats_daily
product_id, stat_date (Lagos time), impressions, views, whatsapp_clicks. One row per product per day. No per-event rows. Written only through the `record_product_events()` database function, called from a server route with the service role.

### reviews
seller_id, reviewer_email (verified, never public), reviewer_name, rating (1-5), comment, status (pending | published | hidden). Unique (seller_id, reviewer_email). Published immediately, moderated via reports.
- The public can read published reviews but **not** `reviewer_email` (column-level permission).
- Reviews are inserted only by a server route, after email verification.

### email_verifications (server-only)
email, purpose (review | subscribe), seller_id, code_hash, attempts, expires_at, consumed_at. Holds one-time codes for buyer verification. Codes are stored hashed, expire quickly, and have an attempt limit.

### email_subscribers (server-only)
email (unique, lowercase), consent_at, confirmed_at (double opt-in), unsubscribed_at, unsubscribe_token, preferred_categories, preferred_city, bounced_at, source.

### plans
name, price_kobo, billing_interval (month | year | none), listing_limit (null = unlimited), is_active. Seed one row: Free. **The Free plan listing limit is a placeholder of 20** and is changed with a single update statement.

### subscriptions
seller_id (one per seller), plan_id, status (active | grace | expired | cancelled), started_at, current_period_end, grace_ends_at, last_payment_at, paystack_reference. Every new seller automatically gets a Free subscription (no end date).

### app_settings
Single-row table: billing_enabled (false for now), grace_period_days (5).

### reports (server-only)
target_type (product | review | seller), target_id, reason, details, reporter_email (optional), status (open | resolved | dismissed), handled_by.

### email_outbox (server-only)
type, recipient, payload, status (pending | sent | failed), attempts, dedupe_key (unique), send_after, sent_at, last_error.

### seller_notification_preferences
seller_id, new_review, report_received, monthly_stats. Owner can read and update.

### audit_logs (server-only)
actor_id, action, target_type, target_id, details.

## 6. Visibility rules

A product appears publicly only if **all** are true:
1. `status` is `active` (sold items may show with a Sold label)
2. `moderation_status` is `ok`
3. `deleted_at` is null
4. The seller's `listings_visible` is true and the seller is not suspended

Hiding by subscription expiry only flips `profiles.listings_visible`. It never changes product rows, so renewing restores everything instantly.

A seller whose plan is expired keeps a **visible profile page** with a "no listings available right now" message, marked `noindex`. A suspended seller's profile is not public.

## 7. Listing limit

Each plan has a `listing_limit`. **Active and hidden products count toward the limit. Sold products do not.** Deleted products do not count. This is enforced by a database trigger, not only in the UI. (Known v1 limit: many simultaneous create requests could briefly exceed the limit by a small amount.)

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
- Events are batched in the browser, sent in a single request, and applied as counter increments through `record_product_events()`.
- Ignore bots and crawlers, ignore the seller viewing their own products, and rate-limit the endpoint.
- No personal data is stored in events.
- Keep daily rows for 12 months, then roll up to monthly.

## 11. Email system

All emails go through `email_outbox`, processed by a background job via Resend, with retries and dedupe keys. App code never sends email directly during a user action.

**Sellers:** email verification, welcome and finish-onboarding reminder, new review (optional), listing removed or account suspended, report received (optional), monthly stats (optional). Billing emails (later): receipt, renewal reminders at 7/3/1 days, payment failed, grace started, listings hidden, reactivated.

**Buyers who subscribe:** double opt-in confirmation, review verification code, weekly digest of new listings (by chosen category/city). Every update email has a one-click unsubscribe. Bounce and complaint webhooks mark addresses invalid.

Transactional emails and update emails are kept separate.

## 12. Security requirements

- Row-level security on every table. Public read only for public fields. Sellers touch only their own rows. Column-level permissions limit which fields sellers can change.
- **Server-only tables** (email_verifications, email_subscribers, reports, email_outbox, audit_logs) have RLS on and no browser access at all. They are reached only through server routes using the service role.
- The seller's WhatsApp number is **never** returned in public profile or product queries. The Contact Seller button calls a server route that applies bot checks and rate limits, logs the click, and returns the `wa.me` link.
- Reviews, reports, subscriptions, and tracking go through server routes with validation, rate limits, and Turnstile where needed.
- Validate all input on the server (Zod). Never trust the client.
- Secrets only in environment variables, never in code or the browser bundle. The Supabase secret/service-role key is server-only.
- Images: stored in Supabase Storage buckets `avatars` (max 2 MB) and `product-images` (max 5 MB), JPEG/PNG/WebP only. Each seller can only write inside their own folder named after their user id. Compress images before upload.
- Roles are checked on the server and in database rules, not just by hiding UI.
- **Admin and moderator actions run on the server with the service role, after a role check.** Each action is written to `audit_logs`. Admin area at `/admin`, two-factor authentication required, soft deletes only.

## 13. SEO and performance requirements

- Server-rendered pages for marketplace, product, and seller profile pages.
- Clean URLs: `/s/{username}`, `/product/{slug}`.
- Unique titles and meta descriptions, Open Graph tags, structured data (Product, Review/AggregateRating where valid), `sitemap.xml`, `robots.txt`.
- Marketplace uses lazy loading with **cursor-based pagination** on (created_at, id), never page numbers.
- Optimized, lazy-loaded images with fixed dimensions to avoid layout shift. Use the framework's image component.
- Database indexes (in the migrations): partial indexes for the marketplace feed, by category, and by city; seller index; full-text GIN index; reviews, subscriptions, reports, and email queue indexes.
- Target Lighthouse scores above 90 on mobile for performance, SEO, accessibility, and best practices.

## 14. Admin (v1, keep small)

Sellers (search, suspend/reinstate), listings (hide/remove), reviews (hide), reports queue, categories (add/rename/reorder), email subscribers (view/export), dashboard counts. Plans and billing controls come later.

## 15. Build phases

0. Scope, stack, data model (done)
1. Project setup, database migrations, security foundation (in progress)
2. Design system (tokens and shared components)
3. Landing page
4. Seller auth and onboarding
5. Public seller profile
6. Seller dashboard and listings
7. Marketplace and product detail
8. SEO layer, performance, analytics
9. Email system
10. Admin
11. Subscription structure, then Paystack when billing starts
12. Security review, testing, deploy

Build **one page or feature at a time**. Commit working code after each step.

## 16. Decisions log

- Buyers have no accounts; reviews are email-verified (one-time code), one per email per seller, published immediately and moderated by reports.
- Price stored in kobo as an integer.
- Condition options: New, Like New, Used.
- Sellers can be anyone, not only students. Campus/school is an optional field.
- All sellers are Free for now; billing structure is built but switched off.
- Grace period is 5 days (configurable setting).
- Expired sellers keep a visible, noindexed profile.
- Hidden products count toward the listing limit; sold products do not.
- WhatsApp numbers live in `seller_contacts`, never in public queries.
- Usernames are locked after onboarding.
- Maximum 8 images per product.
- Free plan listing limit is a placeholder of 20.
- Admin and moderator actions run on the server with the service role after a role check, and are written to `audit_logs`.
- No domain yet; use `NEXT_PUBLIC_SITE_URL`.