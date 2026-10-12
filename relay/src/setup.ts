export const setupHTML = `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<title>phone-use relay</title>
<style>
  html { color-scheme: light; background: #fff; }
  body { font: 16px/1.5 system-ui; max-width: 44rem; margin: 3rem auto; padding: 0 1rem; color: #20242a; }
  label { display: block; margin-top: 1rem; font-weight: 600; }
  input, button { font: inherit; padding: .5rem; margin: .2rem 0; }
  input { display: block; width: 100%; box-sizing: border-box; }
  pre { white-space: pre-wrap; overflow-wrap: anywhere; background: #f3f5f7; padding: 1rem; min-height: 2rem; }
  button { cursor: pointer; }
</style>
<h1>phone-use relay</h1>
<p>Enter the admin secret to inspect this Worker. It stays in this page's memory and is sent only in the Authorization header.</p>
<label>Admin secret<input id="admin" type="password" autocomplete="off"></label>
<label>Mac ID<input id="mac" placeholder="my-mac" autocomplete="off"></label>
<button id="status">Status</button>
<button id="pair">Create five-minute pairing token</button>
<button id="revoke">Revoke daemon</button>
<pre id="output"></pre>
<p>After pairing the daemon, give an MCP client the URL shown in status and its separate phone-use client credential. Do not share the admin, pairing, or daemon secret with an MCP client.</p>
<script>
  const output = document.querySelector('#output');
  async function run(action) {
    const mac = document.querySelector('#mac').value;
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(mac)) {
      output.textContent = 'Enter a valid Mac ID';
      return;
    }
    const response = await fetch('/admin/macs/' + encodeURIComponent(mac) + '/' + action, {
      method: action === 'status' ? 'GET' : 'POST',
      headers: { Authorization: 'Bearer ' + document.querySelector('#admin').value },
    });
    const data = await response.json();
    output.textContent = JSON.stringify({
      ...data,
      mcpURL: location.origin + '/mac/' + encodeURIComponent(mac) + '/mcp',
    }, null, 2);
  }
  for (const action of ['status', 'pair', 'revoke']) {
    document.querySelector('#' + action).onclick = () => run(action);
  }
</script>
</html>`;
