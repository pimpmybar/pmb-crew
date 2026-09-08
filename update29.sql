-- PMB CREW — aktualizacja 29: protokół zdawczo-odbiorczy szkła (etap 2a, część 2)
-- Bezpieczna do wielokrotnego uruchomienia. Wymaga update27 i update28.
-- Sekcje: A ustawienia i tabele · B funkcje protokołu · C dokument publiczny · D szkło w zwrocie z eventu
--
-- Zasada: szkło schodzi ze stanu przy pakowaniu (update28). Protokół „wydanie” to podpis organizatora pod
-- ilością, którą zabrał; protokół „zwrot” liczy straty (wydane − wrócone) i zapisuje je jako ruch magazynowy
-- 'strata'. Powrót idzie jednym ruchem event_powrot na całą wydaną ilość, strata osobnym ruchem ujemnym —
-- dzięki temu stan zgadza się co do sztuki, a raport strat czyta się wprost z ruchów.

-- ===== A. USTAWIENIA I TABELE =====
alter table events add column if not exists glass_price numeric;   -- null = orgs.config.glass_price

-- domyślne ustawienia organizacji (tylko gdy brak klucza — nie nadpisuje ustawień z panelu)
update orgs set config = config || '{"glass_price": 14}'::jsonb where slug = 'pmb' and not (config ? 'glass_price');
update orgs set config = config || '{"glass_categories": ["SZKŁO"]}'::jsonb where slug = 'pmb' and not (config ? 'glass_categories');
-- dane firmy do dokumentu publicznego (adres uzupełnia się w ustawieniach panelu)
update orgs set config = config || '{"company_name": "Pimp My Bar"}'::jsonb where slug = 'pmb' and not (config ? 'company_name');
update orgs set config = config || '{"nip": "8921393139"}'::jsonb where slug = 'pmb' and not (config ? 'nip');
update orgs set config = config || '{"email": "biuro@pimpmybar.pl"}'::jsonb where slug = 'pmb' and not (config ? 'email');
update orgs set config = config || '{"phone": "+48 513 916 977"}'::jsonb where slug = 'pmb' and not (config ? 'phone');
update orgs set config = config || '{"address": ""}'::jsonb where slug = 'pmb' and not (config ? 'address');

-- straty jako rodzaj ruchu magazynowego
alter table stock_moves drop constraint if exists stock_moves_kind_check;
alter table stock_moves add constraint stock_moves_kind_check
  check (kind in ('zakup','event_wydanie','event_powrot','remanent_korekta','korekta_reczna','strata'));

create table if not exists glass_protocols (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) default current_org_id(),
  event_id uuid not null references events(id) on delete cascade,
  kind text not null check (kind in ('wydanie','liczenie','zwrot')),
  price_per_item numeric not null,
  organizer_name text, organizer_phone text,
  signature_data text,                      -- PNG data-URL podpisu (ok. 10–30 KB)
  signed_at timestamptz, crew_name text,
  payment_method text check (payment_method in ('gotowka','faktura')),
  payment_amount numeric, invoice_data jsonb,
  loss_amount numeric,                      -- wyliczone przy 'zwrot'
  settled_at timestamptz, settled_by text,  -- panel: potwierdzenie rozliczenia
  public_token text unique not null default encode(gen_random_bytes(10), 'hex'),
  note text, created_at timestamptz default now()
);
create table if not exists glass_protocol_items (
  protocol_id uuid not null references glass_protocols(id) on delete cascade,
  org_id uuid not null references orgs(id) default current_org_id(),
  catalog_id uuid not null references catalog(id),
  name text not null, qty numeric not null default 0,
  primary key (protocol_id, catalog_id)
);
-- anulowanie protokołu (panel): protokół zostaje w bazie, ale znika z ekranów i zwalnia miejsce na nowy
alter table glass_protocols add column if not exists voided_at timestamptz;
alter table glass_protocols add column if not exists voided_by text;
-- stan zwrotu z eventu sprzed protokołu — z niego odtwarzamy wpis przy anulowaniu
alter table glass_protocol_items add column if not exists prev_returned numeric;
create index if not exists glass_protocols_event_idx on glass_protocols (org_id, event_id, created_at);
-- jeden podpisany 'wydanie' i jeden 'zwrot' na event (funkcja pilnuje tego wcześniej, indeks jest siatką bezpieczeństwa);
-- anulowane nie liczą się do limitu
drop index if exists glass_protocols_signed_uq;
create unique index glass_protocols_signed_uq on glass_protocols (org_id, event_id, kind) where kind in ('wydanie','zwrot') and voided_at is null;
-- 'liczenie' też jest jedno na event (funkcja nadpisuje pozycje w tym samym wierszu)
drop index if exists glass_protocols_liczenie_uq;
create unique index glass_protocols_liczenie_uq on glass_protocols (org_id, event_id) where kind = 'liczenie' and voided_at is null;

alter table glass_protocols enable row level security;
alter table glass_protocol_items enable row level security;
drop policy if exists org_glass_protocols on glass_protocols;
create policy org_glass_protocols on glass_protocols for all to authenticated using (org_id = current_org_id()) with check (org_id = current_org_id());
drop policy if exists org_glass_protocol_items on glass_protocol_items;
create policy org_glass_protocol_items on glass_protocol_items for all to authenticated using (org_id = current_org_id()) with check (org_id = current_org_id());
grant select, update on glass_protocols to authenticated;   -- panel: settled_at, settled_by
grant select on glass_protocol_items to authenticated;

-- ilość wydana na event z ruchów wydania; gdy ruchów nie ma (stara agenda) — z ilości w pakowaniu.
-- Pomocnicza, wołana tylko z funkcji tokenowych (te sprawdzają uprawnienia): bez security definer i bez prawa
-- wykonania dla ról API — inaczej byłaby wystawiona przez PostgREST bez żadnej autoryzacji.
create or replace function glass_packed(p_org uuid, p_event uuid, p_catalog uuid) returns numeric
language sql stable set search_path = public as $$
  select coalesce(
    (select sum(-m.qty) from stock_moves m join packing_items pi on pi.id = m.ref_id and m.ref_type = 'packing_item'
      where pi.event_id = p_event and m.org_id = p_org and m.kind = 'event_wydanie' and m.catalog_id = p_catalog),
    (select sum(pi.qty_num) from packing_items pi
      where pi.event_id = p_event and pi.org_id = p_org and pi.catalog_id = p_catalog),
    0);
$$;
revoke execute on function glass_packed(uuid, uuid, uuid) from public, anon, authenticated;

-- ===== B. FUNKCJE PROTOKOŁU =====
-- ekran protokołu: pozycje szkła z katalogu organizacji, ile pojechało, wszystkie protokoły eventu.
-- signature_data nie wraca (rozmiar) — tylko informacja, że podpis jest.
create or replace function wh_glass_get(p_mtoken text, p_event uuid)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; e events; o orgs; gc jsonb; price numeric;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  select * into e from events where id = p_event and org_id = c.org_id;
  if not found then return null; end if;
  select * into o from orgs where id = c.org_id;
  gc := coalesce(o.config->'glass_categories', '["SZKŁO"]'::jsonb);
  price := coalesce(e.glass_price, (o.config->>'glass_price')::numeric, 14);
  return json_build_object(
    'org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name),
      'company_name', o.config->>'company_name', 'nip', o.config->>'nip', 'address', o.config->>'address',
      'email', o.config->>'email', 'phone', o.config->>'phone'),
    'event', json_build_object('id', e.id, 'name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date,
      'event_end_date', e.event_end_date, 'venue', e.venue, 'glass_price', e.glass_price, 'glass_price_effective', price),
    'items', (
      select coalesce(json_agg(json_build_object(
          'catalog_id', ct.id, 'name', ct.name, 'unit', ct.unit,
          'packed_qty', glass_packed(c.org_id, e.id, ct.id), 'stock', ct.stock
        ) order by ct.name), '[]'::json)
      from catalog ct
      where ct.org_id = c.org_id and ct.active
        and exists (select 1 from jsonb_array_elements_text(gc) g(v) where g.v = ct.category)),
    'protocols', (
      select coalesce(json_agg(json_build_object(
          'id', gp.id, 'kind', gp.kind, 'signed_at', gp.signed_at, 'organizer_name', gp.organizer_name,
          'organizer_phone', gp.organizer_phone, 'crew_name', gp.crew_name, 'price_per_item', gp.price_per_item,
          'loss_amount', gp.loss_amount, 'payment_method', gp.payment_method, 'payment_amount', gp.payment_amount,
          'invoice_data', gp.invoice_data, 'settled_at', gp.settled_at, 'public_token', gp.public_token,
          'note', gp.note, 'created_at', gp.created_at, 'has_signature', gp.signature_data is not null,
          'items', (select coalesce(json_agg(json_build_object('catalog_id', gi.catalog_id, 'name', gi.name, 'qty', gi.qty) order by gi.name), '[]'::json)
            from glass_protocol_items gi where gi.protocol_id = gp.id and gi.org_id = c.org_id)
        ) order by gp.created_at), '[]'::json)
      from glass_protocols gp where gp.event_id = e.id and gp.org_id = c.org_id and gp.voided_at is null)
  );
end $$;

-- zapis protokołu. 'liczenie' — bez podpisu, jeden wiersz na event, pozycje nadpisywane.
-- 'wydanie'/'zwrot' — wymagają nazwiska organizatora i podpisu, tylko raz (anulowane nie blokują).
-- 'zwrot' liczy straty (wydane − wrócone), zapisuje ruchy magazynowe i wpis w zwrocie z eventu.
-- Ilości: nigdy ujemne; w zwrocie nie da się oddać więcej, niż zostało wydane.
create or replace function wh_glass_save(p_mtoken text, p_event uuid, p_kind text, p_items json, p_meta json)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; e events; o orgs; gc jsonb; price numeric; gp glass_protocols; r event_returns;
        it json; cid uuid; q numeric; nm text; tracked boolean; issued numeric; packed numeric; extra numeric;
        loss numeric; losses numeric := 0; prev numeric; move numeric;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  select * into e from events where id = p_event and org_id = c.org_id;
  if not found then raise exception 'not allowed'; end if;
  if p_kind not in ('wydanie','liczenie','zwrot') then raise exception 'bad kind'; end if;
  select * into o from orgs where id = c.org_id;
  gc := coalesce(o.config->'glass_categories', '["SZKŁO"]'::jsonb);
  price := coalesce(e.glass_price, (o.config->>'glass_price')::numeric, 14);

  if p_kind in ('wydanie','zwrot') then
    if coalesce(trim(p_meta->>'organizer_name'), '') = '' or coalesce(p_meta->>'signature_data', '') = '' then
      raise exception 'signature required';
    end if;
    if exists (select 1 from glass_protocols where event_id = p_event and org_id = c.org_id and kind = p_kind and voided_at is null) then
      raise exception 'already signed';
    end if;
  else
    select * into gp from glass_protocols where event_id = p_event and org_id = c.org_id and kind = 'liczenie' and voided_at is null;
  end if;

  if gp.id is null then
    insert into glass_protocols (org_id, event_id, kind, price_per_item, organizer_name, organizer_phone,
      signature_data, signed_at, crew_name, payment_method, payment_amount, invoice_data, note)
    values (c.org_id, p_event, p_kind, price,
      nullif(trim(coalesce(p_meta->>'organizer_name', '')), ''),
      nullif(trim(coalesce(p_meta->>'organizer_phone', '')), ''),
      nullif(coalesce(p_meta->>'signature_data', ''), ''),
      case when p_kind in ('wydanie','zwrot') then now() end,
      case when p_kind in ('wydanie','zwrot') then c.first_name end,
      case when p_kind = 'zwrot' then nullif(coalesce(p_meta->>'payment_method', ''), '') end,
      case when p_kind = 'zwrot' then (p_meta->>'payment_amount')::numeric end,
      case when p_kind = 'zwrot' and p_meta->>'invoice_data' is not null then (p_meta->'invoice_data')::text::jsonb end,
      nullif(trim(coalesce(p_meta->>'note', '')), ''))
    returning * into gp;
  else
    update glass_protocols set price_per_item = price, crew_name = c.first_name,
      note = coalesce(nullif(trim(coalesce(p_meta->>'note', '')), ''), gp.note) where id = gp.id returning * into gp;
    delete from glass_protocol_items where protocol_id = gp.id and org_id = c.org_id;
  end if;

  if p_kind = 'zwrot' then
    select * into r from event_returns where event_id = p_event and org_id = c.org_id;
    if not found then
      insert into event_returns (org_id, event_id) values (c.org_id, p_event) returning * into r;
    end if;
  end if;

  for it in select * from json_array_elements(coalesce(p_items, '[]'::json)) loop
    cid := (it->>'catalog_id')::uuid;
    q := coalesce((it->>'qty')::numeric, 0);
    prev := null;
    select ct.name, ct.stock is not null into nm, tracked from catalog ct
      where ct.id = cid and ct.org_id = c.org_id
        and exists (select 1 from jsonb_array_elements_text(gc) g(v) where g.v = ct.category);
    if nm is null then raise exception 'not allowed'; end if;
    if p_kind <> 'zwrot' then
      if q < 0 then raise exception 'bad qty'; end if;
    else
      -- wydane: z podpisanego (nieanulowanego) protokołu wydania, a gdy go nie ma — z ruchów pakowania
      packed := glass_packed(c.org_id, p_event, cid);
      select gi.qty into issued from glass_protocol_items gi join glass_protocols w on w.id = gi.protocol_id
        where w.event_id = p_event and w.org_id = c.org_id and w.kind = 'wydanie' and w.voided_at is null and gi.catalog_id = cid;
      if issued is null then issued := packed; end if;
      if q < 0 or q > issued then raise exception 'bad qty'; end if;
      -- spakowane, ale nieoddane organizatorowi (wydanie < pakowanie) wracają razem ze zwrotem
      extra := greatest(0, packed - issued);
      loss := greatest(0, issued - q);
      losses := losses + loss;
      -- ile tej pozycji wróciło już przez zwrot z eventu (wh_return_set zrobił wtedy swój ruch) — liczymy różnicę
      select coalesce(ri.returned_qty, 0) into prev from event_return_items ri where ri.return_id = r.id and ri.catalog_id = cid;
      prev := coalesce(prev, 0);
      move := q + extra + loss - prev;
    end if;
    insert into glass_protocol_items (protocol_id, org_id, catalog_id, name, qty, prev_returned) values (gp.id, c.org_id, cid, nm, q, prev)
      on conflict (protocol_id, catalog_id) do update set name = excluded.name, qty = excluded.qty, prev_returned = excluded.prev_returned;

    if p_kind = 'zwrot' then
      if tracked and move <> 0 then
        insert into stock_moves (org_id, catalog_id, qty, kind, ref_type, ref_id, note, created_by)
        values (c.org_id, cid, move, 'event_powrot', 'glass_protocol', gp.id,
          'protokół szkła: wróciło ' || trim(to_char(q + extra, 'FM999999990.##')) || ', straty ' || trim(to_char(loss, 'FM999999990.##')),
          c.first_name);
      end if;
      if tracked and loss > 0 then
        insert into stock_moves (org_id, catalog_id, qty, kind, ref_type, ref_id, note, created_by)
        values (c.org_id, cid, -loss, 'strata', 'glass_protocol', gp.id, 'protokół szkła: straty', c.first_name);
      end if;
      -- ten sam wpis widzi zwrot z eventu i rozliczenie w panelu (bez drugiego ruchu z wh_return_set):
      -- fizycznie wróciło to, co oddał organizator, plus to, co nigdy do niego nie pojechało
      insert into event_return_items (return_id, catalog_id, org_id, returned_qty, opened_qty, note, updated_at, updated_by)
      values (r.id, cid, c.org_id, q + extra, 0, 'protokół szkła', now(), c.first_name)
      on conflict (return_id, catalog_id) do update set returned_qty = excluded.returned_qty, opened_qty = 0,
        note = excluded.note, updated_at = now(), updated_by = excluded.updated_by;
    end if;
  end loop;

  if p_kind = 'zwrot' then
    update glass_protocols set loss_amount = losses * price where id = gp.id;
  end if;
  return wh_glass_get(p_mtoken, p_event);
end $$;
grant execute on function wh_glass_get(text, uuid), wh_glass_save(text, uuid, text, json, json) to anon, authenticated;

-- anulowanie protokołu z panelu (zalogowany właściciel): odwraca ruchy magazynowe protokołu, przywraca wpisy
-- w zwrocie z eventu do stanu sprzed protokołu i zwalnia miejsce na nowy podpis. Protokół zostaje w bazie.
create or replace function glass_protocol_void(p_protocol uuid)
returns json language plpgsql security definer set search_path = public as $$
declare org uuid; gp glass_protocols; r event_returns; m stock_moves; gi glass_protocol_items; who text;
begin
  org := current_org_id();
  if org is null then raise exception 'not allowed'; end if;
  select * into gp from glass_protocols where id = p_protocol and org_id = org;
  -- liczenie jest robocze: nie rusza stanu i nadpisuje się w kółko, więc nie ma czego anulować
  if not found or gp.voided_at is not null or gp.kind = 'liczenie' then raise exception 'not allowed'; end if;
  if gp.kind = 'wydanie' and exists (select 1 from glass_protocols z
      where z.event_id = gp.event_id and z.org_id = org and z.kind = 'zwrot' and z.voided_at is null) then
    raise exception 'void zwrot first';
  end if;
  begin who := nullif(auth.jwt()->>'email', ''); exception when others then who := null; end;
  who := coalesce(who, 'panel');
  for m in select * from stock_moves where org_id = org and ref_type = 'glass_protocol' and ref_id = p_protocol loop
    insert into stock_moves (org_id, catalog_id, qty, kind, ref_type, ref_id, note, created_by)
    values (org, m.catalog_id, -m.qty, m.kind, 'glass_protocol', p_protocol, 'anulowanie protokołu szkła', who);
  end loop;
  -- wpisy w zwrocie z eventu robi tylko protokół zwrotu — wydania nie mają czego przywracać
  if gp.kind = 'zwrot' then
    select * into r from event_returns where event_id = gp.event_id and org_id = org;
    if found then
      for gi in select * from glass_protocol_items where protocol_id = p_protocol and org_id = org loop
        update event_return_items ri set returned_qty = coalesce(gi.prev_returned, ri.returned_qty),
          note = 'anulowany protokół szkła', updated_at = now(), updated_by = who
          where ri.return_id = r.id and ri.catalog_id = gi.catalog_id;
      end loop;
    end if;
  end if;
  update glass_protocols set voided_at = now(), voided_by = who where id = p_protocol;
  return json_build_object('ok', true);
end $$;
revoke execute on function glass_protocol_void(uuid) from public, anon;
grant execute on function glass_protocol_void(uuid) to authenticated;

-- ===== C. DOKUMENT PUBLICZNY =====
-- token dowolnego protokołu eventu otwiera ten sam dokument: obie strony (wydanie i zwrot).
-- To dokument organizatora, więc zawiera jego telefon i podpisy obu stron.
create or replace function glass_protocol_public(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare gp glass_protocols; w glass_protocols; z glass_protocols; e events; o orgs;
begin
  if coalesce(p_token, '') = '' then return null; end if;
  select * into gp from glass_protocols where public_token = p_token and voided_at is null;
  if not found then return null; end if;
  select * into e from events where id = gp.event_id;
  select * into o from orgs where id = gp.org_id;
  select * into w from glass_protocols where event_id = gp.event_id and org_id = gp.org_id and kind = 'wydanie' and voided_at is null;
  select * into z from glass_protocols where event_id = gp.event_id and org_id = gp.org_id and kind = 'zwrot' and voided_at is null;
  return json_build_object(
    'org', json_build_object('brand', coalesce(o.config->>'brand', o.name), 'company_name', o.config->>'company_name',
      'nip', o.config->>'nip', 'address', o.config->>'address', 'email', o.config->>'email', 'phone', o.config->>'phone'),
    'event', json_build_object('name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date,
      'event_end_date', e.event_end_date, 'venue', e.venue),
    'price_per_item', coalesce(z.price_per_item, w.price_per_item, gp.price_per_item),
    'wydanie', case when w.id is null then null else json_build_object(
      'signed_at', w.signed_at, 'organizer_name', w.organizer_name, 'organizer_phone', w.organizer_phone,
      'crew_name', w.crew_name, 'signature_data', w.signature_data,
      'items', (select coalesce(json_agg(json_build_object('name', gi.name, 'qty', gi.qty) order by gi.name), '[]'::json)
        from glass_protocol_items gi where gi.protocol_id = w.id)) end,
    'zwrot', case when z.id is null then null else json_build_object(
      'signed_at', z.signed_at, 'organizer_name', z.organizer_name, 'organizer_phone', z.organizer_phone,
      'crew_name', z.crew_name, 'signature_data', z.signature_data, 'payment_method', z.payment_method,
      'payment_amount', z.payment_amount, 'invoice_data', z.invoice_data, 'loss_amount', z.loss_amount,
      'settled_at', z.settled_at,
      'items', (select coalesce(json_agg(json_build_object(
            'name', gi.name, 'issued', x.issued, 'returned', gi.qty, 'loss', greatest(0, x.issued - gi.qty)
          ) order by gi.name), '[]'::json)
        from glass_protocol_items gi
        cross join lateral (select coalesce(
            (select wi.qty from glass_protocol_items wi where wi.protocol_id = w.id and wi.catalog_id = gi.catalog_id),
            glass_packed(z.org_id, z.event_id, gi.catalog_id)) as issued) x
        where gi.protocol_id = z.id)) end
  );
end $$;
grant execute on function glass_protocol_public(text) to anon, authenticated;

-- ===== D. SZKŁO W ZWROCIE Z EVENTU =====
-- pozycje szkła są rozliczane protokołem — zwrot.html pokazuje je tylko do odczytu (flaga glass)
create or replace function wh_return_get(p_mtoken text, p_event uuid)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; e events; o orgs; r event_returns; cat_order jsonb; gc jsonb;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then return null; end if;
  select * into e from events where id = p_event and org_id = c.org_id;
  if not found then return null; end if;
  select * into o from orgs where id = c.org_id;
  cat_order := coalesce(o.config->'cat_order', '[]'::jsonb);
  gc := coalesce(o.config->'glass_categories', '["SZKŁO"]'::jsonb);
  select * into r from event_returns where event_id = e.id and org_id = c.org_id;
  return json_build_object(
    'org', json_build_object('slug', o.slug, 'brand', coalesce(o.config->>'brand', o.name), 'cat_order', cat_order),
    'event', json_build_object('id', e.id, 'name', coalesce(nullif(e.crew_name,''), e.name), 'event_date', e.event_date, 'event_end_date', e.event_end_date, 'venue', e.venue),
    'return', case when r.id is null then null else json_build_object('status', r.status, 'note', r.note, 'closed_at', r.closed_at, 'closed_by', r.closed_by) end,
    'items', (
      select coalesce(json_agg(json_build_object(
        'catalog_id', p.catalog_id, 'name', ct.name, 'category', ct.category, 'unit', ct.unit,
        'packed_qty', p.packed_qty, 'reserve_qty', coalesce(p.reserve_qty, 0), 'stock', ct.stock, 'perishable', ct.perishable,
        'glass', exists (select 1 from jsonb_array_elements_text(gc) g(v) where g.v = ct.category),
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
      select coalesce(json_agg(json_build_object('catalog_id', ct.id, 'name', ct.name, 'category', ct.category, 'unit', ct.unit, 'stock', ct.stock, 'perishable', ct.perishable,
        'glass', exists (select 1 from jsonb_array_elements_text(gc) g(v) where g.v = ct.category)) order by ct.category, ct.name), '[]'::json)
      from catalog ct where ct.org_id = c.org_id and ct.active and ct.stock is not null
        and not exists (select 1 from stock_moves m join packing_items pi on pi.id = m.ref_id and m.ref_type = 'packing_item' where pi.event_id = e.id and m.catalog_id = ct.id)
    )
  );
end $$;
grant execute on function wh_return_get(text, uuid) to anon, authenticated;

-- szkła nie da się oddać ręcznym zwrotem — jedyną drogą jest protokół (inaczej stan policzyłby powrót dwa razy)
create or replace function wh_return_set(p_mtoken text, p_event uuid, p_catalog uuid, p_returned numeric, p_opened numeric, p_note text)
returns json language plpgsql security definer set search_path = public as $$
declare c crew; r event_returns; prev_ret numeric := 0; prev_open numeric := 0; d numeric;
begin
  select * into c from crew where my_token = p_mtoken and warehouse_access;
  if not found then raise exception 'not allowed'; end if;
  if not exists (select 1 from events where id = p_event and org_id = c.org_id) then raise exception 'not allowed'; end if;
  if not exists (select 1 from catalog where id = p_catalog and org_id = c.org_id) then raise exception 'not allowed'; end if;
  if exists (select 1 from catalog ct join orgs o on o.id = ct.org_id
      where ct.id = p_catalog and ct.org_id = c.org_id
        and exists (select 1 from jsonb_array_elements_text(coalesce(o.config->'glass_categories', '["SZKŁO"]'::jsonb)) g(v) where g.v = ct.category))
  then raise exception 'glass'; end if;
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
grant execute on function wh_return_set(text, uuid, uuid, numeric, numeric, text) to anon, authenticated;

notify pgrst, 'reload schema';
