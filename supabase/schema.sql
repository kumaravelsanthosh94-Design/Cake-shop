-- Supabase SQL Editor: run this file once to create the bakery store.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.store_settings (
  singleton boolean primary key default true check (singleton),
  owner_id uuid references auth.users(id) on delete set null,
  bakery_name text not null default 'Tindu Backery',
  tagline text not null default 'Home-baked, made for your moments.',
  phone text not null default '',
  whatsapp_number text not null default '',
  upi_id text not null default '',
  delivery_area text not null default 'Local delivery area',
  hero_image_url text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
insert into public.store_settings(singleton) values (true) on conflict (singleton) do nothing;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  category text not null default 'Cakes',
  description text not null default '',
  image_url text,
  ingredients text[] not null default '{}',
  allergens text[] not null default '{}',
  flavours text[] not null default '{}',
  variants jsonb not null default '[]'::jsonb check (jsonb_typeof(variants) = 'array'),
  lead_days integer not null default 1 check (lead_days >= 0),
  is_available boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  order_number text not null unique,
  tracking_token text not null unique,
  customer_name text not null,
  customer_phone text not null,
  delivery_address text not null,
  requested_for date,
  delivery_preference text not null default '',
  subtotal numeric(10,2) not null check (subtotal >= 0),
  delivery_fee numeric(10,2),
  total numeric(10,2),
  confirmed_slot timestamptz,
  delivery_note text,
  status text not null default 'requested' check (status in ('requested','accepted','payment_received','baking','ready','out_for_delivery','delivered','declined')),
  is_paid boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists orders_owner_created_idx on public.orders(owner_id, created_at desc);
create index if not exists orders_tracking_token_idx on public.orders(tracking_token);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  variant_label text not null,
  flavour text not null default '',
  unit_price numeric(10,2) not null check (unit_price >= 0),
  quantity integer not null check (quantity between 1 and 20),
  line_total numeric(10,2) not null check (line_total >= 0),
  created_at timestamptz not null default now()
);
create index if not exists order_items_order_idx on public.order_items(order_id);

create table if not exists public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status text not null check (status in ('requested','accepted','payment_received','baking','ready','out_for_delivery','delivered','declined')),
  note text,
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_created_idx on public.order_events(order_id, created_at);

alter table public.store_settings enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_events enable row level security;

drop policy if exists "Public can view available cakes" on public.products;
create policy "Public can view available cakes" on public.products for select to anon, authenticated using (is_available or owner_id = auth.uid());
drop policy if exists "Owner manages products" on public.products;
create policy "Owner manages products" on public.products for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owner reads store settings" on public.store_settings;
create policy "Owner reads store settings" on public.store_settings for select to authenticated using (owner_id = auth.uid());
drop policy if exists "Owner updates store settings" on public.store_settings;
create policy "Owner updates store settings" on public.store_settings for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owner reads orders" on public.orders;
create policy "Owner reads orders" on public.orders for select to authenticated using (owner_id = auth.uid());
drop policy if exists "Owner reads order items" on public.order_items;
create policy "Owner reads order items" on public.order_items for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id and o.owner_id = auth.uid()));
drop policy if exists "Owner reads order events" on public.order_events;
create policy "Owner reads order events" on public.order_events for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id and o.owner_id = auth.uid()));

create or replace function public.get_storefront_settings()
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object('bakery_name', bakery_name, 'tagline', tagline, 'phone', phone,
    'whatsapp_number', whatsapp_number, 'upi_id', upi_id, 'delivery_area', delivery_area,
    'hero_image_url', hero_image_url)
  from public.store_settings where singleton = true;
$$;
revoke all on function public.get_storefront_settings() from public;
grant execute on function public.get_storefront_settings() to anon, authenticated;

create or replace function public.create_public_order(p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_owner uuid;
  v_order_id uuid := gen_random_uuid();
  v_number text := 'BB-' || upper(substr(encode(extensions.gen_random_bytes(5), 'hex'), 1, 8));
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_subtotal numeric(10,2) := 0;
  v_item jsonb;
  v_product public.products%rowtype;
  v_variant text;
  v_flavour text;
  v_quantity integer;
  v_price numeric(10,2);
  v_lead integer := 0;
  v_requested date;
begin
  select owner_id into v_owner from public.store_settings where singleton = true;
  if v_owner is null then raise exception 'Bakery setup is not complete'; end if;
  if coalesce(trim(p_order->>'customer_name'), '') = '' or coalesce(trim(p_order->>'customer_phone'), '') = '' or coalesce(trim(p_order->>'delivery_address'), '') = '' then
    raise exception 'Name, mobile number, and delivery address are required';
  end if;
  if jsonb_typeof(p_order->'items') <> 'array' or jsonb_array_length(p_order->'items') = 0 then raise exception 'Add at least one cake'; end if;
  if jsonb_array_length(p_order->'items') > 20 then raise exception 'Cart has too many different cakes'; end if;
  if nullif(p_order->>'requested_for', '') is not null then v_requested := (p_order->>'requested_for')::date; end if;

  for v_item in select value from jsonb_array_elements(p_order->'items') loop
    v_quantity := (v_item->>'quantity')::integer;
    if v_quantity < 1 or v_quantity > 20 then raise exception 'Cake quantity is not valid'; end if;
    select * into v_product from public.products where id = (v_item->>'product_id')::uuid and owner_id = v_owner and is_available = true;
    if not found then raise exception 'A cake in your cart is no longer available'; end if;
    v_variant := coalesce(v_item->>'variant_label','');
    select (variant.value->>'price')::numeric into v_price from jsonb_array_elements(v_product.variants) as variant(value) where variant.value->>'label' = v_variant limit 1;
    if v_price is null or v_price < 0 then raise exception 'A selected cake size is no longer available'; end if;
    v_flavour := coalesce(v_item->>'flavour','');
    if cardinality(v_product.flavours) > 0 and not (v_product.flavours @> array[v_flavour]) then raise exception 'A selected cake flavour is no longer available'; end if;
    v_subtotal := v_subtotal + v_price * v_quantity;
    v_lead := greatest(v_lead, v_product.lead_days);
  end loop;
  if v_requested is not null and v_requested < current_date + v_lead then raise exception 'Requested date does not meet advance notice'; end if;

  insert into public.orders(id, owner_id, order_number, tracking_token, customer_name, customer_phone, delivery_address, requested_for, delivery_preference, subtotal)
  values(v_order_id, v_owner, v_number, v_token, trim(p_order->>'customer_name'), trim(p_order->>'customer_phone'), trim(p_order->>'delivery_address'), v_requested, coalesce(p_order->>'delivery_preference',''), v_subtotal);
  for v_item in select value from jsonb_array_elements(p_order->'items') loop
    select * into v_product from public.products where id = (v_item->>'product_id')::uuid and owner_id = v_owner;
    v_variant := v_item->>'variant_label'; v_flavour := coalesce(v_item->>'flavour',''); v_quantity := (v_item->>'quantity')::integer;
    select (variant.value->>'price')::numeric into v_price from jsonb_array_elements(v_product.variants) as variant(value) where variant.value->>'label' = v_variant limit 1;
    insert into public.order_items(order_id, product_id, product_name, variant_label, flavour, unit_price, quantity, line_total)
    values(v_order_id, v_product.id, v_product.name, v_variant, v_flavour, v_price, v_quantity, v_price * v_quantity);
  end loop;
  insert into public.order_events(order_id,status,note) values(v_order_id,'requested','Order request received');
  return jsonb_build_object('id',v_order_id,'order_number',v_number,'token',v_token);
end;
$$;
revoke all on function public.create_public_order(jsonb) from public;
grant execute on function public.create_public_order(jsonb) to anon, authenticated;

create or replace function public.get_public_order(p_token text)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id',o.id,'order_number',o.order_number,'customer_name',o.customer_name,'customer_phone',o.customer_phone,
    'delivery_address',o.delivery_address,'requested_for',o.requested_for,'delivery_preference',o.delivery_preference,
    'subtotal',o.subtotal,'delivery_fee',o.delivery_fee,'total',o.total,'confirmed_slot',o.confirmed_slot,
    'delivery_note',o.delivery_note,'status',o.status,'is_paid',o.is_paid,'tracking_token',o.tracking_token,'created_at',o.created_at,
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_name',i.product_name,'variant_label',i.variant_label,'flavour',i.flavour,'unit_price',i.unit_price,'quantity',i.quantity,'line_total',i.line_total) order by i.created_at) from public.order_items i where i.order_id=o.id),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'status',e.status,'note',e.note,'created_at',e.created_at) order by e.created_at) from public.order_events e where e.order_id=o.id),'[]'::jsonb)
  ) from public.orders o where o.tracking_token = p_token limit 1;
$$;
revoke all on function public.get_public_order(text) from public;
grant execute on function public.get_public_order(text) to anon, authenticated;

create or replace function public.accept_order(p_order_id uuid, p_confirmed_slot timestamptz, p_delivery_fee numeric, p_delivery_note text default '')
returns void language plpgsql security definer set search_path = public
as $$
declare v_order public.orders%rowtype;
begin
  select * into v_order from public.orders where id=p_order_id and owner_id=auth.uid() for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.status <> 'requested' then raise exception 'Only a new request can be accepted'; end if;
  if p_confirmed_slot is null or p_confirmed_slot <= now() then raise exception 'Choose a future delivery time'; end if;
  if p_delivery_fee is null or p_delivery_fee < 0 then raise exception 'Delivery fee must be zero or more'; end if;
  update public.orders set status='accepted', confirmed_slot=p_confirmed_slot, delivery_fee=p_delivery_fee, total=subtotal+p_delivery_fee, delivery_note=nullif(trim(p_delivery_note),''), updated_at=now() where id=p_order_id;
  insert into public.order_events(order_id,status,note) values(p_order_id,'accepted',concat('Delivery confirmed for ',to_char(p_confirmed_slot,'DD Mon YYYY HH12:MI AM')));
end;
$$;
revoke all on function public.accept_order(uuid,timestamptz,numeric,text) from public;
grant execute on function public.accept_order(uuid,timestamptz,numeric,text) to authenticated;

create or replace function public.mark_order_paid(p_order_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare v_order public.orders%rowtype;
begin
  select * into v_order from public.orders where id=p_order_id and owner_id=auth.uid() for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.status <> 'accepted' then raise exception 'Accept and confirm delivery before recording payment'; end if;
  if v_order.is_paid then raise exception 'Payment is already recorded'; end if;
  update public.orders set status='payment_received',is_paid=true,updated_at=now() where id=p_order_id;
  insert into public.order_events(order_id,status,note) values(p_order_id,'payment_received',coalesce(nullif(trim(p_note),''),'Payment received'));
end;
$$;
revoke all on function public.mark_order_paid(uuid,text) from public;
grant execute on function public.mark_order_paid(uuid,text) to authenticated;

create or replace function public.set_order_stage(p_order_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare v_order public.orders%rowtype; v_expected text;
begin
  select * into v_order from public.orders where id=p_order_id and owner_id=auth.uid() for update;
  if not found then raise exception 'Order not found'; end if;
  v_expected := case v_order.status when 'payment_received' then 'baking' when 'baking' then 'ready' when 'ready' then 'out_for_delivery' when 'out_for_delivery' then 'delivered' else null end;
  if v_expected is null or p_status is distinct from v_expected then raise exception 'Update the next preparation stage in order'; end if;
  update public.orders set status=p_status,updated_at=now() where id=p_order_id;
  insert into public.order_events(order_id,status,note) values(p_order_id,p_status,nullif(trim(p_note),''));
end;
$$;
revoke all on function public.set_order_stage(uuid,text,text) from public;
grant execute on function public.set_order_stage(uuid,text,text) to authenticated;

create or replace function public.decline_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.orders set status='declined',updated_at=now() where id=p_order_id and owner_id=auth.uid() and status='requested';
  if not found then raise exception 'Only a new request can be declined'; end if;
  insert into public.order_events(order_id,status,note) values(p_order_id,'declined','The bakery could not accept this request');
end;
$$;
revoke all on function public.decline_order(uuid) from public;
grant execute on function public.decline_order(uuid) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('cake-photos','cake-photos',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "Cake photos are public" on storage.objects;
create policy "Cake photos are public" on storage.objects for select using (bucket_id='cake-photos');
drop policy if exists "Bakery owner uploads photos" on storage.objects;
create policy "Bakery owner uploads photos" on storage.objects for insert to authenticated with check (bucket_id='cake-photos' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "Bakery owner updates photos" on storage.objects;
create policy "Bakery owner updates photos" on storage.objects for update to authenticated using (bucket_id='cake-photos' and (storage.foldername(name))[1]=auth.uid()::text) with check (bucket_id='cake-photos' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "Bakery owner removes photos" on storage.objects;
create policy "Bakery owner removes photos" on storage.objects for delete to authenticated using (bucket_id='cake-photos' and (storage.foldername(name))[1]=auth.uid()::text);
