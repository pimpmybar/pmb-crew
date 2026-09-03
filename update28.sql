-- PMB CREW — aktualizacja 28: ruchy magazynowe i zwrot z eventu (etap 2a)
-- Bezpieczna do wielokrotnego uruchomienia. Wymaga update27.
-- Sekcje: A ruchy i stan · B wydanie przy pakowaniu · C remanent przez ruchy · D zwrot z eventu · E widok dla panelu
--
-- Zasada (spec Z3, D5): catalog.stock zostaje jako pole, ale jest liczone z ruchów. Każda zmiana stanu to wiersz
-- w stock_moves: wydanie przy pakowaniu (ujemne), powrót przy zwrocie (dodatnie), korekta z remanentu,
-- ręczna zmiana w panelu. Panel i remanent działają bez przepisywania.

-- ===== A. RUCHY MAGAZYNOWE =====
alter table catalog add column if not exists perishable boolean not null default false; -- napoczęte nie wracają (puree, pulpy): ekipa wylewa na miejscu
alter table catalog add column if not exists opened_qty numeric not null default 0;  -- napoczęte opakowania (poza stanem)
update catalog set perishable = true where not perishable and (name ilike '%puree%' or name ilike '%purée%' or name ilike '%pulpa%');

create table if not exists stock_moves (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) default current_org_id(),
  catalog_id uuid not null references catalog(id) on delete cascade,
  qty numeric not null,                 -- ze znakiem: wydanie ujemne, powrót/zakup dodatnie
  kind text not null check (kind in ('zakup','event_wydanie','event_powrot','remanent_korekta','korekta_reczna')),
  ref_type text,                        -- 'packing_item' | 'return' | 'purchase' | null
  ref_id uuid,
  note text,
  created_by text,
  created_at timestamptz default now()
);
create index if not exists stock_moves_org_cat_idx on stock_moves (org_id, catalog_id, created_at desc);
create index if not exists stock_moves_ref_idx on stock_moves (ref_type, ref_id);
alter table stock_moves enable row level security;
drop policy if exists org_stock_moves on stock_moves;
create policy org_stock_moves on stock_moves for all to authenticated using (org_id = current_org_id()) with check (org_id = current_org_id());
grant select, insert on stock_moves to authenticated;

-- ruch → stan. Flaga pmb.from_audit: ruch zapisany przez audyt ręcznej zmiany — stan ustawia już sam UPDATE, nie dodajemy drugi raz.
create or replace function stock_moves_apply() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('pmb.from_audit', true), '') = '1' then return new; end if;
  perform set_config('pmb.from_move', '1', true);
  update catalog set stock = coalesce(stock, 0) + new.qty, stock_updated_at = now(),
    stock_updated_by = coalesce(new.created_by, stock_updated_by)
    where id = new.catalog_id and org_id = new.org_id;
  perform set_config('pmb.from_move', '', true);
  return new;
end $$;
drop trigger if exists stock_moves_apply on stock_moves;
create trigger stock_moves_apply after insert on stock_moves for each row execute function stock_moves_apply();

-- ręczna zmiana stanu (panel: PATCH catalog.stock) → ruch korekta_reczna. Tylko gdy obie strony niepuste:
-- null → liczba = start śledzenia, liczba → null = koniec śledzenia; bez ruchu.
create or replace function catalog_stock_audit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('pmb.from_move', true), '') = '1' then return new; end if;
  if old.stock is not null and new.stock is not null and new.stock <> old.stock then
    perform set_config('pmb.from_audit', '1', true);
    insert into stock_moves (org_id, catalog_id, qty, kind, note, created_by)
    values (new.org_id, new.id, new.stock - old.stock, 'korekta_reczna', 'zmiana w panelu', new.stock_updated_by);
    perform set_config('pmb.from_audit', '', true);
  end if;
  return new;
end $$;
drop trigger if exists catalog_stock_audit on catalog;
create trigger catalog_stock_audit before update of stock on catalog for each row execute function catalog_stock_audit();

-- zapas: pozycje brane poza agendą (te same składniki); wracają przez zwrot jak reszta
alter table packing_items add column if not exists reserve boolean not null default false;

-- ===== B. WYDANIE PRZY PAKOWANIU =====
-- odhaczenie pozycji (packed_at null → data) zdejmuje qty_num ze stanu; odznaczenie oddaje. Tylko pozycje
-- podpięte do katalogu, z ilością liczbową i katalogiem ze stanem (stock not null).
create or replace function packing_items_issue() returns trigger language plpgsql security definer set search_path = public as $$
declare tracked boolean; who text;
begin
  if new.catalog_id is null or new.qty_num is null then return new; end if;
  select stock is not null into tracked from catalog where id = new.catalog_id and org_id = new.org_id;
  if not coalesce(tracked, false) then return new; end if;
  select first_name into who from crew where id = coalesce(new.packed_by, old.packed_by) and org_id = new.org_id;
  if old.packed_at is null and new.packed_at is not null then
    insert into stock_moves (org_id, catalog_id, qty, kind, ref_type, ref_id, created_by)
    values (new.org_id, new.catalog_id, -new.qty_num, 'event_wydanie', 'packing_item', new.id, who);
  elsif old.packed_at is not null and new.packed_at is null then
    insert into stock_moves (org_id, catalog_id, qty, kind, ref_type, ref_id, note, created_by)
    values (new.org_id, new.catalog_id, new.qty_num, 'event_wydanie', 'packing_item', new.id, 'cofnięcie pakowania', who);
  end if;
  return new;
end $$;
drop trigger if exists packing_items_issue on packing_items;
create trigger packing_items_issue after update of packed_at on packing_items for each row execute function packing_items_issue();

-- ===== B2. ZAPAS (poza agendą) =====
-- dodanie pozycji spoza agendy — od razu jako spakowana (wydanie ze stanu przez trigger) — i usunięcie
create or replace function wh_reserve_add(p_mtoken text, p_event uuid, p_catalog uuid, p_qty numeric)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; ct catalog; ex packing_items;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  if not exists (select 1 from events where id = p_event and org_id = c.org_id) then raise exception 'not allowed'; end if;
  select * into ct from catalog where id = p_catalog and org_id = c.org_id;
  if not found then raise exception 'not allowed'; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'bad qty'; end if;
  select * into ex from packing_items where event_id = p_event and catalog_id = p_catalog and reserve and org_id = c.org_id;
  if found then
    -- zmiana ilości zapasu: cofnij wydanie, ustaw nową ilość, wydaj ponownie (trigger liczy ruchy)
    update packing_items set packed_at = null, packed_by = null where id = ex.id;
    update packing_items set qty_num = p_qty where id = ex.id;
    update packing_items set packed_at = now(), packed_by = c.id where id = ex.id;
  else
    insert into packing_items (org_id, event_id, catalog_id, category, name, unit, qty_num, sort, reserve, note)
    values (c.org_id, p_event, ct.id, ct.category, ct.name, ct.unit, p_qty, 9000 + coalesce(ct.sort, 0), true, 'ZAPAS')
    returning * into ex;
    update packing_items set packed_at = now(), packed_by = c.id where id = ex.id;
  end if;
  return wh_event(p_mtoken, p_event);
end $$;

create or replace function wh_reserve_remove(p_mtoken text, p_event uuid, p_catalog uuid)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; ex packing_items;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  select * into ex from packing_items where event_id = p_event and catalog_id = p_catalog and reserve and org_id = c.org_id;
  if found then
    update packing_items set packed_at = null, packed_by = null where id = ex.id;   -- cofa wydanie ze stanu
    delete from packing_items where id = ex.id;
  end if;
  return wh_event(p_mtoken, p_event);
end $$;
grant execute on function wh_reserve_add(text, uuid, uuid, numeric), wh_reserve_remove(text, uuid, uuid) to anon, authenticated;

-- wh_event: pozycje pakowania z flagą zapasu + katalog ze stanem do wyboru zapasu (sygnatura bez zmian)
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
        'id', p.id, 'category', p.category, 'name', p.name, 'catalog_id', p.catalog_id, 'reserve', p.reserve, 'qty_num', p.qty_num,
        'qty', coalesce(p.qty, case when p.qty_num is not null then trim(to_char(p.qty_num,'FM999999990.##')) || ' ' || coalesce(p.unit,'') else '' end) || case when p.note is not null and p.note <> '' and not p.reserve then ' · ' || p.note else '' end,
        'sort', p.sort, 'packed_at', p.packed_at, 'packed_by', (select first_name from crew where id = p.packed_by and org_id = c.org_id)
      ) order by p.category, p.sort, p.created_at), '[]'::json)
      from packing_items p where p.event_id = e.id and p.org_id = c.org_id and (p.qty_num is not null or coalesce(p.qty,'') <> '' or coalesce(p.note,'') <> '')),
    'catalog', (select coalesce(json_agg(json_build_object('id', ct.id, 'name', ct.name, 'category', ct.category, 'unit', ct.unit, 'stock', ct.stock) order by ct.category, ct.sort, ct.name), '[]'::json)
      from catalog ct where ct.org_id = c.org_id and ct.active and ct.stock is not null)
  );
end $$;

-- ===== C. REMANENT PRZEZ RUCHY =====
create or replace function stock_set(p_key text, p_id uuid, p_stock numeric, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key); cur numeric; who text := nullif(trim(p_by), '');
begin
  if o is null then raise exception 'bad key'; end if;
  select stock into cur from catalog where id = p_id and org_id = o;
  if not found then raise exception 'not found'; end if;
  if p_stock is null or cur is null then
    -- start/koniec śledzenia: bez ruchu
    perform set_config('pmb.from_move', '1', true);
    update catalog set stock = p_stock, stock_updated_at = now(), stock_updated_by = who where id = p_id and org_id = o;
    perform set_config('pmb.from_move', '', true);
  elsif p_stock <> cur then
    insert into stock_moves (org_id, catalog_id, qty, kind, note, created_by) values (o, p_id, p_stock - cur, 'remanent_korekta', 'remanent', who);
  else
    update catalog set stock_updated_at = now(), stock_updated_by = who where id = p_id and org_id = o;
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function stock_add(p_key text, p_category text, p_name text, p_unit text, p_stock numeric, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key); nid uuid; cur numeric; cat text := coalesce(nullif(trim(p_category),''),'INNE'); who text := nullif(trim(p_by),'');
begin
  if o is null then raise exception 'bad key'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'no name'; end if;
  select id, stock into nid, cur from catalog where org_id = o and category = cat and name = trim(p_name);
  if nid is null then
    insert into catalog (org_id, category, name, unit, sort, stock_updated_at, stock_updated_by)
    values (o, cat, trim(p_name), coalesce(nullif(trim(p_unit),''),'szt.'),
            (select coalesce(max(sort),0)+1 from catalog where org_id = o and category = cat), now(), who)
    returning id into nid;
  else
    update catalog set active = true, stock_updated_at = now(), stock_updated_by = who where id = nid;
  end if;
  if p_stock is not null and (cur is null or cur <> p_stock) then
    insert into stock_moves (org_id, catalog_id, qty, kind, note, created_by)
    values (o, nid, p_stock - coalesce(cur, 0), 'remanent_korekta', case when cur is null then 'nowa pozycja w remanencie' else 'remanent' end, who);
  end if;
  return json_build_object('ok', true, 'id', nid);
end $$;

-- ===== D. ZWROT Z EVENTU =====
create table if not exists event_returns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) default current_org_id(),
  event_id uuid not null references events(id) on delete cascade,
  status text not null default 'w_toku' check (status in ('w_toku','zamkniety')),
  note text, closed_at timestamptz, closed_by text, created_at timestamptz default now(),
  unique (org_id, event_id)
);
create table if not exists event_return_items (
  return_id uuid not null references event_returns(id) on delete cascade,
  catalog_id uuid not null references catalog(id) on delete cascade,
  org_id uuid not null references orgs(id) default current_org_id(),
  returned_qty numeric not null default 0,   -- całe sztuki, które wróciły na stan
  opened_qty numeric not null default 0,     -- napoczęte (poza stanem)
  note text, updated_at timestamptz default now(), updated_by text,
  primary key (return_id, catalog_id)
);
alter table event_returns enable row level security;
alter table event_return_items enable row level security;
drop policy if exists org_event_returns on event_returns;
create policy org_event_returns on event_returns for all to authenticated using (org_id = current_org_id()) with check (org_id = current_org_id());
drop policy if exists org_event_return_items on event_return_items;
create policy org_event_return_items on event_return_items for all to authenticated using (org_id = current_org_id()) with check (org_id = current_org_id());
grant select, update on event_returns to authenticated;
grant select on event_return_items to authenticated;

-- ekran zwrotu: co pojechało (z ruchów wydania), co już wpisano, podpowiedź dla produktów psujących się
create or replace function wh_return_get(p_mtoken text, p_event uuid)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; e events; o orgs; r event_returns; cat_order jsonb;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  select * into e from events where id = p_event and org_id = c.org_id;
  if not found then return null; end if;
  select * into o from orgs where id = c.org_id;
  cat_order := coalesce(o.config->'cat_order', '[]'::jsonb);
  select * into r from event_returns where event_id = e.id and org_id = c.org_id;
  return json_build_object(
    'org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name), 'cat_order', cat_order),
    'event', json_build_object('id', e.id, 'name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date, 'event_end_date', e.event_end_date, 'venue', e.venue),
    'return', case when r.id is null then null else json_build_object('status', r.status, 'note', r.note, 'closed_at', r.closed_at, 'closed_by', r.closed_by) end,
    'items', (
      select coalesce(json_agg(json_build_object(
        'catalog_id', p.catalog_id, 'name', ct.name, 'category', ct.category, 'unit', ct.unit,
        'packed_qty', p.packed_qty, 'reserve_qty', coalesce(p.reserve_qty, 0), 'stock', ct.stock, 'perishable', ct.perishable,
        'returned_qty', ri.returned_qty, 'opened_qty', ri.opened_qty, 'note', ri.note, 'counted', ri.catalog_id is not null
      ) order by (select coalesce(idx - 1, 999) from jsonb_array_elements_text(cat_order) with ordinality t(v, idx) where v = ct.category), ct.category, ct.name), '[]'::json)
      from (
        select m.catalog_id, sum(-m.qty) as packed_qty, sum(-m.qty) filter (where pi.reserve) as reserve_qty
        from stock_moves m join packing_items pi on pi.id = m.ref_id and m.ref_type = 'packing_item'
        where pi.event_id = e.id and m.org_id = c.org_id and m.kind = 'event_wydanie'
        group by m.catalog_id having sum(-m.qty) > 0
      ) p
      join catalog ct on ct.id = p.catalog_id
      left join event_return_items ri on ri.return_id = r.id and ri.catalog_id = p.catalog_id
    ),
    'extras', (
      select coalesce(json_agg(json_build_object('catalog_id', ct.id, 'name', ct.name, 'category', ct.category, 'unit', ct.unit, 'stock', ct.stock, 'perishable', ct.perishable) order by ct.category, ct.name), '[]'::json)
      from catalog ct where ct.org_id = c.org_id and ct.active and ct.stock is not null
        and not exists (select 1 from stock_moves m join packing_items pi on pi.id = m.ref_id and m.ref_type = 'packing_item' where pi.event_id = e.id and m.catalog_id = ct.id)
    )
  );
end $$;

-- wpis zwrotu jednej pozycji: delta całych sztuk → ruch event_powrot; napoczęte → catalog.opened_qty
create or replace function wh_return_set(p_mtoken text, p_event uuid, p_catalog uuid, p_returned numeric, p_opened numeric, p_note text)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; r event_returns; prev_ret numeric := 0; prev_open numeric := 0; d numeric;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  if not exists (select 1 from events where id = p_event and org_id = c.org_id) then raise exception 'not allowed'; end if;
  if not exists (select 1 from catalog where id = p_catalog and org_id = c.org_id) then raise exception 'not allowed'; end if;
  select * into r from event_returns where event_id = p_event and org_id = c.org_id;
  if not found then
    insert into event_returns (org_id, event_id) values (c.org_id, p_event) returning * into r;
  end if;
  if r.status = 'zamkniety' then raise exception 'closed'; end if;
  select returned_qty, opened_qty into prev_ret, prev_open from event_return_items where return_id = r.id and catalog_id = p_catalog;
  prev_ret := coalesce(prev_ret, 0); prev_open := coalesce(prev_open, 0);
  insert into event_return_items (return_id, catalog_id, org_id, returned_qty, opened_qty, note, updated_at, updated_by)
  values (r.id, p_catalog, c.org_id, coalesce(p_returned, 0), coalesce(p_opened, 0), nullif(trim(p_note), ''), now(), c.first_name)
  on conflict (return_id, catalog_id) do update set returned_qty = excluded.returned_qty, opened_qty = excluded.opened_qty, note = excluded.note, updated_at = now(), updated_by = excluded.updated_by;
  d := coalesce(p_returned, 0) - prev_ret;
  if d <> 0 then
    insert into stock_moves (org_id, catalog_id, qty, kind, ref_type, ref_id, note, created_by)
    values (c.org_id, p_catalog, d, 'event_powrot', 'return', r.id, case when d < 0 then 'poprawka zwrotu' else null end, c.first_name);
  end if;
  if coalesce(p_opened, 0) <> prev_open then
    update catalog set opened_qty = greatest(0, opened_qty - prev_open + coalesce(p_opened, 0)) where id = p_catalog and org_id = c.org_id;
  end if;
  return wh_return_get(p_mtoken, p_event);
end $$;

create or replace function wh_return_close(p_mtoken text, p_event uuid, p_note text)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; r event_returns;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  if not exists (select 1 from events where id = p_event and org_id = c.org_id) then raise exception 'not allowed'; end if;
  select * into r from event_returns where event_id = p_event and org_id = c.org_id;
  if not found then
    insert into event_returns (org_id, event_id) values (c.org_id, p_event) returning * into r;
  end if;
  update event_returns set status = 'zamkniety', closed_at = now(), closed_by = c.first_name, note = coalesce(nullif(trim(p_note), ''), note) where id = r.id;
  return wh_return_get(p_mtoken, p_event);
end $$;

grant execute on function wh_return_get(text, uuid), wh_return_set(text, uuid, uuid, numeric, numeric, text), wh_return_close(text, uuid, text) to anon, authenticated;

-- wh_events: status zwrotu przy każdym evencie (do plakietki „do rozliczenia”); sygnatura bez zmian
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
      'pack_done',  (select count(*) from packing_items p where p.event_id = e.id and p.org_id = c.org_id and p.packed_at is not null and (p.qty_num is not null or coalesce(p.qty,'')<>'' or coalesce(p.note,'')<>'')),
      'return_status', (select r.status from event_returns r where r.event_id = e.id and r.org_id = c.org_id)
    ) order by e.event_date), '[]'::json)
    from events e where e.org_id = c.org_id and e.status in ('wstepny','potwierdzony') and coalesce(e.event_end_date, e.event_date) >= current_date - 3);
end $$;

-- ===== E. WIDOK DLA PANELU: zużycie na evencie = wydane − zwrócone =====
create or replace view event_usage with (security_invoker = true) as
select m.org_id, pi.event_id, c.id as catalog_id, c.name, c.category, c.unit,
       sum(-m.qty) as issued,
       coalesce(sum(-m.qty) filter (where pi.reserve), 0) as reserve,
       coalesce(r.returned_qty, 0) as returned,
       coalesce(r.opened_qty, 0) as opened,
       sum(-m.qty) - coalesce(r.returned_qty, 0) as used
from stock_moves m
join packing_items pi on pi.id = m.ref_id and m.ref_type = 'packing_item'
join catalog c on c.id = m.catalog_id
left join event_returns er on er.event_id = pi.event_id and er.org_id = m.org_id
left join event_return_items r on r.return_id = er.id and r.catalog_id = c.id
where m.kind = 'event_wydanie'
group by m.org_id, pi.event_id, c.id, c.name, c.category, c.unit, r.returned_qty, r.opened_qty
having sum(-m.qty) > 0;
grant select on event_usage to authenticated;

notify pgrst, 'reload schema';
