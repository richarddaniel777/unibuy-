-- UniBuy migration 3 of 4: row-level security and column-level grants
-- Run after 20261010000002_functions_triggers.sql
--
-- Approach:
--   1. Turn on RLS for every table.
--   2. Remove all default access for anon (visitors) and authenticated (signed-in sellers).
--   3. Grant back only what each role needs, by table and by column.
--   4. Tables with no policies (reports, email_outbox, ...) are server-only: they are
--      reached through server routes using the service role, never from the browser.
-- Staff (moderator / super_admin) actions also run on the server with the service role,
-- after the server checks the user's role. Every admin action is written to audit_logs.

-- ---------------------------------------------------------------------------
-- 1. Enable RLS everywhere
-- ---------------------------------------------------------------------------
alter table public.profiles                       enable row level security;
alter table public.seller_contacts                enable row level security;
alter table public.user_roles                     enable row level security;
alter table public.categories                     enable row level security;
alter table public.products                       enable row level security;
alter table public.product_images                 enable row level security;
alter table public.product_stats_daily            enable row level security;
alter table public.reviews                        enable row level security;
alter table public.email_verifications            enable row level security;
alter table public.email_subscribers              enable row level security;
alter table public.plans                          enable row level security;
alter table public.subscriptions                  enable row level security;
alter table public.app_settings                   enable row level security;
alter table public.reports                        enable row level security;
alter table public.email_outbox                   enable row level security;
alter table public.seller_notification_preferences enable row level security;
alter table public.audit_logs                     enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Remove default access, and stop future tables from being exposed by default
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Policies and grants, table by table
-- ---------------------------------------------------------------------------

-- profiles: public can read active, onboarded sellers. Owners read and edit their own.
-- Sellers cannot touch status or listings_visible (no column grant).
grant select on public.profiles to anon, authenticated;
grant update (username, display_name, avatar_url, about, city, area, campus, onboarding_completed)
  on public.profiles to authenticated;

create policy "profiles: public read active"
  on public.profiles for select to anon, authenticated
  using (status = 'active' and onboarding_completed);

create policy "profiles: owner read own"
  on public.profiles for select to authenticated
  using (id = auth.uid());

create policy "profiles: owner update own"
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- seller_contacts: only the owner. Public WhatsApp links are served by a server route.
grant select on public.seller_contacts to authenticated;
grant insert (seller_id, whatsapp_number) on public.seller_contacts to authenticated;
grant update (whatsapp_number) on public.seller_contacts to authenticated;

create policy "seller_contacts: owner read"
  on public.seller_contacts for select to authenticated
  using (seller_id = auth.uid());

create policy "seller_contacts: owner insert"
  on public.seller_contacts for insert to authenticated
  with check (seller_id = auth.uid());

create policy "seller_contacts: owner update"
  on public.seller_contacts for update to authenticated
  using (seller_id = auth.uid())
  with check (seller_id = auth.uid());

-- user_roles: users can read their own roles. Nobody changes roles from the browser.
grant select on public.user_roles to authenticated;

create policy "user_roles: read own"
  on public.user_roles for select to authenticated
  using (user_id = auth.uid());

-- categories: public read of active categories.
grant select on public.categories to anon, authenticated;

create policy "categories: public read active"
  on public.categories for select to anon, authenticated
  using (is_active);

-- products
grant select on public.products to anon, authenticated;
grant insert (seller_id, title, slug, description, price_kobo, is_negotiable, condition,
              category_id, city, area, status)
  on public.products to authenticated;
grant update (title, description, price_kobo, is_negotiable, condition, category_id,
              city, area, status, deleted_at)
  on public.products to authenticated;
-- No delete grant: sellers soft-delete by setting deleted_at.
-- seller_id, slug and moderation_status can never be changed by a seller.

create policy "products: public read visible"
  on public.products for select to anon, authenticated
  using (
    status in ('active', 'sold')
    and moderation_status = 'ok'
    and deleted_at is null
    and exists (
      select 1 from public.profiles p
      where p.id = products.seller_id
        and p.status = 'active'
        and p.listings_visible
    )
  );

create policy "products: owner read own"
  on public.products for select to authenticated
  using (seller_id = auth.uid());

create policy "products: owner insert"
  on public.products for insert to authenticated
  with check (
    seller_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.status = 'active' and p.onboarding_completed
    )
  );

create policy "products: owner update own"
  on public.products for update to authenticated
  using (seller_id = auth.uid() and moderation_status = 'ok')
  with check (seller_id = auth.uid());

-- product_images: visible whenever the parent product is visible to the caller
-- (the subquery on products is itself filtered by the products policies above).
grant select on public.product_images to anon, authenticated;
grant insert (product_id, path, sort_order) on public.product_images to authenticated;
grant update (sort_order) on public.product_images to authenticated;
grant delete on public.product_images to authenticated;

create policy "product_images: read when product readable"
  on public.product_images for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_images.product_id));

create policy "product_images: owner insert"
  on public.product_images for insert to authenticated
  with check (exists (
    select 1 from public.products p
    where p.id = product_images.product_id and p.seller_id = auth.uid()
  ));

create policy "product_images: owner update"
  on public.product_images for update to authenticated
  using (exists (
    select 1 from public.products p
    where p.id = product_images.product_id and p.seller_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.products p
    where p.id = product_images.product_id and p.seller_id = auth.uid()
  ));

create policy "product_images: owner delete"
  on public.product_images for delete to authenticated
  using (exists (
    select 1 from public.products p
    where p.id = product_images.product_id and p.seller_id = auth.uid()
  ));

-- product_stats_daily: sellers read stats for their own products. Writes only via record_product_events().
grant select on public.product_stats_daily to authenticated;

create policy "product_stats_daily: owner read"
  on public.product_stats_daily for select to authenticated
  using (exists (
    select 1 from public.products p
    where p.id = product_stats_daily.product_id and p.seller_id = auth.uid()
  ));

-- reviews: the public can read published reviews, but NOT reviewer_email (column grant).
-- Inserts happen on the server, after the buyer verifies their email.
grant select (id, seller_id, reviewer_name, rating, comment, status, created_at)
  on public.reviews to anon, authenticated;

create policy "reviews: public read published"
  on public.reviews for select to anon, authenticated
  using (status = 'published');

-- plans: public read of active plans.
grant select on public.plans to anon, authenticated;

create policy "plans: public read active"
  on public.plans for select to anon, authenticated
  using (is_active);

-- subscriptions: sellers read their own. Changes come from webhooks and server jobs.
grant select on public.subscriptions to authenticated;

create policy "subscriptions: owner read"
  on public.subscriptions for select to authenticated
  using (seller_id = auth.uid());

-- app_settings: signed-in users can read (for example, to know if billing is enabled).
grant select on public.app_settings to authenticated;

create policy "app_settings: authenticated read"
  on public.app_settings for select to authenticated
  using (true);

-- seller_notification_preferences: owner reads and edits.
grant select on public.seller_notification_preferences to authenticated;
grant update (new_review, report_received, monthly_stats)
  on public.seller_notification_preferences to authenticated;

create policy "notification prefs: owner read"
  on public.seller_notification_preferences for select to authenticated
  using (seller_id = auth.uid());

create policy "notification prefs: owner update"
  on public.seller_notification_preferences for update to authenticated
  using (seller_id = auth.uid())
  with check (seller_id = auth.uid());

-- Server-only tables (RLS on, no policies, no grants):
--   email_verifications, email_subscribers, reports, email_outbox, audit_logs
-- They are only reachable with the service role from server code.
