# PMB CREW

Aplikacja operacyjna Pimp My Bar: eventy, agendy, ekipa, magazyn, zakupy.
Statyczne strony HTML + Supabase. Bez frameworka, bez kroku budowania.

## Struktura
- `panel.html` — panel właściciela (logowanie e-mail/hasło)
- `crew.html`, `agenda.html`, `menu.html`, `remanent.html`, `zakupy.html`, `zwrot.html` — strony dla ekipy (dostęp po tokenie w linku)
- `pmb-core.js` — wspólny rdzeń (sesja, `api()`, `rpc()`, formatowanie, marka) — ładowany przez każdą stronę
- `schema.sql` — pełny schemat bazy w stanie po update26 (zrzut z produkcji 01.09.2026; oryginalne update1–26 przepadły)
- `update27.sql` … `update30.sql` — kolejne migracje, uruchamiane po kolei w Supabase → SQL Editor; `updateNN_rollback.sql` (np. `update29_rollback.sql`) — cofnięcie danej migracji (nie są migracjami, poligon je pomija)
- `szklo.html`, `protokol.html` — protokół szkła (od update29, opis niżej)
- `intake/PmbImport.gs` — Apps Script arkusza z odpowiedziami formularza „Dane do umowy" (od update30, opis niżej)
- `db/test/` — lokalny poligon migracji (Postgres 16)
- `testNN.mjs` — testy Playwright (mockowane REST)
- `docs/superpowers/specs/` — architektura; `docs/superpowers/plans/` — plany wdrożeń

## Testy
```bash
bash db/test/run.sh                                  # odtwarza bazę z migracji lokalnie + testy SQL
for t in $(ls test*.mjs | sort -V); do node $t; done # testy stron (wymaga playwright + Chromium)
```

## Wdrożenie migracji
1. Supabase → SQL Editor → wklej treść `updateNN.sql` → Run.
2. Sprawdź w aplikacji to, co zmienia migracja (opis w nagłówku pliku).
3. Test bezpieczeństwa danych (etap 1+): wklej `db/test/test_isolation.sql` — działa w transakcji i nic nie zostawia.

## Organizacje (od update27)
Każdy rekord ma `org_id`. Użytkownik widzi tylko organizację, do której należy (`org_members`).
Konfiguracja (marka, kolejność kategorii, kategorie kupowane) — `orgs.config`, edytowana w Ustawieniach.
Linki rekrutacyjne bez tokenu przyjmują `?o=<slug>`; brak parametru = `DEFAULT_ORG_SLUG` z `pmb-core.js`.

## Magazyn = suma ruchów (od update28)
`catalog.stock` nie jest już nadpisywany — każda zmiana to wiersz w `stock_moves` (trigger utrzymuje `stock`):
- `event_wydanie` — odhaczenie pozycji w pakowaniu (panel lub telefon ekipy); odznaczenie tworzy ruch odwrotny,
- `event_powrot` — wpis w zwrocie z eventu (`zwrot.html?w=<my_token>&ev=<event>`, link w widoku magazynowym),
- `remanent_korekta` — zmiana w remanencie (`remanent.html`), `korekta_reczna` — zmiana stanu wprost w panelu.
Śledzone są tylko pozycje ze stanem (`stock is not null`) podpięte do katalogu z ilością liczbową.
Napoczęte opakowania (`catalog.opened_qty`) są poza stanem. Produkty z `catalog.perishable` (puree, pulpy) przy zwrocie pokazują „napoczęte wylewamy” — wraca tylko to, co zamknięte. Zapas poza agendą: `packing_items.reserve` (ekipa dodaje w widoku magazynowym eventu, `wh_reserve_add/remove`), schodzi ze stanu i wraca jak reszta. Widok `event_usage` = wydano (w tym zapas) − wróciło per event.

## Protokół szkła (od update29)
Szkło rozlicza osobny, podpisany protokół — nie zwrot z eventu (tam szkło jest tylko do odczytu).
- `szklo.html?w=<my_token>&ev=<event>` — ekipa: wydanie (podpis organizatora przed eventem), liczenie w trakcie, zwrot (podpis po evencie); link w widoku magazynowym eventu.
- `protokol.html?p=<public_token>` — dokument dla organizatora (obie strony, straty, forma płatności), otwierany bez logowania po losowym tokenie.
- Stan: zwrot protokołu robi jeden ruch `event_powrot` (wróciło + straty) i — gdy są straty — jeden ruch `strata` na minus. Straty liczy wyłącznie protokół, cena jest w nim zamrożona (`price_per_item`).
- Panel → event → Pakowanie → karta „Szkło”: wydano/wróciło/straty, kwota i forma płatności, przycisk „Rozliczone” (`settled_at`, `settled_by`), „Cofnij rozliczenie” i „Anuluj protokół” (`glass_protocol_void` — odwraca ruchy magazynowe, przywraca wpisy zwrotu z eventu i zwalnia miejsce na nowy podpis; zwrot anuluje się przed wydaniem). W liście eventów znaczniki „szkło do rozliczenia” i „szkło bez zwrotu” (event po terminie z samym wydaniem).
- Zwrot bez wydania: gdy nie ma podpisanego wydania, w `szklo.html` zakładka Zwrot liczy od ilości z pakowania. Ilości spakowane, a nieoddane organizatorowi wracają razem ze zwrotem, dlatego `event_powrot` protokołu = wróciło + niewydane + straty − wcześniejszy zwrot.
- Szkła nie da się oddać ręcznym zwrotem z eventu (`wh_return_set` odrzuca je błędem `glass`) — jedyną drogą jest protokół.
- **Kolejność wdrożenia update29:** najpierw strony (`szklo.html`, `protokol.html`, `crew.html`, `zwrot.html`, `panel.html`), potem `update29.sql` w Supabase. Link „Protokół szkła” u ekipy zadziała dopiero po migracji.
- `orgs.config`: `glass_price` (domyślna stawka zł/szt., nadpisywana per event przez `events.glass_price`), `glass_categories` (kategorie katalogu liczone jako szkło), dane firmy na protokół — `company_name`, `nip`, `address`, `email`, `phone`. Wszystko edytowalne w Ustawieniach.

## Import z formularza umowy (od update30)
Formularz Google „Dane do umowy" zapisuje odpowiedzi w arkuszu „EVENTY PIMP MY BAR" (osobna zakładka na rodzaj usługi).
Skrypt arkusza wysyła każdy wiersz do bazy (`event_intake`), a event pojawia się w panelu jako **wstępny** z plakietką
„z formularza" — właściciel go sprawdza i potwierdza. Wdrożenie:
1. Supabase → SQL Editor → `update30.sql` → Run (dodaje `events.intake_id/intake_at/client_email`, klucz `intake_key` w `settings`
   i funkcję `event_intake`). Cofnięcie: `update30_rollback.sql`.
2. Arkusz → Rozszerzenia → Apps Script → w istniejącym projekcie dodaj NOWY plik (Pliki → + → Skrypt) o nazwie PmbImport i wklej `intake/PmbImport.gs` (istniejącego skryptu umów nie ruszaj); Ustawienia projektu → Właściwości skryptu →
   `INTAKE_KEY` = wartość z panelu (Ustawienia → „Klucz importu z formularza", przycisk Kopiuj); uruchom raz `pmbSetup()`
   i zatwierdź uprawnienia (zakłada wyzwalacz „przy przesłaniu formularza").
3. Zaległe wiersze (opcjonalnie): otwórz zakładkę w arkuszu i uruchom `pmbImportSheet()` — wyśle wiersze bez wpisu w kolumnie
   `PMB import`. Kolumna ta (dopisywana na końcu nagłówków) trzyma wynik: `created|exists|linked <id>` albo treść błędu.
   Wszystkie zakładki naraz, tylko eventy z datą od dziś: `pmbImportUpcoming()` (przenosi też link do umowy wpisany
   w kolumnie „Liczba gości” na właściwe pole — `pmbFixRow_`).

Duplikaty: `intake_id` = `sygnatura czasowa|adres e-mail` z unikalnym indeksem per organizacja. Ponowne wysłanie tego samego
wiersza zwraca `exists` i niczego nie zmienia (uzupełni tylko pusty link do umowy). Jeśli event był już wpisany ręcznie —
ta sama data i ten sam klient — wiersz się do niego **podpina** (`linked`): dostaje sygnaturę, e-mail i link do umowy,
a pozostałe pola zostają nietknięte. Nagłówki czytane są tolerancyjnie (po początku, bez względu na wielkość liter i spacje),
daty w formatach `YYYY-MM-DD`, `DD.MM.YYYY`, `DD/MM/YYYY`, godziny sprowadzane do `HH:MM`.

## Kopia repo
Sesje Claude nie trzymają plików między uruchomieniami. Po każdej sesji zapisz `pmb-crew.bundle`
(`git bundle create pmb-crew.bundle --all`) i wgraj zmiany na GitHub. Odtworzenie: `git clone pmb-crew.bundle pmb-crew`.
