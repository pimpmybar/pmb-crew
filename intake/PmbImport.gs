/* PMB CREW — import wpisów z formularza „Dane do umowy" do aplikacji.
   Skrypt arkusza „EVENTY PIMP MY BAR" (Rozszerzenia → Apps Script) — OSOBNY plik PmbImport.gs obok istniejącego
   skryptu generującego umowy; nazwy funkcji z przedrostkiem pmb, żeby nie kolidować z jego onFormSubmit. Każdy wysłany formularz trafia
   do bazy przez funkcję event_intake (update30.sql) i pojawia się w panelu jako event „wstepny"
   z plakietką „z formularza". Powtórne wysłanie tego samego wiersza nie tworzy drugiego eventu.

   Wdrożenie (opis też w README):
   1. Wklej ten plik do Apps Script arkusza.
   2. Ustawienia projektu → Właściwości skryptu → INTAKE_KEY = klucz z panelu (Ustawienia → „Klucz importu z formularza").
   3. Uruchom raz pmbSetup() i zaakceptuj uprawnienia. Backfill starych wierszy: pmbImportSheet() na każdej zakładce. */

var SUPABASE_URL = 'https://zqpqjgxtefzojhjglppb.supabase.co';
var SUPABASE_KEY = 'sb_publishable__bPrQF9K35vs8RbLdWBRXQ_VBVj2esQ';   // klucz publiczny (anon), ten sam co na stronach
var STATUS_HEADER = 'PMB import';   // kolumna z wynikiem importu, dopisywana na końcu wiersza nagłówków
var TZ = 'Europe/Warsaw';

function intakeKey_() {
  var k = PropertiesService.getScriptProperties().getProperty('INTAKE_KEY');
  if (!k) throw new Error('Brak INTAKE_KEY — Ustawienia projektu → Właściwości skryptu (klucz z panelu → Ustawienia).');
  return k;
}

/* Strefa czasowa arkusza (nie skryptu) — w niej arkusz buduje obiekty Date dla komórek z godziną. */
var sheetTz_ = null;
function sheetTz() {
  if (!sheetTz_) {
    try { sheetTz_ = SpreadsheetApp.getActiveSpreadsheet().getSpreadsheetTimeZone(); } catch (e) {}
    if (!sheetTz_) sheetTz_ = TZ;
  }
  return sheetTz_;
}

/* Wartość komórki jako tekst. Daty i godziny arkusz podaje jako obiekt Date
   (komórka z godziną to Date na 1899-12-30), więc formatujemy je sami.
   disp = tekst widoczny w komórce (getDisplayValues). Dla godzin bierzemy właśnie jego: Date z 1899 r.
   przeliczany między strefami dostaje historyczne przesunięcie (LMT, Warszawa +1:24) i godzina
   wychodziła przesunięta o +1:14. Bez disp formatujemy w strefie arkusza, nie w TZ. */
function cell_(v, disp) {
  if (v === null || v === undefined) return '';
  if (Object.prototype.toString.call(v) === '[object Date]') {
    if (v.getFullYear() < 1900) {                                                        // godzina: Date na 1899-12-30
      var m = /(\d{1,2}):(\d{2})/.exec(String(disp || ''));
      if (m) return ('0' + m[1]).slice(-2) + ':' + m[2];
      return Utilities.formatDate(v, sheetTz(), 'HH:mm');
    }
    var midnight = v.getHours() === 0 && v.getMinutes() === 0 && v.getSeconds() === 0;
    return Utilities.formatDate(v, TZ, midnight ? 'yyyy-MM-dd' : 'yyyy-MM-dd HH:mm:ss'); // data / sygnatura czasowa
  }
  if (Array.isArray(v)) return v.map(cell_).filter(String).join(', ');
  return String(v).trim();
}

/* Wiersz jako {nagłówek: wartość}. Przy powtórzonych nagłówkach (np. dwa „Link do dokumentu")
   zostaje pierwsza niepusta wartość — bazie wystarczy jedna. */
function rowObject_(headers, values, display) {
  var row = {};
  for (var i = 0; i < headers.length; i++) {
    var h = cell_(headers[i]);
    if (!h || h === STATUS_HEADER) continue;
    var v = cell_(values[i], display ? display[i] : '');
    if (row[h] === undefined || row[h] === '') row[h] = v;
  }
  return row;
}

/* Wysyłka do bazy. Zwraca {ok, action, id} albo {ok:false, error}. */
function post_(row) {
  var res = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/event_intake', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY },
    payload: JSON.stringify({ p_key: intakeKey_(), p_row: row }),
    muteHttpExceptions: true
  });
  var code = res.getResponseCode(), body = res.getContentText();
  if (code < 200 || code >= 300) return { ok: false, error: 'HTTP ' + code + ': ' + body.slice(0, 300) };
  var j;
  try { j = JSON.parse(body); } catch (e) { return { ok: false, error: 'zła odpowiedź: ' + body.slice(0, 300) }; }
  return { ok: true, action: j && j.action, id: j && j.id };
}

/* Numer kolumny „PMB import” (dopisuje nagłówek, jeśli go nie ma). */
function statusCol_(sheet) {
  var last = sheet.getLastColumn();
  var headers = sheet.getRange(1, 1, 1, last).getValues()[0];
  for (var i = 0; i < headers.length; i++) if (cell_(headers[i]) === STATUS_HEADER) return i + 1;
  sheet.getRange(1, last + 1).setValue(STATUS_HEADER);
  return last + 1;
}

function writeStatus_(sheet, rowIdx, text) {
  try { sheet.getRange(rowIdx, statusCol_(sheet)).setValue(text); } catch (e) { Logger.log('status: ' + e); }
}

function sendRow_(sheet, rowIdx, row) {
  var r = post_(row);
  var text = r.ok ? (r.action + ' ' + (r.id || '')) : ('BŁĄD: ' + r.error);
  Logger.log('wiersz ' + rowIdx + ': ' + text);
  writeStatus_(sheet, rowIdx, text);
  return r;
}

/* Wyzwalacz „przy przesłaniu formularza”. */
function pmbOnFormSubmit(e) {
  var sheet = (e && e.range) ? e.range.getSheet() : SpreadsheetApp.getActiveSheet();
  var rowIdx = (e && e.range) ? e.range.getRow() : sheet.getLastRow();
  var row;
  if (e && e.namedValues) {
    row = {};
    for (var k in e.namedValues) {
      var h = String(k).trim();
      if (!h || h === STATUS_HEADER) continue;
      var v = cell_(e.namedValues[k]);
      if (row[h] === undefined || row[h] === '') row[h] = v;
    }
  } else {
    var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    var rng = sheet.getRange(rowIdx, 1, 1, sheet.getLastColumn());
    row = rowObject_(headers, rng.getValues()[0], rng.getDisplayValues()[0]);
  }
  sendRow_(sheet, rowIdx, row);
}

/* Ręczne dosłanie zaległych wierszy z aktywnej zakładki (pomija te, które mają już wynik w „PMB import”). */
function pmbImportSheet() {
  var sheet = SpreadsheetApp.getActiveSheet();
  var lastRow = sheet.getLastRow(), lastCol = sheet.getLastColumn();
  if (lastRow < 2) { Logger.log('pusta zakładka'); return; }
  var col = statusCol_(sheet);
  lastCol = Math.max(lastCol, col);
  var headers = sheet.getRange(1, 1, 1, lastCol).getValues()[0];
  var body = sheet.getRange(2, 1, lastRow - 1, lastCol);
  var data = body.getValues(), shown = body.getDisplayValues();
  var sent = 0, skipped = 0;
  for (var i = 0; i < data.length; i++) {
    if (cell_(data[i][col - 1]) !== '') { skipped++; continue; }
    var row = rowObject_(headers, data[i], shown[i]);
    var any = false;
    for (var h in row) if (row[h] !== '') { any = true; break; }
    if (!any) { skipped++; continue; }
    sendRow_(sheet, i + 2, row);
    sent++;
    Utilities.sleep(200);   // bez zrywania limitów UrlFetch
  }
  Logger.log('zakładka ' + sheet.getName() + ': wysłano ' + sent + ', pominięto ' + skipped);
}

/* Jednorazowo: zakłada wyzwalacz na przesłanie formularza. */
function pmbSetup() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var have = ScriptApp.getProjectTriggers().some(function (t) {
    return t.getHandlerFunction() === 'pmbOnFormSubmit' && t.getEventType() === ScriptApp.EventType.ON_FORM_SUBMIT;
  });
  if (!have) {
    ScriptApp.newTrigger('pmbOnFormSubmit').forSpreadsheet(ss).onFormSubmit().create();
    Logger.log('wyzwalacz pmbOnFormSubmit założony');
  } else {
    Logger.log('wyzwalacz pmbOnFormSubmit już istnieje');
  }
  var k = PropertiesService.getScriptProperties().getProperty('INTAKE_KEY');
  Logger.log(k ? 'INTAKE_KEY ustawiony' : 'UWAGA: ustaw INTAKE_KEY w Ustawieniach projektu → Właściwości skryptu (klucz z panelu → Ustawienia).');
}

/* ===== Dosłanie zaległych eventów =====
   pmbImportUpcoming(): wszystkie zakładki formularza, tylko wiersze z datą od dziś i bez wyniku w „PMB import”. */
function pmbImportUpcoming() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var today = new Date(); today.setHours(0, 0, 0, 0);
  var sent = 0;
  ss.getSheets().forEach(function (sheet) {
    var lastRow = sheet.getLastRow(), lastCol = sheet.getLastColumn();
    if (lastRow < 2) return;
    var headers = sheet.getRange(1, 1, 1, lastCol).getValues()[0].map(cell_);
    if (headers.indexOf('Sygnatura czasowa') < 0) return;
    var dateIdx = headers.indexOf('Data rozpoczęcia usługi');
    if (dateIdx < 0) return;
    var statusIdx = headers.indexOf(STATUS_HEADER);
    var data = sheet.getRange(2, 1, lastRow - 1, lastCol).getValues();
    for (var i = 0; i < data.length; i++) {
      var d = data[i][dateIdx];
      if (Object.prototype.toString.call(d) !== '[object Date]' || d < today) continue;
      if (statusIdx >= 0 && cell_(data[i][statusIdx]) !== '') continue;
      var col = statusCol_(sheet);
      var hdr = sheet.getRange(1, 1, 1, Math.max(lastCol, col)).getValues()[0];
      var rng = sheet.getRange(i + 2, 1, 1, Math.max(lastCol, col));
      sendRow_(sheet, i + 2, pmbFixRow_(rowObject_(hdr, rng.getValues()[0], rng.getDisplayValues()[0])));
      sent++;
      Utilities.sleep(200);
    }
  });
  Logger.log('Dosłano: ' + sent);
}

/* W starszych zakładkach link do umowy siedzi w kolumnie „Liczba gości” — przenosimy go na właściwe pole. */
function pmbFixRow_(row) {
  var g = String(row['Liczba gości'] || '');
  if (/^https?:\/\//i.test(g)) {
    if (!row['Link do dokumentu']) row['Link do dokumentu'] = g;
    row['Liczba gości'] = '';
  }
  return row;
}
