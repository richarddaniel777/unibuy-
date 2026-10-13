-- UniBuy migration 2 of 4: functions and triggers
-- Run after 20261010000001_core_schema.sql

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger seller_contacts_set_updated_at
  before update on public.seller_contacts
  for each row execute function public.set_updated_at();

create trigger products_set_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

create trigger subscriptions_set_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- New auth user: create profile, seller role, Free subscription, notification prefs
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_free_plan uuid;
begin
  insert into public.profiles (id) values (new.id);
  insert into public.user_roles (user_id, role) values (new.id, 'seller');

  select id into v_free_plan from public.plans where name = 'Free' limit 1;
  if v_free_plan is not null then
    insert into public.subscriptions (seller_id, plan_id, status)
    values (new.id, v_free_plan, 'active');
  end if;

  insert into public.seller_notification_preferences (seller_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Usernames are locked once onboarding is complete (stable URLs and SEO)
-- ---------------------------------------------------------------------------
create or replace function public.protect_username()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.onboarding_completed and new.username is distinct from old.username then
    raise exception 'Username cannot be changed after onboarding' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger profiles_protect_username
  before update of username on public.profiles
  for each row execute function public.protect_username();

-- ---------------------------------------------------------------------------
-- Listing limit (active + hidden count; sold and deleted do not)
-- ---------------------------------------------------------------------------
create or replace function public.enforce_listing_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
  v_count integer;
begin
  -- Only check when the row will count toward the limit.
  if new.deleted_at is not null or new.status not in ('active', 'hidden') then
    return new;
  end if;

  -- Already counted before this update: nothing changes.
  if tg_op = 'UPDATE' and old.deleted_at is null and old.status in ('active', 'hidden') then
    return new;
  end if;

  select pl.listing_limit
    into v_limit
    from public.subscriptions s
    join public.plans pl on pl.id = s.plan_id
   where s.seller_id = new.seller_id;

  if v_limit is null then
    return new;  -- unlimited
  end if;

  select count(*)
    into v_count
    from public.products
   where seller_id = new.seller_id
     and deleted_at is null
     and status in ('active', 'hidden')
     and id <> new.id;

  if v_count >= v_limit then
    raise exception 'Listing limit reached for your plan' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger products_listing_limit
  before insert or update of status, deleted_at on public.products
  for each row execute function public.enforce_listing_limit();

revoke execute on function public.enforce_listing_limit() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Max 8 images per product
-- ---------------------------------------------------------------------------
create or replace function public.enforce_image_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.product_images where product_id = new.product_id) >= 8 then
    raise exception 'A product can have at most 8 images' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger product_images_limit
  before insert on public.product_images
  for each row execute function public.enforce_image_limit();

revoke execute on function public.enforce_image_limit() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Batched analytics: called by a server route with the service role only
-- p_events example:
--   [{"product_id": "<uuid>", "impressions": 4, "views": 1, "clicks": 0}]
-- ---------------------------------------------------------------------------
create or replace function public.record_product_events(p_events jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.product_stats_daily (product_id, stat_date, impressions, views, whatsapp_clicks)
  select e.product_id,
         (now() at time zone 'Africa/Lagos')::date,
         least(sum(greatest(coalesce(e.impressions, 0), 0)), 1000),
         least(sum(greatest(coalesce(e.views, 0), 0)), 1000),
         least(sum(greatest(coalesce(e.clicks, 0), 0)), 1000)
    from jsonb_to_recordset(p_events) as e(product_id uuid, impressions integer, views integer, clicks integer)
    join public.products p on p.id = e.product_id
   group by e.product_id
  on conflict (product_id, stat_date) do update
    set impressions     = public.product_stats_daily.impressions     + excluded.impressions,
        views           = public.product_stats_daily.views           + excluded.views,
        whatsapp_clicks = public.product_stats_daily.whatsapp_clicks + excluded.whatsapp_clicks;
$$;

revoke execute on function public.record_product_events(jsonb) from public, anon, authenticated;
grant  execute on function public.record_product_events(jsonb) to service_role;
