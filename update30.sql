-- PMB CREW — aktualizacja 30: eventy z formularza „Dane do umowy" (import z arkusza Google)
-- Bezpieczna do wielokrotnego uruchomienia. Wymaga update27 (organizacje).
-- Sekcje: A kolumny i klucz importu · B pomocnicze czytanie wiersza · C event_intake
--
-- Zasada: Google Apps Script wysyła wiersz formularza (nagłówek → wartość) do event_intake razem z kluczem
-- organizacji z settings.intake_key. Funkcja rozpoznaje wiersz po sygnaturze czasowej i adresie e-mail
-- (events.intake_id, indeks unikalny), więc ponowne wysłanie tego samego wiersza nie tworzy drugiego eventu.
-- Nowy event powstaje ze statusem 'wstepny' — właściciel widzi go w panelu z plakietką „z formularza"
-- i potwierdza. Jeśli event był już wpisany ręcznie (ten sam klient i ta sama data), wiersz tylko się do niego
-- podpina: uzupełnia sygnaturę, link do umowy i e-mail, a reszty pól nie rusza.

-- ===== A. KOLUMNY I KLUCZ IMPORTU =====
alter table events add column if not exists intake_id text;           -- '<sygnatura czasowa>|<e-mail>' z formularza
alter table events add column if not exists intake_at timestamptz;    -- kiedy wiersz trafił do bazy
alter table events add column if not exists client_email text;        -- adres z formularza (do korespondencji)
create unique index if not exists events_intake_uq on events (org_id, intake_id) where intake_id is not null;

-- klucz importu per organizacja (jak stock_key); nie nadpisuje istniejącego
insert into settings (org_id, key, value)
  select o.id, 'intake_key', encode(gen_random_bytes(12), 'hex') from orgs o
  where not exists (select 1 from settings s where s.org_id = o.id and s.key = 'intake_key');

-- organizacja po kluczu importu (jak stock_org, ale klucz nie jest publiczny — nie dajemy go anonowi)
create or replace function intake_org(p_key text) returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from settings where key = 'intake_key' and value = p_key and coalesce(p_key, '') <> '' limit 1
$$;
revoke execute on function intake_org(text) from public, anon, authenticated;

-- ===== B. POMOCNICZE CZYTANIE WIERSZA =====
-- Nagłówki w zakładkach arkusza różnią się drobiazgami (spacja na końcu, wielkość liter, dopiski w nawiasie),
-- dlatego szukamy po początku nagłówka, bez względu na wielkość liter, i bierzemy pierwszą niepustą wartość.
create or replace function intake_text(p_row json, p_header text) returns text
language sql immutable as $$
  select v from (
    select btrim(coalesce(e.value, '')) as v,
           case when lower(btrim(e.key)) = lower(btrim(p_header)) then 0 else 1 end as pref
    from json_each_text(p_row) e
    where lower(btrim(e.key)) like lower(btrim(p_header)) || '%'
  ) x where v <> '' order by pref limit 1
$$;
revoke execute on function intake_text(json, text) from public, anon, authenticated;

-- data z formularza: 'YYYY-MM-DD', 'DD.MM.YYYY' albo 'DD/MM/YYYY'; cokolwiek innego = null
create or replace function intake_date(p text) returns date
language plpgsql immutable as $$
declare s text := btrim(coalesce(p, ''));
begin
  if s = '' then return null; end if;
  if s ~ '^\d{4}-\d{2}-\d{2}' then return substring(s from 1 for 10)::date; end if;
  if s ~ '^\d{1,2}[./]\d{1,2}[./]\d{4}' then
    return to_date(regexp_replace(substring(s from '^\d{1,2}[./]\d{1,2}[./]\d{4}'), '[./]', '.', 'g'), 'DD.MM.YYYY');
  end if;
  return null;
exception when others then return null;
end $$;
revoke execute on function intake_date(text) from public, anon, authenticated;

-- godzina jako 'HH:MM' — bez sekund i bez daty, którą arkusz dokleja do komórek czasu (1899-12-30 16:00:00)
create or replace function intake_time(p text) returns text
language plpgsql immutable as $$
declare s text := btrim(coalesce(p, '')); m text[];
begin
  if s = '' then return null; end if;
  s := regexp_replace(s, '^\d{4}-\d{2}-\d{2}[T ]', '');
  m := regexp_match(s, '(\d{1,2}):(\d{2})');
  if m is null then return null; end if;
  return lpad(m[1], 2, '0') || ':' || m[2];
end $$;
revoke execute on function intake_time(text) from public, anon, authenticated;

-- liczba z pola tekstowego („100", „100 osób"); brak cyfr = null
create or replace function intake_int(p text) returns integer
language sql immutable as $$
  select case when coalesce(p, '') ~ '\d' then (substring(p from '\d{1,7}'))::integer end
$$;
revoke execute on function intake_int(text) from public, anon, authenticated;

-- ===== C. PRZYJĘCIE WIERSZA =====
create or replace function event_intake(p_key text, p_row json)
returns json language plpgsql security definer set search_path = public as $$
declare
  o uuid := intake_org(p_key);
  sig text; mail text; iid text; ev events; nid uuid;
  v_client text; v_service text; v_name text; v_url text; v_phone text;
  v_date date; v_end date; v_pav text; v_sto text; v_venue text; v_addr text; v_first text;
begin
  if o is null then raise exception 'not allowed'; end if;
  sig := intake_text(p_row, 'Sygnatura czasowa');
  if sig is null then raise exception 'no timestamp'; end if;
  mail := intake_text(p_row, 'Adres e-mail');
  iid := sig || '|' || coalesce(mail, '');

  v_client  := intake_text(p_row, 'NAZWA PODMIOTU');
  v_service := intake_text(p_row, 'Rodzaj usługi');
  v_url     := intake_text(p_row, 'Link do dokumentu');
  v_date    := intake_date(intake_text(p_row, 'Data rozpoczęcia usługi'));
  if v_date is null then raise exception 'bad date'; end if;
  v_end := intake_date(intake_text(p_row, 'Data zakończenia usługi'));
  if v_end = v_date then v_end := null; end if;

  v_pav := intake_text(p_row, 'Nr. pawilonu');  if lower(coalesce(v_pav, '')) = 'brak' then v_pav := null; end if;
  v_sto := intake_text(p_row, 'Nr. stoiska');   if lower(coalesce(v_sto, '')) = 'brak' then v_sto := null; end if;
  v_venue := nullif(array_to_string(array_remove(array[
      intake_text(p_row, 'Nazwa lokalu'), intake_text(p_row, 'Nr. lokalu'), v_pav, v_sto], null), ', '), '');
  v_addr := nullif(array_to_string(array_remove(array[
      intake_text(p_row, 'Ulica, numer'),
      intake_text(p_row, 'Kod pocztowy miejsca wykonania usługi'),
      intake_text(p_row, 'Miasto wykonania usługi')], null), ', '), '');
  -- telefon bywa opisany słownie („numer 572 571 205,") — zostawiamy cyfry, spacje i plus
  v_phone := nullif(btrim(regexp_replace(regexp_replace(
      coalesce(intake_text(p_row, 'Nr kontaktowy do Państwa'), ''), '[^0-9+ ]', '', 'g'), '\s+', ' ', 'g')), '');
  v_name := left(coalesce(nullif(v_client, ''), 'Zapytanie z formularza')
            || case when coalesce(v_service, '') <> '' then ' — ' || lower(v_service) else '' end, 120);

  -- 1. ten sam wiersz już był
  select * into ev from events where org_id = o and intake_id = iid limit 1;
  if found then
    if coalesce(v_url, '') <> '' and coalesce(ev.contract_url, '') = '' then
      update events set contract_url = v_url, updated_at = now() where id = ev.id;
    end if;
    return json_build_object('ok', true, 'action', 'exists', 'id', ev.id);
  end if;

  -- 2. event wpisany wcześniej ręcznie: ten sam dzień i ten sam klient (albo jego nazwa w nazwie eventu)
  v_first := replace(replace(split_part(coalesce(v_client, ''), ' ', 1), '%', ''), '_', '');
  if coalesce(v_client, '') <> '' then
    select * into ev from events
     where org_id = o and intake_id is null and event_date = v_date
       and (lower(coalesce(client, '')) = lower(v_client)
            or (v_first <> '' and name ilike '%' || v_first || '%'))
     order by created_at limit 1;
    if found then
      update events set
        intake_id = iid, intake_at = now(),
        contract_url = case when coalesce(contract_url, '') = '' then coalesce(v_url, contract_url) else contract_url end,
        client_email = case when coalesce(client_email, '') = '' then coalesce(mail, client_email) else client_email end,
        updated_at = now()
      where id = ev.id;
      return json_build_object('ok', true, 'action', 'linked', 'id', ev.id);
    end if;
  end if;

  -- 3. nowy event do potwierdzenia
  begin
    insert into events (org_id, name, client, client_email, status, event_date, event_end_date, start_time, end_time,
      venue, address, guests, bartenders_needed, service_type, modules, contact_name, contact_phone, organizer_phone,
      menu, contract_url, intake_id, intake_at)
    values (o, v_name, v_client, mail, 'wstepny', v_date, v_end,
      intake_time(intake_text(p_row, 'Godzina rozpoczęcia usługi')),
      intake_time(intake_text(p_row, 'Godzina zakończenia usługi')),
      v_venue, v_addr,
      intake_int(intake_text(p_row, 'Liczba gości')),
      coalesce(intake_int(intake_text(p_row, 'Ilość barmanów/baristów')), 0),
      v_service, intake_text(p_row, 'Ilość modułów'),
      intake_text(p_row, 'Osoba reprezentująca firmę'), v_phone, v_phone,
      intake_text(p_row, 'Proszę o wklejenie wszelkich ustaleń'), v_url, iid, now())
    returning id into nid;
  exception when unique_violation then   -- dwa równoczesne wysłania tego samego wiersza
    select id into nid from events where org_id = o and intake_id = iid;
    return json_build_object('ok', true, 'action', 'exists', 'id', nid);
  end;
  return json_build_object('ok', true, 'action', 'created', 'id', nid);
end $$;
grant execute on function event_intake(text, json) to anon, authenticated;

notify pgrst, 'reload schema';
