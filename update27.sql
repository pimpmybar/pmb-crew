-- PMB CREW — aktualizacja 27: fundament wielofirmowy (etap 1 architektury)
-- Bezpieczna do wielokrotnego uruchomienia. Wymaga wszystkich wcześniejszych update'ów (stan = schema.sql).
-- Sekcje: A organizacje i org_id · B polityki RLS · C funkcje ekipy · D funkcje magazynu · E funkcje ze slugiem

-- ===== A. ORGANIZACJE =====
create table if not exists orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique not null,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz default now()
);
create table if not exists org_members (
  org_id uuid not null references orgs(id) on delete cascade,
  user_id uuid not null,                    -- auth.users.id (bez FK: testowalność, kasowanie użytkownika nie kasuje historii)
  role text not null default 'owner',       -- owner | admin | member
  created_at timestamptz default now(),
  primary key (org_id, user_id)
);

-- organizacja PMB (stały identyfikator) i przypisanie wszystkich istniejących użytkowników
insert into orgs (id, name, slug, config) values (
  '00000000-0000-0000-0000-000000000001', 'Pimp My Bar', 'pmb',
  '{"brand":"PIMP MY BAR",
    "cat_order":["ALKOHOLE","PIWO I KEGI","NAPOJE","OWOCE","SYROPY I SOK","KAWA","DODATKI","LÓD","SZKŁO","BAR","CHECK LIST"],
    "buy_default":["ALKOHOLE","PIWO I KEGI","NAPOJE","OWOCE","SYROPY I SOK","KAWA","DODATKI"]}'::jsonb
) on conflict (id) do nothing;
insert into org_members (org_id, user_id, role)
  select '00000000-0000-0000-0000-000000000001', id, 'owner' from auth.users
  on conflict do nothing;

-- organizacja zalogowanego użytkownika (null = brak członkostwa = nic nie widać)
create or replace function current_org_id() returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from org_members where user_id = auth.uid() order by created_at limit 1
$$;
grant execute on function current_org_id() to anon, authenticated;

-- org_id w każdej tabeli biznesowej: dodaj → wypełnij PMB → wymagane → domyślne z sesji → indeks
do $$
declare t text;
begin
  foreach t in array array['events','crew','assignments','packing_items','catalog','recipes','remanenty','settings','updates','shop_lists','shop_checks'] loop
    execute format('alter table %I add column if not exists org_id uuid references orgs(id)', t);
    execute format('update %I set org_id = %L where org_id is null', t, '00000000-0000-0000-0000-000000000001');
    execute format('alter table %I alter column org_id set not null', t);
    execute format('alter table %I alter column org_id set default current_org_id()', t);
    execute format('create index if not exists %I on %I (org_id)', t || '_org_id_idx', t);
  end loop;
end $$;

-- klucze i unikalność per organizacja
alter table settings drop constraint if exists settings_pkey;
alter table settings add primary key (org_id, key);
alter table shop_lists drop constraint if exists shop_lists_pkey;
alter table shop_lists add primary key (org_id, week_key);
alter table shop_checks drop constraint if exists shop_checks_pkey;
alter table shop_checks add primary key (org_id, week_key, item_key);
alter table catalog drop constraint if exists catalog_category_name_key;
alter table catalog drop constraint if exists catalog_org_category_name_key;
alter table catalog add constraint catalog_org_category_name_key unique (org_id, category, name);
alter table crew drop constraint if exists crew_phone_key;
alter table crew drop constraint if exists crew_org_phone_key;
alter table crew add constraint crew_org_phone_key unique (org_id, phone);
alter table recipes drop constraint if exists recipes_name_key;
alter table recipes drop constraint if exists recipes_org_name_key;
alter table recipes add constraint recipes_org_name_key unique (org_id, name);

-- ===== B. POLITYKI RLS: tylko własna organizacja =====
do $$
declare t text; old text;
begin
  for t, old in select * from (values
    ('events','auth all events'), ('crew','auth all crew'), ('assignments','auth all assignments'),
    ('packing_items','auth all packing'), ('catalog','auth all catalog'), ('recipes','auth all recipes'),
    ('remanenty','auth all remanenty'), ('settings','auth all settings'), ('updates','auth all updates'),
    ('shop_lists','shop_lists auth all'), ('shop_checks','shop_checks auth all')) v(t, old)
  loop
    execute format('drop policy if exists %I on %I', old, t);
    execute format('drop policy if exists %I on %I', 'org_' || t, t);
    execute format('create policy %I on %I for all to authenticated using (org_id = current_org_id()) with check (org_id = current_org_id())', 'org_' || t, t);
  end loop;
end $$;

alter table orgs enable row level security;
alter table org_members enable row level security;
drop policy if exists orgs_select_own on orgs;
create policy orgs_select_own on orgs for select to authenticated using (id = current_org_id());
drop policy if exists orgs_update_owner on orgs;
create policy orgs_update_owner on orgs for update to authenticated
  using (id = current_org_id() and exists (select 1 from org_members m where m.org_id = orgs.id and m.user_id = auth.uid() and m.role in ('owner','admin')))
  with check (id = current_org_id());
drop policy if exists org_members_select_own on org_members;
create policy org_members_select_own on org_members for select to authenticated using (org_id = current_org_id());
grant select, update on orgs to authenticated;
grant select on org_members to authenticated;

-- ===== C. FUNKCJE EKIPY =====
-- token przydziału → organizacja z assignments.org_id
create or replace function crew_get(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare a assignments; e events; c crew; o orgs; ups json;
begin
  select * into a from assignments where token = p_token;
  if not found then return null; end if;
  if a.status = 'wyslany' then
    update assignments set status = 'otwarty', opened_at = now() where id = a.id returning * into a;
  end if;
  select * into e from events where id = a.event_id and org_id = a.org_id;
  select * into c from crew where id = a.crew_id and org_id = a.org_id;
  select * into o from orgs where id = a.org_id;
  select coalesce(json_agg(json_build_object('created_at', u.created_at, 'message', u.message) order by u.created_at desc), '[]'::json)
    into ups from updates u where u.event_id = e.id and u.org_id = a.org_id;
  return json_build_object(
    'org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name)),
    'assignment', json_build_object('status', a.status, 'role', a.role, 'rate_amount', a.rate_amount,
       'rate_unit', a.rate_unit, 'rate_note', a.rate_note, 'counter_offer', a.counter_offer,
       'responded_at', a.responded_at, 'seen_agenda_version', a.seen_agenda_version),
    'crew', json_build_object('first_name', c.first_name, 'last_name', c.last_name, 'phone', c.phone,
       'email', c.email, 'city', c.city, 'driving_license', c.driving_license, 'has_car', c.has_car, 'shirt_size', c.shirt_size,
       'experience', c.experience, 'student', c.student, 'my_token', c.my_token),
    'event', json_build_object('name', coalesce(nullif(e.crew_name,''), e.name), 'status', e.status, 'event_date', e.event_date,
       'start_time', e.start_time, 'end_time', e.end_time, 'venue', e.venue, 'venue_url', e.venue_url, 'address', e.address,
       'map_url', e.map_url, 'guests', e.guests, 'bartenders_needed', e.bartenders_needed,
       'helpers_needed', e.helpers_needed, 'summary', e.summary, 'dress_code', e.dress_code,
       'payment_info', e.payment_info, 'travel_note', e.travel_note, 'meeting_place', e.meeting_place, 'schedule', e.schedule),
    'agenda', case when a.status = 'zaakceptowany' and e.agenda_published then json_build_object(
       'meeting_place', e.meeting_place, 'meeting_time', e.meeting_time, 'dress_code', e.dress_code,
       'packing_list', e.packing_list, 'cash_needed', e.cash_needed, 'cash_note', e.cash_note,
       'contact_name', e.contact_name, 'contact_phone', e.contact_phone, 'menu', e.menu,
       'transport', e.transport, 'vehicle', e.vehicle, 'branding', e.branding, 'schedule', e.schedule,
       'notes', e.notes, 'version', e.agenda_version, 'updated_at', e.updated_at)
       else null end,
    'updates', case when a.status = 'zaakceptowany' then ups else '[]'::json end
  );
end $$;

create or replace function crew_respond(p_token text, p_action text, p_data json)
returns json language plpgsql security definer set search_path = public as $$
declare a assignments;
begin
  select * into a from assignments where token = p_token;
  if not found then raise exception 'bad token'; end if;
  if p_data is not null then
    update crew set
      first_name = coalesce(nullif(p_data->>'first_name',''), first_name),
      last_name  = coalesce(nullif(p_data->>'last_name',''), last_name),
      email      = coalesce(nullif(p_data->>'email',''), email),
      city       = coalesce(nullif(p_data->>'city',''), city),
      driving_license = coalesce((p_data->>'driving_license')::boolean, driving_license),
      has_car    = coalesce((p_data->>'has_car')::boolean, has_car),
      shirt_size = coalesce(nullif(p_data->>'shirt_size',''), shirt_size),
      experience = coalesce(nullif(p_data->>'experience',''), experience),
      student    = coalesce((p_data->>'student')::boolean, student),
      terms_accepted_at = case when (p_data->>'accept_terms') = 'true' then coalesce(terms_accepted_at, now()) else terms_accepted_at end
    where id = a.crew_id and org_id = a.org_id;
  end if;
  if p_action = 'accept' then
    update assignments set status = 'zaakceptowany', responded_at = now(), counter_offer = null where id = a.id;
    update crew set status = 'aktywny' where id = a.crew_id and org_id = a.org_id and status = 'nowy';
  elsif p_action = 'decline' then
    update assignments set status = 'odrzucony', responded_at = now(), counter_offer = nullif(p_data->>'counter_offer','') where id = a.id;
  elsif p_action = 'seen' then
    update assignments set seen_agenda_version = (select agenda_version from events where id = a.event_id and org_id = a.org_id) where id = a.id;
  end if;
  return crew_get(p_token);
end $$;

create or replace function crew_packing(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare a assignments;
begin
  select * into a from assignments where token = p_token and status = 'zaakceptowany';
  if not found then return '[]'::json; end if;
  return (select coalesce(json_agg(json_build_object(
      'id', p.id, 'category', p.category, 'name', p.name,
      'qty', coalesce(p.qty, case when p.qty_num is not null then trim(to_char(p.qty_num,'FM999999990.##')) || ' ' || coalesce(p.unit,'') else '' end) || case when p.note is not null and p.note <> '' then ' · ' || p.note else '' end,
      'sort', p.sort, 'packed_at', p.packed_at, 'packed_by', (select first_name from crew where id = p.packed_by and org_id = a.org_id)
    ) order by p.category, p.sort, p.created_at), '[]'::json)
    from packing_items p where p.event_id = a.event_id and p.org_id = a.org_id and (p.qty_num is not null or coalesce(p.qty,'') <> '' or coalesce(p.note,'') <> ''));
end $$;

create or replace function crew_pack(p_token text, p_item uuid, p_packed boolean)
returns json language plpgsql security definer set search_path = public as $$
declare a assignments;
begin
  select * into a from assignments where token = p_token and status = 'zaakceptowany';
  if not found then raise exception 'not allowed'; end if;
  update packing_items set
    packed_by = case when p_packed then a.crew_id else null end,
    packed_at = case when p_packed then now() else null end
  where id = p_item and event_id = a.event_id and org_id = a.org_id;
  return crew_packing(p_token);
end $$;

-- kod zaproszenia → organizacja z events.org_id
create or replace function crew_invite_info(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare e events; o orgs;
begin
  select * into e from events where invite_code = p_code;
  if not found then return null; end if;
  select * into o from orgs where id = e.org_id;
  return json_build_object('org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name)),
    'name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date, 'start_time', e.start_time, 'end_time', e.end_time,
    'venue', e.venue, 'address', e.address, 'open', coalesce(e.invite_open, true), 'status', e.status);
end $$;

create or replace function crew_join(p_code text, p_phone text, p_role text)
returns json language plpgsql security definer set search_path = public as $$
declare e events; c crew; a assignments; ph text; r text;
begin
  select * into e from events where invite_code = p_code;
  if not found then raise exception 'bad code'; end if;
  if not coalesce(e.invite_open, true) then raise exception 'closed'; end if;
  ph := regexp_replace(p_phone, '[^0-9+]', '', 'g');
  if ph ~ '^[0-9]{9}$' then ph := '+48' || ph; end if;
  if ph ~ '^48[0-9]{9}$' then ph := '+' || ph; end if;
  if ph ~ '^0048' then ph := '+' || substr(ph, 3); end if;
  if ph !~ '^\+[0-9]{9,15}$' then raise exception 'bad phone'; end if;
  r := case when p_role = 'pomocnik' then 'pomocnik' else 'barman' end;
  select * into c from crew where phone = ph and org_id = e.org_id;
  if not found then
    insert into crew (org_id, phone, default_role) values (e.org_id, ph, r) returning * into c;
  end if;
  select * into a from assignments where event_id = e.id and crew_id = c.id;
  if found then
    -- numer już jest na evencie: nie zdradzamy tokenu ani warunków
    return json_build_object('exists', true);
  end if;
  insert into assignments (org_id, event_id, crew_id, role, rate_amount, rate_unit, rate_note)
  values (e.org_id, e.id, c.id, r, case when r = 'pomocnik' then e.default_rate_helper else e.default_rate_bartender end, 'event', e.default_rate_note)
  returning * into a;
  return json_build_object('token', a.token);
end $$;

-- my_token → organizacja z crew.org_id
create or replace function crew_home(p_mtoken text)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; o orgs;
begin
  select * into c from crew where my_token = p_mtoken;
  if not found then return null; end if;
  select * into o from orgs where id = c.org_id;
  return json_build_object(
    'org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name)),
    'first_name', c.first_name,
    'events', (
      select coalesce(json_agg(x order by (x->>'event_date')), '[]'::json) from (
        select json_build_object(
          'name', coalesce(nullif(e.crew_name,''), e.name),
          'event_date', e.event_date, 'start_time', e.start_time, 'end_time', e.end_time,
          'venue', e.venue, 'address', e.address,
          'meeting_time', case when a.status='zaakceptowany' then e.meeting_time end,
          'meeting_place', case when a.status='zaakceptowany' then e.meeting_place end,
          'role', a.role, 'status', a.status, 'token', a.token
        ) as x
        from assignments a join events e on e.id = a.event_id and e.org_id = c.org_id
        where a.crew_id = c.id and a.org_id = c.org_id
          and e.status in ('wstepny','potwierdzony','zakonczony')
          and e.event_date >= current_date - 30
      ) s
    )
  );
end $$;

-- ===== D. FUNKCJE MAGAZYNU I ZAKUPÓW =====
-- klucz remanentu → organizacja
create or replace function stock_org(p_key text) returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from settings where key = 'stock_key' and value = p_key and value <> '' limit 1
$$;
grant execute on function stock_org(text) to anon, authenticated;
create or replace function stock_key_ok(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select stock_org(p_key) is not null
$$;

create or replace function wh_events(p_mtoken text)
returns json language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  return (select coalesce(json_agg(json_build_object(
      'id', e.id, 'name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date, 'event_end_date', e.event_end_date,
      'start_time', e.start_time, 'end_time', e.end_time, 'venue', e.venue, 'address', e.address,
      'meeting_time', e.meeting_time, 'departure_time', e.departure_time, 'vehicle', e.vehicle, 'modules', e.modules, 'branding', e.branding,
      'bartenders_needed', e.bartenders_needed, 'helpers_needed', e.helpers_needed,
      'pack_total', (select count(*) from packing_items p where p.event_id = e.id and p.org_id = c.org_id and (p.qty_num is not null or coalesce(p.qty,'')<>'' or coalesce(p.note,'')<>'')),
      'pack_done',  (select count(*) from packing_items p where p.event_id = e.id and p.org_id = c.org_id and p.packed_at is not null and (p.qty_num is not null or coalesce(p.qty,'')<>'' or coalesce(p.note,'')<>''))
    ) order by e.event_date), '[]'::json)
    from events e where e.org_id = c.org_id and e.status in ('wstepny','potwierdzony') and coalesce(e.event_end_date, e.event_date) >= current_date - 1);
end $$;

create or replace function wh_event(p_mtoken text, p_event uuid)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; e events;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  select * into e from events where id = p_event and org_id = c.org_id;
  if not found then return null; end if;
  return json_build_object(
    'event', json_build_object('id', e.id, 'name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date, 'event_end_date', e.event_end_date,
       'start_time', e.start_time, 'end_time', e.end_time, 'venue', e.venue, 'address', e.address, 'map_url', e.map_url, 'guests', e.guests,
       'bartenders_needed', e.bartenders_needed, 'helpers_needed', e.helpers_needed, 'summary', e.summary, 'schedule', e.schedule),
    'agenda', json_build_object('meeting_place', e.meeting_place, 'meeting_time', e.meeting_time, 'departure_time', e.departure_time,
       'dress_code', e.dress_code, 'packing_list', e.packing_list, 'menu', e.menu, 'transport', e.transport, 'vehicle', e.vehicle,
       'branding', e.branding, 'modules', e.modules, 'notes', e.notes, 'contact_name', e.contact_name, 'contact_phone', e.contact_phone),
    'packing', (select coalesce(json_agg(json_build_object(
        'id', p.id, 'category', p.category, 'name', p.name,
        'qty', coalesce(p.qty, case when p.qty_num is not null then trim(to_char(p.qty_num,'FM999999990.##')) || ' ' || coalesce(p.unit,'') else '' end) || case when p.note is not null and p.note <> '' then ' · ' || p.note else '' end,
        'sort', p.sort, 'packed_at', p.packed_at, 'packed_by', (select first_name from crew where id = p.packed_by and org_id = c.org_id)
      ) order by p.category, p.sort, p.created_at), '[]'::json)
      from packing_items p where p.event_id = e.id and p.org_id = c.org_id and (p.qty_num is not null or coalesce(p.qty,'') <> '' or coalesce(p.note,'') <> ''))
  );
end $$;

create or replace function wh_pack(p_mtoken text, p_item uuid, p_packed boolean)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; ev uuid;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  update packing_items set packed_by = case when p_packed then c.id else null end, packed_at = case when p_packed then now() else null end
   where id = p_item and org_id = c.org_id returning event_id into ev;
  if ev is null then raise exception 'not allowed'; end if;
  return wh_event(p_mtoken, ev);
end $$;

create or replace function stock_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key);
begin
  if o is null then raise exception 'bad key'; end if;
  return (select coalesce(json_agg(json_build_object(
      'id', id, 'category', category, 'name', name, 'unit', unit, 'stock', stock, 'photo_url', photo_url,
      'updated_at', stock_updated_at, 'updated_by', stock_updated_by) order by category, sort, name), '[]'::json)
    from catalog where active and org_id = o);
end $$;

create or replace function stock_set(p_key text, p_id uuid, p_stock numeric, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key);
begin
  if o is null then raise exception 'bad key'; end if;
  update catalog set stock = p_stock, stock_updated_at = now(), stock_updated_by = nullif(trim(p_by), '') where id = p_id and org_id = o;
  return json_build_object('ok', true);
end $$;

create or replace function stock_set_photo(p_key text, p_id uuid, p_url text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key);
begin
  if o is null then raise exception 'bad key'; end if;
  update catalog set photo_url = p_url where id = p_id and org_id = o;
  return json_build_object('ok', true);
end $$;

create or replace function stock_add(p_key text, p_category text, p_name text, p_unit text, p_stock numeric, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key); nid uuid; cat text := coalesce(nullif(trim(p_category),''),'INNE');
begin
  if o is null then raise exception 'bad key'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'no name'; end if;
  insert into catalog (org_id, category, name, unit, sort, stock, stock_updated_at, stock_updated_by)
  values (o, cat, trim(p_name), coalesce(nullif(trim(p_unit),''),'szt.'),
          (select coalesce(max(sort),0)+1 from catalog where org_id = o and category = cat), p_stock, now(), nullif(trim(p_by),''))
  on conflict (org_id, category, name) do update set stock = excluded.stock, stock_updated_at = now(), stock_updated_by = excluded.stock_updated_by, active = true
  returning id into nid;
  return json_build_object('ok', true, 'id', nid);
end $$;

create or replace function stock_snapshot(p_key text, p_note text, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key); n int;
begin
  if o is null then raise exception 'bad key'; end if;
  insert into remanenty (org_id, note, items)
  select o, trim(both ' —' from coalesce(nullif(trim(p_note),''),'remanent') || case when nullif(trim(p_by),'') is not null then ' — ' || trim(p_by) else '' end),
         coalesce(jsonb_agg(jsonb_build_object('id', id, 'category', category, 'name', name, 'unit', unit, 'stock', stock)), '[]'::jsonb)
  from catalog where active and org_id = o;
  get diagnostics n = row_count;
  return json_build_object('ok', n > 0);
end $$;

create or replace function shop_get(p_mtoken text, p_week text default null)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; l shop_lists; o orgs;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  select * into o from orgs where id = c.org_id;
  if p_week is not null then
    select * into l from shop_lists where org_id = c.org_id and week_key = p_week;
  end if;
  if l.week_key is null then
    select * into l from shop_lists where org_id = c.org_id and week_to >= current_date - 1 order by week_from asc limit 1;
  end if;
  if l.week_key is null then
    select * into l from shop_lists where org_id = c.org_id order by updated_at desc limit 1;
  end if;
  return json_build_object(
    'org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name), 'cat_order', coalesce(o.config->'cat_order', '[]'::jsonb)),
    'first_name', c.first_name,
    'weeks', (select coalesce(json_agg(json_build_object('week_key', week_key, 'week_from', week_from, 'week_to', week_to, 'updated_at', updated_at) order by week_from desc), '[]'::json)
              from shop_lists where org_id = c.org_id and week_to >= current_date - 14),
    'list', case when l.week_key is null then null else json_build_object('week_key', l.week_key, 'week_from', l.week_from, 'week_to', l.week_to, 'updated_at', l.updated_at, 'items', l.items) end,
    'checks', (select coalesce(json_object_agg(item_key, json_build_object('at', checked_at, 'by', checked_by)), '{}'::json) from shop_checks where org_id = c.org_id and week_key = l.week_key)
  );
end $$;

create or replace function shop_check(p_mtoken text, p_week text, p_item text, p_checked boolean)
returns json language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  if p_checked then
    insert into shop_checks (org_id, week_key, item_key, checked_by) values (c.org_id, p_week, p_item, c.first_name)
    on conflict (org_id, week_key, item_key) do update set checked_at = now(), checked_by = excluded.checked_by;
  else
    delete from shop_checks where org_id = c.org_id and week_key = p_week and item_key = p_item;
  end if;
  return shop_get(p_mtoken, p_week);
end $$;

-- ===== E. FUNKCJE ZE SLUGIEM ORGANIZACJI (rekrutacja, warunki, receptury) =====
drop function if exists crew_terms();
create or replace function crew_terms(p_org text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name)),
    'terms', (select value from settings where org_id = o.id and key = 'terms'),
    'warehouse', (select value from settings where org_id = o.id and key = 'warehouse'),
    'recruit_open', coalesce((select value from settings where org_id = o.id and key = 'recruit_open'), 'true') = 'true')
  from orgs o where o.slug = p_org
$$;
grant execute on function crew_terms(text) to anon, authenticated;

drop function if exists crew_recipes();
create or replace function crew_recipes(p_org text)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('name',r.name,'aliases',r.aliases,'category',r.category,'ing_short',r.ing_short,'descr',r.descr,'recipe',r.recipe,'glass',r.glass,'ice',r.ice,'garnish',r.garnish,'method',r.method,'is_mock',r.is_mock) order by r.category, r.sort, r.name), '[]'::json)
  from recipes r join orgs o on o.id = r.org_id where o.slug = p_org and r.active
$$;
grant execute on function crew_recipes(text) to anon, authenticated;

drop function if exists crew_register(text, json);
create or replace function crew_register(p_org text, p_phone text, p_data json)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid; c crew; ph text;
begin
  select id into o from orgs where slug = p_org;
  if o is null then raise exception 'bad org'; end if;
  if coalesce((select value from settings where org_id = o and key = 'recruit_open'), 'true') <> 'true' then raise exception 'closed'; end if;
  ph := regexp_replace(p_phone, '[^0-9+]', '', 'g');
  if ph ~ '^[0-9]{9}$' then ph := '+48' || ph; end if;
  if ph ~ '^48[0-9]{9}$' then ph := '+' || ph; end if;
  if ph ~ '^0048' then ph := '+' || substr(ph, 3); end if;
  if ph !~ '^\+[0-9]{9,15}$' then raise exception 'bad phone'; end if;
  if (p_data->>'accept_terms') is distinct from 'true' then raise exception 'terms'; end if;
  select * into c from crew where phone = ph and org_id = o;
  if found and c.terms_accepted_at is not null then
    return json_build_object('exists', true);
  end if;
  if not found then
    insert into crew (org_id, phone, status, source) values (o, ph, 'nowy', 'rekrutacja') returning * into c;
  end if;
  update crew set
    first_name = coalesce(nullif(p_data->>'first_name',''), first_name),
    last_name  = coalesce(nullif(p_data->>'last_name',''), last_name),
    email      = coalesce(nullif(p_data->>'email',''), email),
    city       = coalesce(nullif(p_data->>'city',''), city),
    driving_license = coalesce((p_data->>'driving_license')::boolean, driving_license),
    has_car    = coalesce((p_data->>'has_car')::boolean, has_car),
    shirt_size = coalesce(nullif(p_data->>'shirt_size',''), shirt_size),
    experience = coalesce(nullif(p_data->>'experience',''), experience),
    student    = coalesce((p_data->>'student')::boolean, student),
    default_role = coalesce(nullif(p_data->>'role',''), default_role),
    terms_accepted_at = now()
  where id = c.id;
  return json_build_object('ok', true);
end $$;
grant execute on function crew_register(text, text, json) to anon, authenticated;

notify pgrst, 'reload schema';
