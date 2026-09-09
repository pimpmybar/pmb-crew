-- PMB CREW — cofnięcie update30 (import eventów z formularza umowy) do stanu po update29.
-- Usuwa funkcje event_intake, intake_org i pomocnicze, indeks events_intake_uq, kolumny events.intake_id,
-- events.intake_at, events.client_email oraz klucze importu z settings ('intake_key').
-- UWAGA: razem z kolumnami znika informacja, które eventy przyszły z formularza (plakietka „z formularza"),
-- a po ponownym uruchomieniu update30 klucze importu będą nowe — trzeba je wpisać w Apps Script na nowo.
-- Same eventy zostają. Bezpieczne do wielokrotnego uruchomienia.
drop function if exists event_intake(text, json);
drop function if exists intake_org(text);
drop function if exists intake_text(json, text);
drop function if exists intake_date(text);
drop function if exists intake_time(text);
drop function if exists intake_int(text);
drop index if exists events_intake_uq;
alter table events drop column if exists intake_id;
alter table events drop column if exists intake_at;
alter table events drop column if exists client_email;
delete from settings where key = 'intake_key';

notify pgrst, 'reload schema';
