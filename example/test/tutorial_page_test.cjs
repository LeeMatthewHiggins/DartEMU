const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {test} = require('node:test');
const {runInNewContext} = require('node:vm');

const html = readFileSync(join(__dirname, '../web/index.html'), 'utf8');
const script = readFileSync(join(__dirname, '../web/tutorial/main.js'), 'utf8');
const sessionSource = readFileSync(join(__dirname, '../lib/src/tutorial/tutorial_session.dart'), 'utf8');

// Exercise the actual page script with a minimal DOM and controllable timers.
function page() {
  let focused;
  const nodes = new Map([...html.matchAll(/<[^>]+\bid="([^"]+)"[^>]*>/g)].map(([tag, id]) => [id, {
    disabled: /\sdisabled(?:[\s>])/.test(tag),
    hidden: /\shidden(?:[\s>])/.test(tag),
    src: tag.match(/\bsrc="([^"]*)"/)?.[1],
    textContent: '', handlers: {}, dataset: {},
    addEventListener(type, callback) { this.handlers[type] = callback; },
    setAttribute() {}, focus() { focused = id; }, scrollIntoView() {},
    classList: {add() {}, remove() {}},
  }]));
  const tabs = [...html.matchAll(/id="(tab-[^"]+)"[^>]+data-lesson="([^"]+)"/g)].map(([, id, lesson]) => {
    const tab = nodes.get(id);
    tab.dataset.lesson = lesson;
    return tab;
  });
  const timers = new Map();
  const posted = [];
  const copied = [];
  const listeners = {};
  let nextTimer = 0;
  const frame = nodes.get('emulator');
  frame.contentWindow = {postMessage(message, origin) {
    posted.push({message: {...message}, origin});
  }};
  const window = {
    location: {origin: 'https://example.test', search: '', hash: ''},
    addEventListener(type, callback) { listeners[type] = callback; },
    setTimeout(callback, delay) { timers.set(++nextTimer, {callback, delay}); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
    matchMedia() { return {matches: false}; },
  };
  const examples = JSON.parse(runInNewContext(script + '\nJSON.stringify(examples)', {
    window, URL, URLSearchParams,
    navigator: {clipboard: {async writeText(command) { copied.push(command); }}},
    document: {
      baseURI: 'https://example.test/DartEMU/',
      querySelector(selector) { return nodes.get(selector.slice(1)); },
      querySelectorAll() { return tabs; },
    },
  }));
  return {
    nodes, frame, posted, timers, examples, copied,
    get focused() { return focused; },
    run: nodes.get('run-example'),
    feedback: nodes.get('lesson-feedback'),
    click(id) { return nodes.get(id).handlers.click(); },
    message(data, origin = window.location.origin, source = frame.contentWindow) {
      listeners.message({data, origin, source});
    },
    advance(delay) {
      for (const [id, timer] of timers) {
        if (timer.delay === delay) { timers.delete(id); timer.callback(); }
      }
    },
  };
}

test('only messages from the same-origin emulator can enable controls', () => {
  const p = page();
  p.message({type: 'dartemu:ready'}, 'https://unrelated.test');
  p.message({type: 'dartemu:ready'}, undefined, {});
  p.message(null);
  assert.equal(p.run.disabled, true);
  p.message({type: 'dartemu:ready'});
  assert.equal(p.run.disabled, false);
});

test('a fresh shell prompt clears an ignored request without a stale warning', () => {
  const p = page();
  p.message({type: 'dartemu:ready'});
  p.click('run-example'); // The guest ignores this while a user is typing.
  assert.equal(p.run.disabled, true);
  p.message({type: 'dartemu:ready'}); // Their manual command finishes.
  assert.equal(p.run.disabled, false);
  const feedback = p.feedback.textContent;
  p.advance(3000);
  assert.equal(p.feedback.textContent, feedback);
  p.click('run-example');
  assert.equal(p.posted.length, 2);
});

test('one acknowledged example runs until its matching completion', () => {
  const p = page();
  p.message({type: 'dartemu:ready'});
  p.click('run-example');
  p.click('run-example');
  assert.deepEqual(p.posted, [{
    message: {type: 'dartemu:run', id: 'inspect'}, origin: 'https://example.test',
  }]);
  p.message({type: 'dartemu:running', id: 'inspect'});
  p.message({type: 'dartemu:complete', id: 'files'});
  assert.equal(p.run.disabled, true);
  p.message({type: 'dartemu:complete', id: 'inspect'});
  assert.equal(p.run.disabled, false);
  assert.equal(p.nodes.get('progress').textContent, '1 / 5 explored');
  assert.equal(p.timers.size, 0);
});

test('cancelling restart preserves the guest and lesson progress', () => {
  const p = page();
  p.message({type: 'dartemu:ready'});
  p.click('run-example');
  p.message({type: 'dartemu:running', id: 'inspect'});
  p.message({type: 'dartemu:complete', id: 'inspect'});
  const guest = p.frame.src;
  p.click('restart');
  assert.equal(p.nodes.get('restart-confirmation').hidden, false);
  assert.equal(p.focused, 'cancel-restart');
  p.click('cancel-restart');
  assert.equal(p.nodes.get('restart-confirmation').hidden, true);
  assert.equal(p.focused, 'restart');
  assert.equal(p.frame.src, guest);
  assert.equal(p.nodes.get('progress').textContent, '1 / 5 explored');
  assert.equal(p.run.disabled, false);
  assert.equal(p.timers.size, 0);
});

test('confirmed restart clears progress and timers for pending or running examples', () => {
  for (const acknowledged of [false, true]) {
    const p = page();
    p.message({type: 'dartemu:ready'});
    p.click('run-example');
    p.message({type: 'dartemu:running', id: 'inspect'});
    p.message({type: 'dartemu:complete', id: 'inspect'});
    p.click('run-example');
    if (acknowledged) p.message({type: 'dartemu:running', id: 'inspect'});
    p.click('restart');
    p.click('confirm-restart');
    assert.equal(p.nodes.get('restart-confirmation').hidden, true);
    assert.equal(p.focused, 'restart');
    assert.equal(p.frame.src, 'terminal.html?boot=32&tutorial=1');
    assert.equal(p.nodes.get('progress').textContent, '0 / 5 explored');
    assert.equal(p.run.disabled, true);
    assert.deepEqual([...p.timers.values()].map(timer => timer.delay), [45000]);
    const feedback = p.feedback.textContent;
    p.advance(3000);
    p.advance(15000);
    assert.equal(p.feedback.textContent, feedback);
    p.message({type: 'dartemu:ready'});
    assert.equal(p.run.disabled, false);
    assert.equal(p.timers.size, 0);
  }
});


test('all five displayed lessons match the commands accepted by the guest', () => {
  const p = page();
  const guestCommands = Object.fromEntries([...sessionSource.matchAll(/^    '(\w+)':([\s\S]*?),\n/gm)].map(([, id, expression]) => {
    const literals = expression.match(/r?"""[\s\S]*?"""|r?"(?:[^"\\]|\\.)*"|r?'(?:[^'\\]|\\.)*'/g);
    return [id, literals.map((literal) => {
      const value = literal.startsWith('r') ? literal.slice(1) : literal;
      const quotes = value.startsWith('"""') ? 3 : 1;
      return value.slice(quotes, -quotes);
    }).join('')];
  }));
  assert.deepEqual(p.examples, guestCommands);
  assert.deepEqual(Object.keys(p.examples), ['inspect', 'files', 'pipeline', 'chart', 'script']);
  for (const id of Object.keys(p.examples)) {
    assert.ok(p.nodes.has('tab-' + id));
    assert.ok(p.nodes.has('lesson-' + id));
    assert.equal(/[\r\n]/.test(p.examples[id]), false);
    assert.ok(p.examples[id].length < 4096);
  }
  for (const [, code] of html.matchAll(/<pre(?: [^>]*)?><code>([\s\S]*?)<\/code><\/pre>/g)) {
    const plain = code.replaceAll('&gt;', '>').replaceAll('&lt;', '<').replaceAll('&amp;', '&');
    assert.ok(plain.split('\n').every(line => line.length <= 80));
  }
});

test('next lesson reaches the chart and fractal, then returns to the first', () => {
  const p = page();
  for (const id of ['files', 'pipeline', 'chart', 'script', 'inspect']) {
    p.click('next-lesson');
    assert.equal(p.nodes.get('lesson-' + id).hidden, false);
    assert.equal(p.nodes.get('next-lesson').textContent, id === 'script' ? 'First lesson' : 'Next lesson');
    assert.equal(p.feedback.textContent, '');
  }
});

test('copy sends the complete command for each lesson', async () => {
  const p = page();
  for (const id of Object.keys(p.examples)) {
    p.click('tab-' + id);
    await p.click('copy-example');
    assert.equal(p.copied.at(-1), p.examples[id]);
  }
});
