/// Static presentation only. No provider credentials, device identity,
/// bootstrap code, session or CSRF is embedded in any asset.
pub const html = "<!doctype html>
<html lang='en'>
<head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>MIMIC · Accounts</title><link rel='stylesheet' href='/panel.css'>
<script src='/panel.js' defer></script></head>
<body><main>
<header><p class='eyebrow'>MIMIC / OPERATOR · LOOPBACK ONLY</p>
<h1>Account enrollment</h1>
<p>Connect a configured Kimi, Codex or Grok OAuth account to MIMIC's existing gateway store.
This does not configure or log in to CPA.</p></header>
<section id='unlock'><h2>Unlock this operator session</h2>
<p>Read the one-time bootstrap file printed by the server. Its code expires in five minutes.
Never paste a provider token here.</p>
<form id='unlock-form'><label for='bootstrap'>One-time operator code</label>
<input id='bootstrap' type='password' autocomplete='off' spellcheck='false' maxlength='43' required>
<button id='unlock-submit' type='submit'>Unlock session</button></form></section>
<section id='operator' hidden>
<div class='toolbar'><h2>Configured accounts</h2><button id='refresh'>Refresh status</button>
<button id='logout'>End operator session</button></div>
<p>Login starts the configured provider's cancellable authorization flow. Login links and verification details are shown only while it is pending.
Cancellation stops this local flow; it does not revoke an existing provider grant.</p>
<div id='accounts'></div>
</section>
<p id='notice' role='status' aria-live='polite'></p>
<footer>Private files are permission-protected, not encrypted. The gateway remains the only refresh manager.
Only explicit configured endpoints are used. No live-provider qualification is implied.</footer>
</main></body></html>"

pub const css = "
:root { color-scheme: light dark; font: 16px/1.5 system-ui,sans-serif; }
body { margin:0; background:#111820; color:#e7edf3; }
main { max-width:850px; margin:3rem auto; padding:0 1.5rem; }
h1 { font-size:2rem; line-height:1.2; } h2 { font-size:1.25rem; }
.eyebrow { color:#9cbabf; font-size:.8rem; letter-spacing:.12em; }
header p, footer { color:#b8c7d3; }
section, article { border:1px solid #3e4e60; border-radius:8px; padding:1.25rem; margin:1rem 0; }
label { display:block; margin-bottom:.4rem; }
input,button { font:inherit; padding:.6rem .8rem; border-radius:5px; border:1px solid #8a9dad; }
input { width:min(95%,26rem); background:#19232f; color:inherit; margin:0 .5rem .7rem 0; }
button { background:#bedcdb; color:#15252b; cursor:pointer; margin:.25rem .5rem .25rem 0; }
button:disabled { opacity:.5; cursor:default; } button:focus-visible,input:focus-visible,a:focus-visible { outline:3px solid #e4ca89; outline-offset:3px; }
.toolbar { display:flex; flex-wrap:wrap; align-items:center; gap:.5rem; }
.toolbar h2 { flex:1; min-width:15rem; }
.verification { padding:.75rem; background:#1e3139; border-radius:5px; overflow-wrap:anywhere; }
a { color:#b2dce1; } code { font-size:1.2rem; letter-spacing:.1em; }
#notice { min-height:1.5rem; color:#e4ca89; } footer { margin-top:2rem; font-size:.85rem; }
[hidden] { display:none!important; }
@media(max-width:500px) { main { margin:1.5rem auto; padding:0 1rem; } h1 { font-size:1.65rem; } section,article { padding:.8rem; } }
"

pub const javascript = "
'use strict';
(() => {
  let csrf = null;
  let timer = null;
  let inFlight = null;
  let generation = 0;
  let unlocking = false;
  let renderedState = null;
  const notice = document.getElementById('notice');
  const accounts = document.getElementById('accounts');
  const input = document.getElementById('bootstrap');
  const operator = document.getElementById('operator');
  const unlockButton = document.getElementById('unlock-submit');
  const tell = (text) => { notice.textContent = text; };
  function advance() {
    generation += 1;
    clearTimeout(timer);
    timer = null;
    inFlight = null;
    unlocking = false;
    unlockButton.disabled = false;
    renderedState = null;
    accounts.replaceChildren();
  }
  const snapshot = () => ({generation,csrf});
  const visible = () => !document.hidden && !operator.hidden;
  const current = ticket => ticket.generation === generation && ticket.csrf === csrf && !!csrf && visible();
  function schedule(ticket, delay) {
    if (!current(ticket)) return;
    clearTimeout(timer);
    timer = setTimeout(() => { if (current(ticket)) status(); }, delay);
  }
  function clearSession(message) {
    advance();
    csrf = null;
    operator.hidden = true;
    document.getElementById('unlock').hidden = false;
    input.value = '';
    tell(message);
  }
  async function api(path, data, capability = csrf) {
    const headers = {'Content-Type':'application/json','X-Mimic-UI':'1'};
    if (capability) headers['X-CSRF-Token'] = capability;
    const response = await fetch(path, {
      method:'POST',headers,body:JSON.stringify(data),
      credentials:'same-origin',cache:'no-store',referrerPolicy:'no-referrer'
    });
    const value = await response.json();
    if (!response.ok) {
      const error = new Error(value.error || 'Operator request rejected');
      error.status = response.status;
      throw error; // A stale response cannot mutate another session's state.
    }
    return value;
  }
  function failure(error, ticket) {
    if (!current(ticket)) return;
    accounts.replaceChildren();
    if (error.status === 401) clearSession('Session ended. Restart the operator UI for a new bootstrap code.');
    else tell(error.message);
  }
  function node(tag, text, parent) {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (parent) parent.appendChild(element);
    return element;
  }
  function render(value) {
    const nextState = JSON.stringify(value.accounts);
    if (nextState === renderedState) return; // Polling must not steal keyboard focus.
    renderedState = nextState;
    accounts.replaceChildren();
    const rendered = snapshot();
    const active = value.accounts.some(a => ['starting','waiting','exchanging'].includes(a.login));
    for (const account of value.accounts) {
      const card = node('article', undefined, accounts);
      node('h3', account.id, card);
      node('p', 'Credential: ' + account.credential + ' · Login: ' + account.login, card);
      if (account.expires_at_ms) node('p', 'Grant expiry: ' + new Date(account.expires_at_ms).toLocaleString(), card);
      const provider = account.provider === 'codex' ? 'Codex' : account.provider === 'xai' ? 'Grok' : 'Kimi';
      const login = node('button', 'Log in to ' + provider, card);
      login.disabled = active;
      login.addEventListener('click', () => act('/api/login', account.id, rendered));
      const cancel = node('button', 'Cancel login', card);
      cancel.disabled = !['starting','waiting','exchanging'].includes(account.login);
      cancel.addEventListener('click', () => act('/api/cancel', account.id, rendered));
      if (account.verification_uri && account.user_code) {
        const verify = node('div', undefined, card);
        verify.className = 'verification';
        node('p', 'Authorize this code with ' + provider + ':', verify);
        node('code', account.user_code, verify);
        const line = node('p', undefined, verify);
        const link = node('a', 'Open ' + provider + ' verification', line);
        link.href = account.verification_uri;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        link.referrerPolicy = 'no-referrer';
        node('p', account.verification_uri, verify);
      }
      if (account.authorization_url) {
        const verify = node('div', undefined, card);
        verify.className = 'verification';
        node('p', 'Authorize the configured Codex account, then return here for installation status:', verify);
        const link = node('a', 'Open Codex login', verify);
        link.href = account.authorization_url;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        link.referrerPolicy = 'no-referrer';
      }
    }
    if (value.accounts.length === 0) node('p', 'No configured supported OAuth accounts.', accounts);
  }
  async function status() {
    if (!csrf || !visible() || (inFlight && inFlight.generation === generation)) return;
    const ticket = snapshot();
    inFlight = ticket;
    try {
      const value = await api('/api/status', {}, ticket.csrf);
      if (current(ticket)) render(value);
    } catch (error) {
      failure(error, ticket);
    } finally {
      if (inFlight === ticket) inFlight = null;
      schedule(ticket, 1000);
    }
  }
  async function act(path, account, rendered) {
    if (!current(rendered)) return; // Detached buttons cannot use a new session.
    advance(); // Invalidate pending status/login replies before clearing prompts.
    const ticket = snapshot();
    try {
      const value = await api(path, {account}, ticket.csrf);
      if (current(ticket)) { render(value); tell('Status updated.'); }
    } catch (error) { failure(error, ticket); }
    schedule(ticket, 250);
  }
  document.getElementById('unlock-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (unlocking) return;
    const code = input.value;
    input.value = ''; // One-time code is never retained after the exchange.
    advance();
    const version = generation;
    csrf = null;
    unlocking = true;
    unlockButton.disabled = true;
    try {
      const value = await api('/api/session', {code}, null);
      if (version !== generation || document.hidden) return;
      csrf = value.csrf; // Memory only; no local/session storage or URL state.
      document.getElementById('unlock').hidden = true;
      operator.hidden = false;
      tell('Operator session unlocked.');
      await status();
    } catch (error) { if (version === generation && !document.hidden) tell(error.message); }
    finally {
      if (version === generation) { unlocking = false; unlockButton.disabled = false; }
    }
  });
  document.getElementById('refresh').addEventListener('click', status);
  document.getElementById('logout').addEventListener('click', async () => {
    const capability = csrf;
    clearSession('Ending operator session...');
    const version = generation;
    try {
      await api('/api/logout', {}, capability);
      if (version === generation && !document.hidden) tell('Session ended. Restart the operator UI to unlock again.');
    } catch (error) {
      if (version === generation && !document.hidden) tell('Session hidden; server cancellation unconfirmed. ' + error.message);
    }
  });
  // Hide transient prompts while this page is backgrounded or navigating away.
  document.addEventListener('visibilitychange', () => {
    advance();
    input.value = '';
    if (!document.hidden) status();
  });
  window.addEventListener('pagehide', () => {
    clearSession('Page left. Restart the operator UI to unlock again.');
  });
})();
"
