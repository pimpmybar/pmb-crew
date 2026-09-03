-- PMB CREW — cofnięcie update28 (etap 2a: ruchy magazynowe i zwrot z eventu) do stanu po update27.
-- Usuwa stock_moves, event_returns, triggery i widok; przywraca poprzednie stock_set/stock_add/wh_events.
-- catalog.stock zostaje z aktualnymi wartościami (ruchy już go zaktualizowały) — dane nie giną.
-- Bezpieczne do wielokrotnego uruchomienia.
drop trigger if exists packing_items_issue on packing_items;
drop trigger if exists catalog_stock_audit on catalog;
drop trigger if exists stock_moves_apply on stock_moves;
drop function if exists packing_items_issue();
drop function if exists catalog_stock_audit();
drop function if exists stock_moves_apply();
drop view if exists event_usage;
drop function if exists wh_return_get(text, uuid);
drop function if exists wh_return_set(text, uuid, uuid, numeric, numeric, text, boolean);
drop function if exists wh_return_close(text, uuid, text);
drop function if exists wh_reserve_add(text, uuid, uuid, numeric);
drop function if exists wh_reserve_remove(text, uuid, uuid);
drop table if exists event_return_items;
drop table if exists event_returns;
drop table if exists stock_moves;
alter table catalog drop column if exists perishable;
alter table packing_items drop column if exists reserve;
alter table catalog drop column if exists opened_qty;

-- poprzednie wersje funkcji (z update27)
create or replace function stock_set(p_key text, p_id uuid, p_stock numeric, p_by text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid := stock_org(p_key);
begin
  if o is null then raise exception 'bad key'; end if;
  update catalog set stock = p_stock, stock_updated_at = now(), stock_updated_by = nullif(trim(p_by), '') where id = p_id and org_id = o;
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

notify pgrst, 'reload schema';
