/* PMB — wspólny rdzeń stron: połączenie z Supabase, sesja, formatowanie.
   Ładowany klasycznym <script src="pmb-core.js"> przed skryptem strony; definiuje zmienne globalne. */
const SUPABASE_URL = 'https://zqpqjgxtefzojhjglppb.supabase.co';
const SUPABASE_KEY = 'sb_publishable__bPrQF9K35vs8RbLdWBRXQ_VBVj2esQ';
const DEFAULT_ORG_SLUG = 'pmb';   // organizacja domyślna dla linków bez parametru ?o= (rekrutacja, warunki)

const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtN = n => n == null ? '' : Number(n).toLocaleString('pl-PL', {maximumFractionDigits: 2});
const fmtD = d => d ? new Date(d + 'T00:00:00').toLocaleDateString('pl-PL', {day:'2-digit', month:'2-digit'}) : '';

/* ---------- SESJA (Supabase Auth) ---------- */
let session = null;
async function auth(path, body){
  const r = await fetch(`${SUPABASE_URL}/auth/v1/${path}`, {method:'POST', headers:{'apikey':SUPABASE_KEY, 'Content-Type':'application/json'}, body: JSON.stringify(body)});
  const j = await r.json(); if(!r.ok) throw new Error(j.error_description || j.msg || j.error || 'auth'); return j;
}
function saveSession(s){ session = s; localStorage.setItem('pmb_session', JSON.stringify(s)); }
async function ensureSession(){
  let s = null; try { s = JSON.parse(localStorage.getItem('pmb_session') || 'null'); } catch(e) {}
  if(!s) return false;
  if(s.expires_at * 1000 - Date.now() > 60000){ session = s; return true; }
  try { saveSession(await auth('token?grant_type=refresh_token', {refresh_token: s.refresh_token})); return true; } catch(e) { return false; }
}

/* ---------- REST / RPC ---------- */
async function api(method, path, body, prefer){
  if(session && session.expires_at * 1000 - Date.now() < 60000) await ensureSession();
  const token = session ? session.access_token : SUPABASE_KEY;
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {method, headers:{'apikey':SUPABASE_KEY, 'Authorization':'Bearer ' + token, 'Content-Type':'application/json', 'Prefer': prefer || 'return=representation'}, body: body ? JSON.stringify(body) : undefined});
  if(r.status === 401 && session){ localStorage.removeItem('pmb_session'); location.reload(); return; }
  if(!r.ok) throw new Error(await r.text());
  const t = await r.text(); return t ? JSON.parse(t) : null;
}
const apiGet = path => api('GET', path);
async function rpc(fn, args){
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {method:'POST', headers:{'apikey':SUPABASE_KEY, 'Authorization':'Bearer ' + SUPABASE_KEY, 'Content-Type':'application/json'}, body: JSON.stringify(args || {})});
  if(!r.ok) throw new Error(await r.text());
  const t = await r.text(); return t ? JSON.parse(t) : null;
}

/* ---------- ORGANIZACJA, MOTYW, MARKA ---------- */
function orgSlug(){ return new URLSearchParams(location.search).get('o') || DEFAULT_ORG_SLUG; }
function initTheme(btnId){
  if(localStorage.getItem('pmb_theme') === 'light') document.documentElement.classList.add('light');
  const b = btnId && $(btnId); if(b) b.onclick = () => { const l = document.documentElement.classList.toggle('light'); localStorage.setItem('pmb_theme', l ? 'light' : 'dark'); };
}
function applyBrand(brand){
  if(!brand) return;
  document.querySelectorAll('.logo').forEach(el => { const s = el.querySelector('span'); el.textContent = brand + ' '; if(s) el.appendChild(s); });
}
