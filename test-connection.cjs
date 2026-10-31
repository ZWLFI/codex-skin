// Stop Codex Skin first; this test requires an unused localhost port 9342.
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { wsServer } = require('/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/playwright-core/lib/utilsBundle.js');
const binary = `${__dirname}/dist/Codex Skin.app/Contents/MacOS/CodexBackground`;

async function main() {
  let mode = 'delayed', received = 0;
  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(['main', 'avatar'].map(name => ({
      type: 'page',
      url: 'app://-/index.html' + (name === 'avatar' ? '?initialRoute=%2Favatar-overlay' : ''),
      webSocketDebuggerUrl: `ws://127.0.0.1:9342/${name}`
    }))));
  });
  const sockets = new wsServer({ server, maxPayload: 40 * 1024 * 1024 });
  sockets.on('connection', (socket, request) => {
    assert.equal(request.url, '/main', 'Never inject into the avatar window');
    socket.on('message', data => {
      received++;
      const { id, method } = JSON.parse(data);
      assert.equal(method, 'Runtime.evaluate');
      if (mode === 'disconnect') { socket.close(); return; }
      socket.send(JSON.stringify({ method: 'Runtime.executionContextCreated', params: {} }));
      const result = mode === 'error'
        ? { exceptionDetails: { text: 'script failed' }, result: {} }
        : { result: { value: mode === 'loading' ? { ready: false } : { active: true } } };
      setTimeout(() => socket.send(JSON.stringify({ id, result })), mode === 'delayed' ? 4000 : 0);
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(9342, '127.0.0.1', resolve); });
  const check = (args = []) => new Promise((resolve, reject) => {
    const process = spawn(binary, ['--check-connection', ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    process.stdout.on('data', data => output += data);
    process.stderr.on('data', data => output += data);
    process.on('error', reject);
    process.on('exit', code => resolve({ code, output }));
  });
  try {
    for (mode of ['delayed', 'loading', 'error', 'disconnect', 'reconnected']) {
      const result = await check();
      assert.equal(result.code, ['delayed', 'reconnected'].includes(mode) ? 0 : 1, `${mode}: ${result.output}`);
    }
    assert.equal(received, 5);
    const burst = await check(['--burst']);
    assert.equal(burst.code, 0);
    assert.equal(received, 6, '50 slider events must coalesce into one injection');
  } finally {
    for (const socket of sockets.clients) socket.terminate();
    await new Promise(resolve => sockets.close(resolve));
    await new Promise(resolve => server.close(resolve));
  }
  const refused = await check();
  assert.equal(refused.code, 1);
  assert.match(refused.output, /背景接口未开启/);
  console.log('connection test passed: delayed response, events, loading, error, disconnect, reconnect, refused port');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
