-- PMB CREW — schemat bazy (stan produkcyjny Supabase po update26, zrzut z 01.09.2026)
-- Odtworzony z pg_catalog projektu zqpqjgxtefzojhjglppb, bo oryginalne pliki schema.sql + update1–26.sql przepadły.
-- Ten plik zastępuje cały ciąg schema.sql + update1..26. Kolejne zmiany: update27.sql i dalej.
-- Bezpieczny do wielokrotnego uruchomienia.

create extension if not exists pgcrypto;

-- ===== TABELE =====
create table if not exists assignments (
  id uuid not null default gen_random_uuid(),
  created_at timestamp with time zone default now(),
  event_id uuid not null,
  crew_id uuid not null,
  token text not null default encode(gen_random_bytes(9), 'hex'::text),
  role text not null default 'barman'::text,
  rate_amount numeric,
  rate_unit text default 'event'::text,
  rate_note text,
  status text not null default 'wyslany'::text,
  counter_offer text,
  opened_at timestamp with time zone,
  responded_at timestamp with time zone,
  seen_agenda_version integer default 0
);

create table if not exists catalog (
  id uuid not null default gen_random_uuid(),
  category text not null,
  name text not null,
  unit text default 'szt.'::text,
  sort integer default 0,
  stock numeric,
  stock_updated_at timestamp with time zone,
  active boolean default true,
  stock_updated_by text,
  photo_url text,
  group_name text,
  price numeric
);

create table if not exists crew (
  id uuid not null default gen_random_uuid(),
  created_at timestamp with time zone default now(),
  phone text not null,
  first_name text,
  last_name text,
  email text,
  city text,
  driving_license boolean,
  shirt_size text,
  experience text,
  student boolean,
  birth_date date,
  default_role text default 'barman'::text,
  rating integer,
  notes text,
  active boolean default true,
  has_car boolean,
  terms_accepted_at timestamp with time zone,
  status text default 'nowy'::text,
  source text,
  my_token text default encode(gen_random_bytes(9), 'hex'::text),
  warehouse_access boolean default false
);

create table if not exists events (
  id uuid not null default gen_random_uuid(),
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now(),
  name text not null,
  client text,
  status text not null default 'wstepny'::text,
  event_date date not null,
  start_time text,
  end_time text,
  venue text,
  address text,
  map_url text,
  guests integer,
  bartenders_needed integer default 0,
  helpers_needed integer default 0,
  summary text,
  agenda_published boolean default false,
  meeting_place text,
  meeting_time text,
  dress_code text,
  packing_list text,
  cash_needed boolean default false,
  cash_note text,
  contact_name text,
  contact_phone text,
  menu text,
  transport text,
  notes text,
  agenda_version integer default 0,
  venue_url text,
  payment_info text,
  travel_note text,
  vehicle text,
  branding text,
  schedule text,
  invite_code text default encode(gen_random_bytes(5), 'hex'::text),
  default_rate_bartender numeric,
  default_rate_helper numeric,
  default_rate_note text,
  invite_open boolean default true,
  contract_url text,
  service_type text,
  organizer_phone text,
  distance_km numeric,
  tolls text,
  travel_time text,
  welcome_drinks text,
  departure_time text,
  modules text,
  payment_type text,
  crew_name text,
  checklist jsonb default '{}'::jsonb,
  event_end_date date
);

create table if not exists packing_items (
  id uuid not null default gen_random_uuid(),
  event_id uuid not null,
  category text not null default 'INNE'::text,
  name text not null,
  qty text,
  sort integer default 0,
  packed_by uuid,
  packed_at timestamp with time zone,
  created_at timestamp with time zone default now(),
  qty_num numeric,
  unit text,
  catalog_id uuid,
  note text
);

create table if not exists recipes (
  id uuid not null default gen_random_uuid(),
  created_at timestamp with time zone default now(),
  category text not null,
  sort integer default 0,
  name text not null,
  aliases text,
  ing_short text,
  descr text,
  recipe text,
  glass text,
  ice text,
  garnish text,
  method text,
  is_mock boolean default false,
  active boolean default true
);

create table if not exists remanenty (
  id uuid not null default gen_random_uuid(),
  created_at timestamp with time zone default now(),
  note text,
  items jsonb not null
);

create table if not exists settings (
  key text not null,
  value text,
  updated_at timestamp with time zone default now()
);

create table if not exists shop_checks (
  week_key text not null,
  item_key text not null,
  checked_at timestamp with time zone default now(),
  checked_by text
);

create table if not exists shop_lists (
  week_key text not null,
  week_from date,
  week_to date,
  items jsonb not null default '[]'::jsonb,
  updated_at timestamp with time zone default now()
);

create table if not exists updates (
  id uuid not null default gen_random_uuid(),
  created_at timestamp with time zone default now(),
  event_id uuid not null,
  message text not null
);

-- ===== KLUCZE I OGRANICZENIA =====
do $$
declare r record;
begin
  for r in select * from (values
    ('assignments','assignments_pkey','primary key (id)'),
    ('catalog','catalog_pkey','primary key (id)'),
    ('crew','crew_pkey','primary key (id)'),
    ('events','events_pkey','primary key (id)'),
    ('packing_items','packing_items_pkey','primary key (id)'),
    ('recipes','recipes_pkey','primary key (id)'),
    ('remanenty','remanenty_pkey','primary key (id)'),
    ('settings','settings_pkey','primary key (key)'),
    ('shop_checks','shop_checks_pkey','primary key (week_key, item_key)'),
    ('shop_lists','shop_lists_pkey','primary key (week_key)'),
    ('updates','updates_pkey','primary key (id)'),
    ('assignments','assignments_event_id_crew_id_key','unique (event_id, crew_id)'),
    ('assignments','assignments_token_key','unique (token)'),
    ('catalog','catalog_category_name_key','unique (category, name)'),
    ('crew','crew_my_token_key','unique (my_token)'),
    ('crew','crew_phone_key','unique (phone)'),
    ('events','events_invite_code_key','unique (invite_code)'),
    ('recipes','recipes_name_key','unique (name)'),
    ('assignments','assignments_crew_id_fkey','foreign key (crew_id) references crew(id) on delete cascade'),
    ('assignments','assignments_event_id_fkey','foreign key (event_id) references events(id) on delete cascade'),
    ('packing_items','packing_items_catalog_id_fkey','foreign key (catalog_id) references catalog(id) on delete set null'),
    ('packing_items','packing_items_event_id_fkey','foreign key (event_id) references events(id) on delete cascade'),
    ('packing_items','packing_items_packed_by_fkey','foreign key (packed_by) references crew(id) on delete set null'),
    ('updates','updates_event_id_fkey','foreign key (event_id) references events(id) on delete cascade')
  ) v(t, c, def)
  loop
    if not exists (select 1 from pg_constraint where conname = r.c and connamespace = 'public'::regnamespace) then
      execute format('alter table %I add constraint %I %s', r.t, r.c, r.def);
    end if;
  end loop;
end $$;

-- ===== RLS: wszystkie tabele, polityki „zalogowany widzi wszystko” (stan przed etapem 1) =====
do $$
declare t text; pol text;
begin
  for t, pol in select * from (values
    ('assignments','auth all assignments'), ('catalog','auth all catalog'), ('crew','auth all crew'),
    ('events','auth all events'), ('packing_items','auth all packing'), ('recipes','auth all recipes'),
    ('remanenty','auth all remanenty'), ('settings','auth all settings'), ('updates','auth all updates'),
    ('shop_checks','shop_checks auth all'), ('shop_lists','shop_lists auth all')) v(t, pol)
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', pol, t);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', pol, t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
  end loop;
end $$;

-- ===== TRIGGER =====
create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists events_touch on events;
create trigger events_touch before update on events for each row execute function touch_updated_at();

-- ===== FUNKCJE EKIPY (token przydziału, zaproszenie, my_token) =====
create or replace function crew_get(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare a assignments; e events; c crew; ups json;
begin
  select * into a from assignments where token = p_token;
  if not found then return null; end if;
  if a.status = 'wyslany' then
    update assignments set status = 'otwarty', opened_at = now() where id = a.id returning * into a;
  end if;
  select * into e from events where id = a.event_id;
  select * into c from crew where id = a.crew_id;
  select coalesce(json_agg(json_build_object('created_at', u.created_at, 'message', u.message) order by u.created_at desc), '[]'::json)
    into ups from updates u where u.event_id = e.id;
  return json_build_object(
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

create or replace function crew_home(p_mtoken text)
returns json language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  select * into c from crew where my_token = p_mtoken;
  if not found then return null; end if;
  return json_build_object(
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
        from assignments a join events e on e.id = a.event_id
        where a.crew_id = c.id
          and e.status in ('wstepny','potwierdzony','zakonczony')
          and e.event_date >= current_date - 30
      ) s
    )
  );
end $$;

create or replace function crew_invite_info(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare e events;
begin
  select * into e from events where invite_code = p_code;
  if not found then return null; end if;
  return json_build_object('name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date, 'start_time', e.start_time, 'end_time', e.end_time,
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
  select * into c from crew where phone = ph;
  if not found then
    insert into crew (phone, default_role) values (ph, r) returning * into c;
  end if;
  select * into a from assignments where event_id = e.id and crew_id = c.id;
  if found then
    -- numer już jest na evencie: nie zdradzamy tokenu ani warunków
    return json_build_object('exists', true);
  end if;
  insert into assignments (event_id, crew_id, role, rate_amount, rate_unit, rate_note)
  values (e.id, c.id, r, case when r = 'pomocnik' then e.default_rate_helper else e.default_rate_bartender end, 'event', e.default_rate_note)
  returning * into a;
  return json_build_object('token', a.token);
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
      'sort', p.sort, 'packed_at', p.packed_at, 'packed_by', (select first_name from crew where id = p.packed_by)
    ) order by p.category, p.sort, p.created_at), '[]'::json)
    from packing_items p where p.event_id = a.event_id and (p.qty_num is not null or coalesce(p.qty,'') <> '' or coalesce(p.note,'') <> ''));
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
  where id = p_item and event_id = a.event_id;
  return crew_packing(p_token);
end $$;

create or replace function crew_recipes()
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('name',name,'aliases',aliases,'category',category,'ing_short',ing_short,'descr',descr,'recipe',recipe,'glass',glass,'ice',ice,'garnish',garnish,'method',method,'is_mock',is_mock) order by category, sort, name), '[]'::json)
  from recipes where active;
$$;

create or replace function crew_register(p_phone text, p_data json)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; ph text;
begin
  if coalesce((select value from settings where key = 'recruit_open'), 'true') <> 'true' then raise exception 'closed'; end if;
  ph := regexp_replace(p_phone, '[^0-9+]', '', 'g');
  if ph ~ '^[0-9]{9}$' then ph := '+48' || ph; end if;
  if ph ~ '^48[0-9]{9}$' then ph := '+' || ph; end if;
  if ph ~ '^0048' then ph := '+' || substr(ph, 3); end if;
  if ph !~ '^\+[0-9]{9,15}$' then raise exception 'bad phone'; end if;
  if (p_data->>'accept_terms') is distinct from 'true' then raise exception 'terms'; end if;
  select * into c from crew where phone = ph;
  if found and c.terms_accepted_at is not null then
    return json_build_object('exists', true);
  end if;
  if not found then
    insert into crew (phone, status, source) values (ph, 'nowy', 'rekrutacja') returning * into c;
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
    where id = a.crew_id;
  end if;
  if p_action = 'accept' then
    update assignments set status = 'zaakceptowany', responded_at = now(), counter_offer = null where id = a.id;
    update crew set status = 'aktywny' where id = a.crew_id and status = 'nowy';
  elsif p_action = 'decline' then
    update assignments set status = 'odrzucony', responded_at = now(), counter_offer = nullif(p_data->>'counter_offer','') where id = a.id;
  elsif p_action = 'seen' then
    update assignments set seen_agenda_version = (select agenda_version from events where id = a.event_id) where id = a.id;
  end if;
  return crew_get(p_token);
end $$;

create or replace function crew_terms()
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'terms', (select value from settings where key = 'terms'),
    'warehouse', (select value from settings where key = 'warehouse'),
    'recruit_open', coalesce((select value from settings where key = 'recruit_open'), 'true') = 'true');
$$;

-- ===== FUNKCJE MAGAZYNU (my_token z warehouse_access, klucz remanentu) =====
create or replace function stock_key_ok(p_key text)
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from settings where key = 'stock_key' and value = p_key and value <> '');
$$;

create or replace function stock_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not stock_key_ok(p_key) then raise exception 'bad key'; end if;
  return (select coalesce(json_agg(json_build_object(
      'id', id, 'category', category, 'name', name, 'unit', unit, 'stock', stock, 'photo_url', photo_url,
      'updated_at', stock_updated_at, 'updated_by', stock_updated_by) order by category, sort, name), '[]'::json)
    from catalog where active);
end $$;

create or replace function stock_set(p_key text, p_id uuid, p_stock numeric, p_by text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from settings where key = 'stock_key' and value = p_key and value <> '') then
    raise exception 'bad key';
  end if;
  update catalog set stock = p_stock, stock_updated_at = now(), stock_updated_by = nullif(trim(p_by), '') where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function stock_set_photo(p_key text, p_id uuid, p_url text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not stock_key_ok(p_key) then raise exception 'bad key'; end if;
  update catalog set photo_url = p_url where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function stock_add(p_key text, p_category text, p_name text, p_unit text, p_stock numeric, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  if not stock_key_ok(p_key) then raise exception 'bad key'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'no name'; end if;
  insert into catalog (category, name, unit, sort, stock, stock_updated_at, stock_updated_by)
  values (coalesce(nullif(trim(p_category),''),'INNE'), trim(p_name), coalesce(nullif(trim(p_unit),''),'szt.'),
          (select coalesce(max(sort),0)+1 from catalog where category = coalesce(nullif(trim(p_category),''),'INNE')), p_stock, now(), nullif(trim(p_by),''))
  on conflict (category, name) do update set stock = excluded.stock, stock_updated_at = now(), stock_updated_by = excluded.stock_updated_by, active = true
  returning id into nid;
  return json_build_object('ok', true, 'id', nid);
end $$;

create or replace function stock_snapshot(p_key text, p_note text, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from settings where key = 'stock_key' and value = p_key and value <> '') then
    raise exception 'bad key';
  end if;
  insert into remanenty (note, items)
  select trim(both ' —' from coalesce(nullif(trim(p_note),''),'remanent') || case when nullif(trim(p_by),'') is not null then ' — ' || trim(p_by) else '' end),
         coalesce(jsonb_agg(jsonb_build_object('id', id, 'category', category, 'name', name, 'unit', unit, 'stock', stock)), '[]'::jsonb)
  from catalog where active;
  get diagnostics n = row_count;
  return json_build_object('ok', n > 0);
end $$;

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
      'pack_total', (select count(*) from packing_items p where p.event_id = e.id and (p.qty_num is not null or coalesce(p.qty,'')<>'' or coalesce(p.note,'')<>'')),
      'pack_done',  (select count(*) from packing_items p where p.event_id = e.id and p.packed_at is not null and (p.qty_num is not null or coalesce(p.qty,'')<>'' or coalesce(p.note,'')<>''))
    ) order by e.event_date), '[]'::json)
    from events e where e.status in ('wstepny','potwierdzony') and coalesce(e.event_end_date, e.event_date) >= current_date - 1);
end $$;

create or replace function wh_event(p_mtoken text, p_event uuid)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; e events;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  select * into e from events where id = p_event;
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
        'sort', p.sort, 'packed_at', p.packed_at, 'packed_by', (select first_name from crew where id = p.packed_by)
      ) order by p.category, p.sort, p.created_at), '[]'::json)
      from packing_items p where p.event_id = e.id and (p.qty_num is not null or coalesce(p.qty,'') <> '' or coalesce(p.note,'') <> ''))
  );
end $$;

create or replace function wh_pack(p_mtoken text, p_item uuid, p_packed boolean)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; ev uuid;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  update packing_items set packed_by = case when p_packed then c.id else null end, packed_at = case when p_packed then now() else null end
   where id = p_item returning event_id into ev;
  return wh_event(p_mtoken, ev);
end $$;

-- ===== ZAKUPY (update26) =====
create or replace function shop_get(p_mtoken text, p_week text default null)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; l shop_lists;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  if p_week is not null then
    select * into l from shop_lists where week_key = p_week;
  end if;
  if l.week_key is null then
    select * into l from shop_lists where week_to >= current_date - 1 order by week_from asc limit 1;
  end if;
  if l.week_key is null then
    select * into l from shop_lists order by updated_at desc limit 1;
  end if;
  return json_build_object(
    'first_name', c.first_name,
    'weeks', (select coalesce(json_agg(json_build_object('week_key', week_key, 'week_from', week_from, 'week_to', week_to, 'updated_at', updated_at) order by week_from desc), '[]'::json)
              from shop_lists where week_to >= current_date - 14),
    'list', case when l.week_key is null then null else json_build_object('week_key', l.week_key, 'week_from', l.week_from, 'week_to', l.week_to, 'updated_at', l.updated_at, 'items', l.items) end,
    'checks', (select coalesce(json_object_agg(item_key, json_build_object('at', checked_at, 'by', checked_by)), '{}'::json) from shop_checks where week_key = l.week_key)
  );
end $$;

create or replace function shop_check(p_mtoken text, p_week text, p_item text, p_checked boolean)
returns json language plpgsql security definer set search_path = public as $$
declare c crew;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  if p_checked then
    insert into shop_checks (week_key, item_key, checked_by) values (p_week, p_item, c.first_name)
    on conflict (week_key, item_key) do update set checked_at = now(), checked_by = excluded.checked_by;
  else
    delete from shop_checks where week_key = p_week and item_key = p_item;
  end if;
  return shop_get(p_mtoken, p_week);
end $$;

-- ===== UPRAWNIENIA DO FUNKCJI (strony ekipy wołają je jako anon) =====
grant execute on function crew_get(text), crew_home(text), crew_invite_info(text), crew_join(text,text,text),
  crew_pack(text,uuid,boolean), crew_packing(text), crew_recipes(), crew_register(text,json), crew_respond(text,text,json),
  crew_terms(), shop_check(text,text,text,boolean), shop_get(text,text),
  stock_add(text,text,text,text,numeric,text), stock_key_ok(text), stock_list(text), stock_set(text,uuid,numeric,text),
  stock_set_photo(text,uuid,text), stock_snapshot(text,text,text), touch_updated_at(),
  wh_event(text,uuid), wh_events(text), wh_pack(text,uuid,boolean)
  to anon, authenticated;

-- ===== STORAGE: zdjęcia katalogu (bucket 'catalog', klucz remanentu w nazwie folderu) =====
insert into storage.buckets (id, name, public) values ('web', 'web', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('catalog', 'catalog', true) on conflict (id) do nothing;
drop policy if exists "catalog photos public read" on storage.objects;
create policy "catalog photos public read" on storage.objects for select to anon, authenticated using (bucket_id = 'catalog');
drop policy if exists "catalog photos upload with key" on storage.objects;
create policy "catalog photos upload with key" on storage.objects for insert to anon, authenticated with check (bucket_id = 'catalog' and stock_key_ok((storage.foldername(name))[1]));
drop policy if exists "catalog photos replace with key" on storage.objects;
create policy "catalog photos replace with key" on storage.objects for update to anon, authenticated
  using (bucket_id = 'catalog' and stock_key_ok((storage.foldername(name))[1])) with check (bucket_id = 'catalog' and stock_key_ok((storage.foldername(name))[1]));

notify pgrst, 'reload schema';
