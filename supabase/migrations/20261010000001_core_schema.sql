-- UniBuy migration 1 of 4: core schema
-- Run once, in order: 01 core_schema, 02 functions_triggers, 03 security_rls, 04 storage

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.app_role            as enum ('seller', 'moderator', 'super_admin');
create type public.seller_status       as enum ('active', 'suspended');
create type public.product_condition   as enum ('new', 'like_new', 'used');
create type public.product_status      as enum ('active', 'hidden', 'sold');
create type public.moderation_state    as enum ('ok', 'removed');
create type public.review_status       as enum ('pending', 'published', 'hidden');
create type public.subscription_status as enum ('active', 'grace', 'expired', 'cancelled');
create type public.report_target       as enum ('product', 'review', 'seller');
create type public.report_status       as enum ('open', 'resolved', 'dismissed');
create type public.email_status        as enum ('pending', 'sent', 'failed');

-- ---------------------------------------------------------------------------
-- Sellers
-- ---------------------------------------------------------------------------
create table public.profiles (
  id                   uuid primary key references auth.users (id) on delete cascade,
  username             text unique,
  display_name         text,
  avatar_url           text,
  about                text,
  city                 text,
  area                 text,
  campus               text,
  status               public.seller_status not null default 'active',
  onboarding_completed boolean not null default false,
  listings_visible     boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint profiles_username_format check (username is null or username ~ '^[a-z0-9_]{3,30}$'),
  constraint profiles_username_reserved check (
    username is null or username not in (
      'admin', 'administrator', 'login', 'logout', 'signup', 'register', 'dashboard',
      'api', 'product', 'products', 'marketplace', 'store', 'settings', 'support',
      'help', 'about', 'terms', 'privacy', 'unibuy', 'null', 'undefined', 'moderator'
    )
  ),
  constraint profiles_display_name_len check (display_name is null or char_length(display_name) between 2 and 60),
  constraint profiles_about_len check (about is null or char_length(about) <= 500),
  constraint profiles_onboarding_requires_fields check (
    not onboarding_completed
    or (username is not null and display_name is not null and city is not null and area is not null)
  )
);

-- WhatsApp numbers live in their own table so they can never leak through public profile queries.
create table public.seller_contacts (
  seller_id       uuid primary key references public.profiles (id) on delete cascade,
  whatsapp_number text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint seller_contacts_whatsapp_format check (whatsapp_number ~ '^\+[1-9][0-9]{7,14}$')
);

create table public.user_roles (
  user_id uuid not null references auth.users (id) on delete cascade,
  role    public.app_role not null,
  primary key (user_id, role)
);

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------
create table public.categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  slug       text not null unique,
  sort_order integer not null default 0,
  is_active  boolean not null default true
);

create table public.products (
  id                uuid primary key default gen_random_uuid(),
  seller_id         uuid not null references public.profiles (id) on delete cascade,
  title             text not null,
  slug              text not null unique,
  description       text not null,
  price_kobo        bigint not null,
  is_negotiable     boolean not null default false,
  condition         public.product_condition not null,
  category_id       uuid not null references public.categories (id),
  city              text not null,
  area              text,
  status            public.product_status not null default 'active',
  moderation_status public.moderation_state not null default 'ok',
  deleted_at        timestamptz,
  search_vector     tsvector generated always as (
                      to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))
                    ) stored,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint products_title_len check (char_length(title) between 3 and 120),
  constraint products_description_len check (char_length(description) between 1 and 5000),
  constraint products_price_positive check (price_kobo > 0)
);

create table public.product_images (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  path       text not null,          -- storage path inside the product-images bucket
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- One row per product per day. No per-event rows (keeps the table small at scale).
create table public.product_stats_daily (
  product_id      uuid not null references public.products (id) on delete cascade,
  stat_date       date not null,
  impressions     bigint not null default 0,
  views           bigint not null default 0,
  whatsapp_clicks bigint not null default 0,
  primary key (product_id, stat_date)
);

-- ---------------------------------------------------------------------------
-- Reviews and buyer email
-- ---------------------------------------------------------------------------
create table public.reviews (
  id             uuid primary key default gen_random_uuid(),
  seller_id      uuid not null references public.profiles (id) on delete cascade,
  reviewer_email text not null,      -- verified, never shown publicly
  reviewer_name  text not null,
  rating         smallint not null,
  comment        text,
  status         public.review_status not null default 'published',
  created_at     timestamptz not null default now(),

  constraint reviews_rating_range check (rating between 1 and 5),
  constraint reviews_comment_len check (comment is null or char_length(comment) <= 1000),
  constraint reviews_name_len check (char_length(reviewer_name) between 1 and 60),
  constraint reviews_email_lower check (reviewer_email = lower(reviewer_email)),
  constraint reviews_one_per_email unique (seller_id, reviewer_email)
);

-- One-time codes for buyer email verification (reviews, subscriptions). Server-only.
create table public.email_verifications (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  purpose     text not null,
  seller_id   uuid references public.profiles (id) on delete cascade,
  code_hash   text not null,
  attempts    integer not null default 0,
  expires_at  timestamptz not null,
  consumed_at timestamptz,
  created_at  timestamptz not null default now(),

  constraint email_verifications_purpose check (purpose in ('review', 'subscribe')),
  constraint email_verifications_email_lower check (email = lower(email))
);

create table public.email_subscribers (
  id                   uuid primary key default gen_random_uuid(),
  email                text not null unique,
  consent_at           timestamptz not null default now(),
  confirmed_at         timestamptz,
  unsubscribed_at      timestamptz,
  unsubscribe_token    text not null unique
                         default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  preferred_categories uuid[] not null default '{}',
  preferred_city       text,
  bounced_at           timestamptz,
  source               text,
  created_at           timestamptz not null default now(),

  constraint email_subscribers_email_lower check (email = lower(email))
);

-- ---------------------------------------------------------------------------
-- Plans and subscriptions (billing is switched off for now)
-- ---------------------------------------------------------------------------
create table public.plans (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  price_kobo       bigint not null default 0,
  billing_interval text,
  listing_limit    integer,            -- null = unlimited
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),

  constraint plans_interval check (billing_interval is null or billing_interval in ('month', 'year')),
  constraint plans_limit_positive check (listing_limit is null or listing_limit > 0)
);

create table public.subscriptions (
  id                 uuid primary key default gen_random_uuid(),
  seller_id          uuid not null unique references public.profiles (id) on delete cascade,
  plan_id            uuid not null references public.plans (id),
  status             public.subscription_status not null default 'active',
  started_at         timestamptz not null default now(),
  current_period_end timestamptz,      -- null for the Free plan (no expiry)
  grace_ends_at      timestamptz,
  last_payment_at    timestamptz,
  paystack_reference text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Single settings row.
create table public.app_settings (
  id                boolean primary key default true,
  billing_enabled   boolean not null default false,
  grace_period_days integer not null default 5,

  constraint app_settings_single_row check (id),
  constraint app_settings_grace_nonneg check (grace_period_days >= 0)
);

-- ---------------------------------------------------------------------------
-- Moderation, email queue, notifications, audit
-- ---------------------------------------------------------------------------
create table public.reports (
  id             uuid primary key default gen_random_uuid(),
  target_type    public.report_target not null,
  target_id      uuid not null,
  reason         text not null,
  details        text,
  reporter_email text,
  status         public.report_status not null default 'open',
  handled_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now(),

  constraint reports_details_len check (details is null or char_length(details) <= 1000)
);

create table public.email_outbox (
  id          uuid primary key default gen_random_uuid(),
  type        text not null,
  recipient   text not null,
  payload     jsonb not null default '{}'::jsonb,
  status      public.email_status not null default 'pending',
  attempts    integer not null default 0,
  dedupe_key  text unique,
  send_after  timestamptz not null default now(),
  sent_at     timestamptz,
  last_error  text,
  created_at  timestamptz not null default now()
);

create table public.seller_notification_preferences (
  seller_id       uuid primary key references public.profiles (id) on delete cascade,
  new_review      boolean not null default true,
  report_received boolean not null default true,
  monthly_stats   boolean not null default true
);

create table public.audit_logs (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid references auth.users (id) on delete set null,
  action      text not null,
  target_type text,
  target_id   uuid,
  details     jsonb,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
-- Marketplace feed (cursor pagination on created_at, id).
create index products_feed_idx
  on public.products (created_at desc, id desc)
  where status = 'active' and moderation_status = 'ok' and deleted_at is null;

create index products_category_feed_idx
  on public.products (category_id, created_at desc, id desc)
  where status = 'active' and moderation_status = 'ok' and deleted_at is null;

create index products_city_feed_idx
  on public.products (city, created_at desc, id desc)
  where status = 'active' and moderation_status = 'ok' and deleted_at is null;

create index products_seller_idx on public.products (seller_id, created_at desc);
create index products_search_idx on public.products using gin (search_vector);

create index product_images_product_idx on public.product_images (product_id, sort_order);

create index product_stats_date_idx on public.product_stats_daily (stat_date);

create index reviews_seller_idx on public.reviews (seller_id, status, created_at desc);

create index profiles_city_idx on public.profiles (city);

create index subscriptions_status_end_idx on public.subscriptions (status, current_period_end);

create index reports_status_idx on public.reports (status, created_at desc);

create index email_outbox_queue_idx on public.email_outbox (status, send_after);

create index email_verifications_lookup_idx on public.email_verifications (email, purpose, created_at desc);

-- ---------------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------------
insert into public.categories (name, slug, sort_order) values
  ('Electronics',     'electronics',     1),
  ('Food',            'food',            2),
  ('Clothes',         'clothes',         3),
  ('Furniture',       'furniture',       4),
  ('Home appliances', 'home-appliances', 5),
  ('Jewelries',       'jewelries',       6),
  ('Beds',            'beds',            7),
  ('Buckets',         'buckets',         8),
  ('Shoes',           'shoes',           9),
  ('Others',          'others',          10);

-- PLACEHOLDER: the Free plan listing limit is 20. Change it any time with:
--   update public.plans set listing_limit = 30 where name = 'Free';
insert into public.plans (name, price_kobo, billing_interval, listing_limit)
values ('Free', 0, null, 20);

insert into public.app_settings (id, billing_enabled, grace_period_days)
values (true, false, 5);
