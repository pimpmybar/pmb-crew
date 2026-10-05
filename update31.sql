-- update31: ukrywanie eventów przed ekipą + magazyn widzi tylko bieżący miesiąc i dwa następne
-- A. events.crew_hidden — event ukryty przed listą magazynową ekipy (właściciel widzi go w panelu normalnie)
-- B. wh_events — pomija ukryte i eventy dalsze niż koniec drugiego miesiąca w przód
-- Cofnięcie: update31_rollback.sql

alter table events add column if not exists crew_hidden boolean not null default false;

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
    from events e where e.org_id = c.org_id and e.status in ('wstepny','potwierdzony') and coalesce(e.event_end_date, e.event_date) >= current_date - 3
      and not e.crew_hidden
      and e.event_date < (date_trunc('month', current_date) + interval '3 months')::date);
end $$;
