-- db/test/test_isolation.sql — organizacja B nie widzi danych organizacji A.
-- Całość w transakcji i ROLLBACK: można uruchomić także w Supabase SQL Editor bez śladu.
begin;
-- Identyfikatory (literalnie, bez \set — plik ma działać także w Supabase SQL Editor):
--   A  = 00000000-0000-0000-0000-000000000001  (PMB)
--   B  = 00000000-0000-0000-0000-0000000000b2  (organizacja testowa)
--   UB = 00000000-0000-0000-0000-0000000000b1  (użytkownik org B)

-- ===== FIXTURES (jako postgres) =====
insert into orgs (id, name, slug) values ('00000000-0000-0000-0000-0000000000b2', 'Org B', 'orgb') on conflict (id) do nothing;
insert into org_members (org_id, user_id, role) values ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b1', 'owner') on conflict do nothing;
-- A
insert into events (org_id, name, event_date, status, invite_code) values ('00000000-0000-0000-0000-000000000001', 'Event A Barcinek', current_date + 4, 'potwierdzony', 'invA');
insert into crew (org_id, phone, first_name, my_token, warehouse_access) values ('00000000-0000-0000-0000-000000000001', '+48100000001', 'Adam', 'tokA', true);
insert into assignments (org_id, event_id, crew_id, token, status)
  select '00000000-0000-0000-0000-000000000001', e.id, c.id, 'asgA', 'zaakceptowany' from events e, crew c where e.invite_code='invA' and c.my_token='tokA';
insert into settings (org_id, key, value) values ('00000000-0000-0000-0000-000000000001', 'stock_key', 'keyA'), ('00000000-0000-0000-0000-000000000001', 'terms', 'TERMS-A') on conflict (org_id, key) do update set value = excluded.value;
insert into catalog (org_id, category, name, unit, stock) values ('00000000-0000-0000-0000-000000000001', 'ALKOHOLE', 'Rum A', 'bt', 7);
insert into recipes (org_id, name, category) values ('00000000-0000-0000-0000-000000000001', 'Drink A', 'KLASYKA');
insert into shop_lists (org_id, week_key, week_from, week_to, items) values ('00000000-0000-0000-0000-000000000001', 'wkA', current_date - 1, current_date + 5, '[{"key":"a1","name":"Rum A","qty":1}]');
insert into packing_items (org_id, event_id, category, name, qty_num, unit) select '00000000-0000-0000-0000-000000000001', id, 'ALKOHOLE', 'Rum A pack', 2, 'bt' from events where invite_code='invA';
-- B
insert into events (org_id, name, event_date, status, invite_code) values ('00000000-0000-0000-0000-0000000000b2', 'Event B', current_date + 9, 'potwierdzony', 'invB');
insert into crew (org_id, phone, first_name, my_token, warehouse_access) values ('00000000-0000-0000-0000-0000000000b2', '+48100000002', 'Bartek', 'tokB', true);
insert into assignments (org_id, event_id, crew_id, token, status)
  select '00000000-0000-0000-0000-0000000000b2', e.id, c.id, 'asgB', 'zaakceptowany' from events e, crew c where e.invite_code='invB' and c.my_token='tokB';
insert into settings (org_id, key, value) values ('00000000-0000-0000-0000-0000000000b2', 'stock_key', 'keyB'), ('00000000-0000-0000-0000-0000000000b2', 'terms', 'TERMS-B');
insert into catalog (org_id, category, name, unit, stock) values ('00000000-0000-0000-0000-0000000000b2', 'ALKOHOLE', 'Gin B', 'bt', 3);
insert into shop_lists (org_id, week_key, week_from, week_to, items) values ('00000000-0000-0000-0000-0000000000b2', 'wkB', current_date + 6, current_date + 12, '[{"key":"b1","name":"Gin B","qty":1}]');

-- ===== 1. RLS: zalogowany użytkownik org B =====
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', true);
set local role authenticated;
select assert_eq(current_org_id(), '00000000-0000-0000-0000-0000000000b2'::uuid, 'current_org_id dla użytkownika B');
select assert_eq((select count(*) from events where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi eventy A');
select assert_eq((select count(*) from crew where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi ekipę A');
select assert_eq((select count(*) from assignments where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi przydziały A');
select assert_eq((select count(*) from packing_items where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi pakowanie A');
select assert_eq((select count(*) from catalog where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi katalog A');
select assert_eq((select count(*) from recipes where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi receptury A');
select assert_eq((select count(*) from settings where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi ustawienia A');
select assert_eq((select count(*) from shop_lists where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi listy zakupów A');
select assert_eq((select count(*) from remanenty where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi remanenty A');
select assert_eq((select count(*) from updates where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi aktualizacje A');
select assert_eq((select count(*) from shop_checks where org_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'RLS: B widzi odhaczenia A');
select assert_eq((select count(*) from orgs), 1::bigint, 'RLS: B widzi tylko swoją organizację');
-- B widzi swoje
select assert_eq((select count(*) from events), 1::bigint, 'RLS: B widzi swój event');
select assert_eq((select count(*) from catalog), 1::bigint, 'RLS: B widzi swój katalog');
-- insert bez org_id dostaje org_id z domyślnej wartości
insert into events (name, event_date, status) values ('Event B2', current_date + 10, 'wstepny');
select assert_eq((select org_id from events where name='Event B2'), '00000000-0000-0000-0000-0000000000b2'::uuid, 'domyślne org_id przy insercie');
-- upsert settings jak w panelu (merge-duplicates po PK org_id,key)
insert into settings (key, value) values ('terms', 'TERMS-B2') on conflict (org_id, key) do update set value = excluded.value;
select assert_eq((select value from settings where key='terms'), 'TERMS-B2', 'upsert settings po (org_id,key)');
reset role;

-- ===== 2. FUNKCJE TOKENOWE =====
-- Funkcje są security definer: wykonują się jako właściciel niezależnie od roli wołającego,
-- więc testujemy je jako postgres (podzapytania po id muszą widzieć wiersze). Jedno wywołanie
-- jako anon sprawdza tylko, że rola ma prawo execute (tak wołają strony ekipy).
set local role anon;
select assert_true(wh_events('tokB') is not null, 'anon może wołać wh_events');
reset role;
-- my_token (magazyn)
select assert_true(wh_events('tokB')::text not like '%Barcinek%', 'wh_events: B widzi event A');
select assert_eq((select count(*) from json_array_elements(wh_events('tokB'))), 2::bigint, 'wh_events: B widzi dokładnie 2 eventy (Event B + Event B2 z sekcji 1)');
select assert_true(wh_event('tokB', (select id from events where invite_code='invA')) is null, 'wh_event: B otwiera event A');
select assert_true(crew_home('tokB')::text not like '%Barcinek%', 'crew_home: B widzi event A');
select assert_true(shop_get('tokB')::text not like '%Rum A%', 'shop_get: B widzi listę A');
select assert_eq(shop_get('tokB')->'list'->>'week_key', 'wkB', 'shop_get: B dostaje swoją listę');
-- assignment token
select assert_true(crew_get('asgB')->'event'->>'name' = 'Event B', 'crew_get: token B daje event B');
select assert_true(crew_packing('asgB')::text not like '%Rum A pack%', 'crew_packing: B widzi pakowanie A');
-- stock key (remanent)
select assert_true(stock_list('keyB')::text not like '%Rum A%', 'stock_list: klucz B widzi katalog A');
select assert_eq((select count(*) from json_array_elements(stock_list('keyB'))), 1::bigint, 'stock_list: klucz B widzi 1 pozycję');
select stock_set('keyB', (select id from catalog where name='Rum A'), 99, 'x');
-- slug organizacji
select assert_eq(crew_terms('orgb')->>'terms', 'TERMS-B2', 'crew_terms: slug B daje warunki B (po upsercie z sekcji 1)');
select assert_eq(crew_terms('pmb')->>'terms', 'TERMS-A', 'crew_terms: slug pmb daje warunki A');
select assert_eq((select count(*) from json_array_elements(crew_recipes('orgb'))), 0::bigint, 'crew_recipes: B nie ma receptur');
select assert_true(crew_recipes('pmb')::text like '%Drink A%', 'crew_recipes: pmb widzi Drink A');
-- zaproszenie i rejestracja tworzą rekordy we właściwej organizacji
select crew_join('invB', '600100200', 'barman');
select crew_register('orgb', '600300400', '{"first_name":"Nowy","accept_terms":"true"}'::json);
select assert_eq((select org_id from crew where phone='+48600100200'), '00000000-0000-0000-0000-0000000000b2'::uuid, 'crew_join: nowa osoba w org B');
select assert_eq((select a.org_id from assignments a join crew c on c.id=a.crew_id where c.phone='+48600100200'), '00000000-0000-0000-0000-0000000000b2'::uuid, 'crew_join: przydział w org B');
select assert_eq((select org_id from crew where phone='+48600300400'), '00000000-0000-0000-0000-0000000000b2'::uuid, 'crew_register: rekrutacja w org B');
select assert_eq((select stock from catalog where name='Rum A'), 7::numeric, 'stock_set: klucz B nie zmienia stanu A');
-- ten sam numer telefonu może istnieć w dwóch organizacjach
insert into crew (org_id, phone, first_name) values ('00000000-0000-0000-0000-000000000001', '+48600100200', 'Ten sam numer w A');
select assert_eq((select count(*) from crew where phone='+48600100200'), 2::bigint, 'unikalność telefonu per organizacja');

rollback;
