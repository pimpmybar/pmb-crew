-- PMB CREW — cofnięcie update29 (protokół szkła) do stanu po update28.
-- Usuwa tabele protokołów, funkcje wh_glass_*, glass_protocol_public i glass_packed, kolumnę events.glass_price,
-- rodzaj ruchu 'strata' oraz klucze dodane do orgs.config: glass_price, glass_categories i dane firmy
-- (company_name, nip, email, phone, address) — te ostatnie trzeba będzie wpisać ponownie.
-- Usuwa też glass_protocol_void (anulowanie protokołu z panelu).
-- Przywraca wh_return_get i wh_return_set z update28 (bez flagi glass i bez blokady szkła w zwrocie).
-- Przerywa, jeśli w bazie są ruchy 'strata' (najpierw trzeba je rozliczyć — inaczej stan przestałby się zgadzać).
-- Bezpieczne do wielokrotnego uruchomienia.
do $$ begin
  if exists (select 1 from stock_moves where kind = 'strata') then
    raise exception 'w bazie są ruchy strata — cofnięcie update29 usunęłoby rodzaj ruchu, na którym stoi stan';
  end if;
end $$;

drop function if exists wh_glass_save(text, uuid, text, json, json);
drop function if exists wh_glass_get(text, uuid);
drop function if exists glass_protocol_public(text);
drop function if exists glass_protocol_void(uuid);
-- kolumny anulowania i indeksy znikają razem z tabelami niżej; ten blok jest dla baz, w których tabele mają zostać
do $$ begin
  if to_regclass('glass_protocols') is not null then
    alter table glass_protocols drop column if exists voided_at, drop column if exists voided_by;
    drop index if exists glass_protocols_liczenie_uq;   -- indeks z update29, w update28 go nie było
    drop index if exists glass_protocols_signed_uq;
    create unique index glass_protocols_signed_uq on glass_protocols (org_id, event_id, kind) where kind in ('wydanie','zwrot');
  end if;
  if to_regclass('glass_protocol_items') is not null then
    alter table glass_protocol_items drop column if exists prev_returned;
  end if;
end $$;
drop table if exists glass_protocol_items;
drop table if exists glass_protocols;
drop function if exists glass_packed(uuid, uuid, uuid);
alter table events drop column if exists glass_price;
alter table stock_moves drop constraint if exists stock_moves_kind_check;
alter table stock_moves add constraint stock_moves_kind_check
  check (kind in ('zakup','event_wydanie','event_powrot','remanent_korekta','korekta_reczna'));
update orgs set config = config - 'glass_price' - 'glass_categories' - 'company_name' - 'nip' - 'email' - 'phone' - 'address' where slug = 'pmb';

-- poprzednia wersja funkcji (z update28)
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

-- wh_return_set z update28 (bez blokady szkła)
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

notify pgrst, 'reload schema';
