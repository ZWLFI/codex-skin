// Run with the Node bundled in ChatGPT.app. Uses the installed app's actual CSS.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { chromium } = require('/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/playwright');

async function main() {
  const archive = fs.openSync('/Applications/ChatGPT.app/Contents/Resources/app.asar', 'r');
  const prefix = Buffer.alloc(16);
  fs.readSync(archive, prefix, 0, 16, 0);
  const header = Buffer.alloc(prefix.readUInt32LE(12));
  fs.readSync(archive, header, 0, header.length, 16);
  const webview = JSON.parse(header).files.webview.files;
  const assets = webview.assets.files;
  const entries = function* (files) {
    for (const [name, entry] of Object.entries(files)) {
      if (entry.files) yield* entries(entry.files);
      else yield [name, entry];
    }
  };
  const readEntry = entry => {
    const data = Buffer.alloc(entry.size);
    fs.readSync(archive, data, 0, data.length, 8 + prefix.readUInt32LE(4) + Number(entry.offset));
    return data.toString();
  };
  // The document establishes layer precedence before any lazy CSS chunk loads.
  const layerOrder = readEntry(webview['index.html']).match(/@layer[^;]+;/)?.[0];
  assert(layerOrder, 'Updated app cascade order needs inspection');
  // Releases may use either descriptive chunk names or content hashes.
  const styles = layerOrder + '\n' + [...new Set([...entries(assets)].filter(([name]) => name.endsWith('.css')).map(([, entry]) => readEntry(entry)))].join('\n');
  fs.closeSync(archive);
  const componentClass = name => styles.match(new RegExp(`\\.(?:_${name}_\\w+|${name}-[\\w-]+)`))?.[0].slice(1);
  const workspace = componentClass('WorkspaceContent');
  const surface = componentClass('MainContentSurface');
  const fade = componentClass('MainContentTopFade');
  const layoutClass = styles.match(/\.(?:_Layout_\w+|Layout-[\w-]+)(?=\{--app-shell-titlebar-height)/)?.[0].slice(1);
  const contentFrame = componentClass('MainContentFrame');
  const topBackground = styles.match(/\.(background-[\w-]+),\.floatingHeader-[^{]+\{background-image:linear-gradient/)?.[1];
  const footerBackground = styles.match(/\.(background-[\w-]+)\{top:calc/)?.[1];
  const footerFade = styles.match(/\.(fade-[\w-]+)\{height:[^}]+--tw-gradient-position:to top/)?.[1];
  assert(topBackground && footerBackground && footerFade, 'Updated gradient components need inspection');
  assert(fade, 'Updated app top fade needs inspection');
  assert(workspace && surface, 'Updated app layout needs inspection');
  const binary = process.env.CODEX_SKIN_TEST_BINARY || `${__dirname}/dist/Codex Skin.app/Contents/MacOS/CodexBackground`;
  const script = execFileSync(binary, ['--print-injection-script'], { encoding: 'utf8' });
  const clear = execFileSync(binary, ['--print-injection-script', '--clear'], { encoding: 'utf8' });
  const probe = execFileSync(binary, ['--print-probe-script'], { encoding: 'utf8' });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage();
    assert.deepEqual(await page.evaluate(script), { ready: false }, 'An unmounted page is not a successful application');
    await page.setContent(`<html data-codex-window-type="electron"><head></head><body><div id="root">
      <div data-app-shell-frame data-app-shell-page-surface="true" data-app-shell-unified-tab-strip="true">
        <aside class="app-shell-left-panel"><nav class="sidebar-navigation">Sidebar</nav></aside>
        <header data-app-shell-main-titlebar>Title</header>
        <main data-app-shell-main-surface="default" class="${surface}">
          <div class="${fade} ${topBackground}"></div>
          <div class="${workspace}"><button id="click-test">Click</button></div>
        </main>
      </div></div></body></html>`);
    await page.addStyleTag({ content: styles });
    await page.addStyleTag({ content: ':root {--color-surface:rgb(255,255,255);--color-surface-secondary:rgb(240,240,240);--color-surface-tertiary:rgb(230,230,230)}' });
    assert.match(await page.locator(`.${fade}`).evaluate(el => getComputedStyle(el).backgroundImage), /linear-gradient/, 'Reproduce the actual top fade');
    const pseudoBackground = () => page.locator(`.${workspace}`).evaluate(el => getComputedStyle(el, '::before').backgroundColor);
    assert.notEqual(await pseudoBackground(), 'rgba(0, 0, 0, 0)', 'Reproduce the new opaque workspace layer');
    await page.locator('main').evaluate(el => el.insertAdjacentHTML('beforeend', '<div class="thread-scroll-container"><div class="bg-gradient-to-t from-surface" id="bottom-fade"></div><div data-thread-scroll-footer="true"><div id="footer-backdrop" class="pointer-events-none absolute bg-surface"></div><div data-composer-layout="multiline" class="bg-surface">Input</div></div></div>'));
    await page.addStyleTag({ content: '#bottom-fade{background-image:linear-gradient(to top,white,transparent)}#footer-backdrop,[data-composer-layout]{background-color:white}' });
    await page.locator('.thread-scroll-container').evaluate(el => el.insertAdjacentHTML('beforeend', '<div id="new-bottom-fade" class="_background_updated_2 _fade_updated_2 pointer-events-none absolute from-surface" style="background-image:linear-gradient(to top,white,transparent)"></div>'));
    await page.locator('.thread-scroll-container').evaluate((el, { footerBackground, footerFade }) => el.insertAdjacentHTML('beforeend', `<div id="current-bottom-fade" aria-hidden="true" class="${footerBackground} ${footerFade} pointer-events-none absolute from-surface" style="--tw-gradient-stops: white, transparent"></div>`), { footerBackground, footerFade });
    assert.match(await page.locator('#current-bottom-fade').evaluate(el => getComputedStyle(el).backgroundImage), /linear-gradient/, 'Reproduce the actual footer fade');
    for (const theme of ['light', 'dark']) {
      await page.locator('html').evaluate((el, theme) => el.dataset.theme = theme, theme);
      await page.evaluate(script);
      assert.equal(await page.locator('#bottom-fade').evaluate(el => getComputedStyle(el).backgroundImage), 'none');
      assert.equal(await page.locator('#new-bottom-fade').evaluate(el => getComputedStyle(el).backgroundImage), 'none');
      assert.equal(await page.locator('#current-bottom-fade').evaluate(el => getComputedStyle(el).backgroundImage), 'none');
      assert.equal(await page.locator('#footer-backdrop').evaluate(el => getComputedStyle(el).backgroundColor), 'rgba(0, 0, 0, 0)');
      assert.equal(await page.locator('[data-composer-layout]').evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(255, 255, 255)');
      assert.equal(await page.locator(`.${fade}`).evaluate(el => getComputedStyle(el).backgroundImage), 'none');
      assert.equal(await pseudoBackground(), 'rgba(0, 0, 0, 0)');
      for (const selector of ['[data-app-shell-frame]', 'main', 'aside', 'nav', 'header']) {
        assert.equal(await page.locator(selector).evaluate(el => getComputedStyle(el).backgroundColor), 'rgba(0, 0, 0, 0)', selector);
      }
      assert.equal(await page.locator('#codex-background-layer').evaluate(el => getComputedStyle(el).opacity), '0.42');
      await page.evaluate(() => document.querySelector('#click-test').onclick = () => document.body.dataset.clicked = 'yes');
      await page.locator('#click-test').click();
      assert.equal(await page.locator('body').getAttribute('data-clicked'), 'yes');
    }
    await page.evaluate(script);
    assert.equal(await page.locator('#codex-background-layer').count(), 1);
    assert.deepEqual(await page.evaluate(probe), { active: true });
    await page.locator('#codex-background-layer').evaluate(el => el.remove());
    assert.deepEqual(await page.evaluate(probe), { ready: false });
    await page.evaluate(script);
    assert.equal(await page.locator('#codex-background-layer').count(), 1, 'Restore the layer after page remount');
    await page.evaluate(clear);
    assert.deepEqual(await page.evaluate(probe), { active: false });
    assert.equal(await page.locator('#codex-background-layer').count(), 0);
    assert.match(await page.locator('#new-bottom-fade').evaluate(el => getComputedStyle(el).backgroundImage), /linear-gradient/, 'Clear restores the native footer fade');
    assert.match(await page.locator('#current-bottom-fade').evaluate(el => getComputedStyle(el).backgroundImage), /linear-gradient/);
    assert.match(await page.locator(`.${fade}`).evaluate(el => getComputedStyle(el).backgroundImage), /linear-gradient/);
    assert.notEqual(await pseudoBackground(), 'rgba(0, 0, 0, 0)', 'Clear restores app styling');
    const frame = page.locator('[data-app-shell-frame]');
    await frame.evaluate(el => {
      el.innerHTML = '<nav data-app-navigation-rail><button>Menu</button></nav><header data-app-shell-titlebar>Title</header><div id="message">Message</div><div id="composer">Input</div>';
    });
    await page.addStyleTag({ content: '[data-app-shell-frame]{--thread-content-max-width:48rem}[data-app-navigation-rail]{width:52px}[data-app-shell-titlebar]{height:44px}#message,#composer{width:100%;max-width:var(--thread-content-max-width)}' });
    const sizes = () => page.evaluate(() => ['[data-app-navigation-rail]', '[data-app-shell-titlebar]', '#message', '#composer'].map((s,i) => {const r=document.querySelector(s).getBoundingClientRect();return i===1?r.height:r.width}));
    const originalSizes = await sizes();
    const compact = execFileSync(binary, ['--print-injection-script', '--compact', '--clear'], { encoding: 'utf8' });
    await page.evaluate(compact);
    assert.deepEqual(await sizes(), [26,22,1152,1152]);
    await page.evaluate(compact);
    assert.deepEqual(await sizes(), [26,22,1152,1152], 'Reapply must not compound scaling');
    await page.locator('[data-app-navigation-rail] button').click();
    await page.evaluate(clear);
    assert.deepEqual(await sizes(), originalSizes, '100% restores original layout');
    // The reserved space must collapse too, including with no background selected.
    await frame.evaluate(el => el.insertAdjacentHTML('beforeend', '<aside id="threads">Threads</aside><div data-app-shell-main-titlebar>Header</div><div data-app-shell-tab-row>Tabs</div><button id="restore-test">Content action</button><div id="reserved-space"></div>'));
    await page.addStyleTag({ content: '[data-app-shell-frame]{--app-shell-navigation-rail-width:52px;--height-titlebar:44px;--app-shell-titlebar-height:var(--height-titlebar)}#reserved-space{margin-left:var(--app-shell-navigation-rail-width);margin-top:var(--app-shell-titlebar-height)}' });
    assert(layoutClass && contentFrame);
    await frame.evaluate((el, { layoutClass, contentFrame, workspace }) => el.insertAdjacentHTML('beforeend', `<div class="${layoutClass}" data-app-shell-application-menu-header style="--sidebar-navigation-header-height:52px;--app-shell-main-content-frame-top-offset:44px"><div id="hidden-header-gap" class="${workspace}"></div><div id="hidden-frame-gap" class="${contentFrame}"></div></div>`), { layoutClass, contentFrame, workspace });
    for (const args of [['--hide-rail'], ['--hide-top'], ['--hide-rail', '--hide-top']]) {
      const hidden = execFileSync(binary, ['--print-injection-script', '--clear', ...args], { encoding: 'utf8' });
      await page.evaluate(hidden);
      const hideRail = args.includes('--hide-rail'), hideTop = args.includes('--hide-top');
      assert.equal(await page.locator('[data-app-navigation-rail]').isVisible(), !hideRail);
      for (const s of ['[data-app-shell-titlebar]', '[data-app-shell-main-titlebar]', '[data-app-shell-tab-row]']) {
        assert.equal(await page.locator(s).isVisible(), !hideTop, s);
      }
      assert.equal(await page.locator('#threads').isVisible(), true, 'Keep the conversation list');
      assert.deepEqual(await page.locator('#reserved-space').evaluate(el => [getComputedStyle(el).marginLeft, getComputedStyle(el).marginTop]), [hideRail ? '0px' : '52px', hideTop ? '0px' : '44px']);
      assert.equal(await page.locator('#hidden-header-gap').evaluate(el => getComputedStyle(el).paddingTop), hideTop ? '0px' : '52px');
      assert.equal(await page.locator('#hidden-frame-gap').evaluate(el => getComputedStyle(el).marginTop), hideTop ? '0px' : '44px');
      await page.locator('#restore-test').click();
      await page.evaluate(hidden);
      assert.deepEqual(await page.evaluate(probe), { active: false });
    }
    await page.evaluate(clear);
    assert.deepEqual(await sizes(), originalSizes, 'Restore hidden bars and previous dimensions');
    assert.equal(await page.locator('[data-app-shell-tab-row]').isVisible(), true);
    assert.equal(await page.locator('#hidden-header-gap').evaluate(el => getComputedStyle(el).paddingTop), '52px');
    assert.equal(await page.locator('#hidden-frame-gap').evaluate(el => getComputedStyle(el).marginTop), '44px');
    assert.deepEqual(await page.locator('#reserved-space').evaluate(el => [getComputedStyle(el).marginLeft, getComputedStyle(el).marginTop]), ['52px', '44px']);
    console.log('layout test passed: actual app CSS, light/dark, opacity, clicks, reapply, clear');
  } finally {
    await browser.close();
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
