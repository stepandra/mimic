(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  let managementKey = '';
  const status = (message) => { $('status').textContent = message; };
  async function api(path, method = 'GET', body) {
    if (!managementKey) throw new Error('Enter the management key first');
    const response = await fetch(path, {
      method,
      headers: { Authorization: `Bearer ${managementKey}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
      credentials: 'omit'
    });
    if (!response.ok) throw new Error(`Request failed (${response.status})`);
    return response.json();
  }
  async function run(action) {
    try { await action(); status('Operation completed.'); }
    catch (error) { status(error.message); }
  }
  function form(id, action) {
    $(id).addEventListener('submit', (event) => {
      event.preventDefault();
      run(() => action(event.currentTarget));
    });
  }
  async function refresh(id, path) {
    $(id).textContent = JSON.stringify(await api(path), null, 2);
  }
  $('connect').addEventListener('click', () => run(async () => {
    managementKey = $('management-key').value;
    $('management-key').value = '';
    await api('/api/health');
    await Promise.all([refresh('credentials', '/api/credentials'), refresh('keys', '/api/keys'), refresh('quotas', '/api/quotas'), refresh('drift', '/api/drift')]);
  }));
  form('active-form', async () => { await refresh('active', `/api/personas/${encodeURIComponent($('provider').value)}/active`); });
  form('draft-form', async () => {
    const result = await api(`/api/personas/${encodeURIComponent($('draft-provider').value)}/drafts`, 'PUT', { content: $('draft-content').value });
    status(`Draft stored: ${result.digest}. Not active until gated promotion.`);
  });
  form('promote-form', async () => {
    const signature = $('signature').value;
    $('signature').value = '';
    await api('/api/promotions', 'POST', { run_id: $('run-id').value, signature });
    await refresh('active', `/api/personas/${encodeURIComponent($('provider').value)}/active`);
  });
  $('reload-credentials').addEventListener('click', () => run(() => refresh('credentials', '/api/credentials')));
  form('credential-form', async () => {
    const body = { id: $('credential-id').value, access_token: $('access-token').value, refresh_token: $('refresh-token').value, expires_at_ms: Number($('expires').value) };
    $('access-token').value = ''; $('refresh-token').value = '';
    await api('/api/credentials', 'POST', body);
    await refresh('credentials', '/api/credentials');
  });
  form('delete-credential-form', async () => {
    await api(`/api/credentials/${encodeURIComponent($('delete-credential').value)}`, 'DELETE');
    await refresh('credentials', '/api/credentials');
  });
  $('reload-keys').addEventListener('click', () => run(() => refresh('keys', '/api/keys')));
  form('key-form', async () => {
    const body = { id: $('key-id').value, token: $('key-token').value };
    $('key-token').value = '';
    await api('/api/keys', 'POST', body);
    await refresh('keys', '/api/keys');
  });
  form('delete-key-form', async () => {
    await api(`/api/keys/${encodeURIComponent($('delete-key').value)}`, 'DELETE');
    await refresh('keys', '/api/keys');
  });
  $('reload-views').addEventListener('click', () => run(async () => {
    await refresh('quotas', '/api/quotas');
    await refresh('drift', '/api/drift');
  }));
})();
