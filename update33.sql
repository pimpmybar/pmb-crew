-- update33: remanent zawężony do pozycji z listy pakowania jednego eventu (remanent.html?k=…&ev=<id>)
create or replace function stock_event_ids(p_key text, p_event uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare o uuid := stock_org(p_key); e events;
begin
  if o is null then raise exception 'bad key'; end if;
  select * into e from events where id = p_event and org_id = o;
  if not found then return null; end if;
  return json_build_object(
    'name', coalesce(nullif(e.crew_name, ''), e.name),
    'ids', (select coalesce(json_agg(distinct p.catalog_id), '[]'::json) from packing_items p
             where p.event_id = e.id and p.org_id = o and p.catalog_id is not null));
end $$;
revoke execute on function stock_event_ids(text, uuid) from public;
grant execute on function stock_event_ids(text, uuid) to anon, authenticated;
