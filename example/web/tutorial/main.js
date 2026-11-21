// Preserve direct links shared before the tutorial became the landing page.
const query = new URLSearchParams(window.location.search);
if (['boot', 'bundle', 'crt'].some((key) => query.has(key))) {
  window.location.replace(new URL('terminal.html' + window.location.search + window.location.hash, document.baseURI));
}

const examples = {
  "inspect": "uname -m; cat /proc/cpuinfo",
  "files": "mkdir -p /tmp/tutorial; printf '%s\\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' > /tmp/tutorial/weather.txt; cat /tmp/tutorial/weather.txt",
  "pipeline": "printf '%s\\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' | sort -r -k2 | head -n 2",
  "chart": "printf '%s\\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' | while read place temp; do printf '%-7s ' \"$place\"; i=0; while [ \"$i\" -lt \"$temp\" ]; do printf '#'; i=$((i + 1)); done; echo \" $temp C\"; done",
  "script": "limit=16; y=-8; while [ \"$y\" -le 8 ]; do row=; x=-30; while [ \"$x\" -le 10 ]; do a=0; b=0; n=0; while [ \"$((a*a+b*b))\" -le 40000 ] && [ \"$n\" -lt \"$limit\" ]; do t=$(((a*a-b*b)/100+x*7)); b=$((2*a*b/100+y*14)); a=$t; n=$((n+1)); done; case $n in \"$limit\") p=@;; [0-2]) p=' ';; [3-5]) p=.;; [6-9]) p='*';; *) p=+;; esac; row=\"$row$p\"; x=$((x+1)); done; printf '%s\\n' \"$row\"; y=$((y+1)); done"
};
const ids = Object.keys(examples);
const frame = document.querySelector('#emulator');
const run = document.querySelector('#run-example');
const feedback = document.querySelector('#lesson-feedback');
const machineStatus = document.querySelector('#machine-status');
const led = document.querySelector('#terminal-led');
const help = document.querySelector('#boot-help');
const tabs = [...document.querySelectorAll('[role="tab"]')];
const completed = new Set();
let selected = ids[0];
let ready = false;
let active = null;
let pending = null;
let bootTimeout;
let commandTimeout;
let acknowledgementTimeout;

function updateRunButton() {
  run.disabled = !ready || active !== null || pending !== null;
  run.textContent = 'Run example';
}
function selectLesson(id, focus = false) {
  selected = id;
  for (const tab of tabs) {
    const current = tab.dataset.lesson === id;
    tab.setAttribute('aria-selected', String(current));
    tab.tabIndex = current ? 0 : -1;
    document.querySelector('#lesson-' + tab.dataset.lesson).hidden = !current;
    if (current && focus) tab.focus();
  }
  document.querySelector('#next-lesson').textContent = id === ids.at(-1) ? 'First lesson' : 'Next lesson';
  feedback.textContent = '';
}
for (const tab of tabs) {
  tab.addEventListener('click', () => selectLesson(tab.dataset.lesson));
  tab.addEventListener('keydown', (event) => {
    let index = ids.indexOf(selected);
    if (event.key === 'ArrowRight') index = (index + 1) % ids.length;
    else if (event.key === 'ArrowLeft') index = (index + ids.length - 1) % ids.length;
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = ids.length - 1;
    else return;
    event.preventDefault();
    selectLesson(ids[index], true);
  });
}
document.querySelector('#next-lesson').addEventListener('click', () => selectLesson(ids[(ids.indexOf(selected) + 1) % ids.length], true));
run.addEventListener('click', () => {
  if (!ready || active !== null || pending !== null) return;
  pending = selected;
  updateRunButton();
  feedback.textContent = '';
  frame.contentWindow.postMessage({type: 'dartemu:run', id: selected}, window.location.origin);
  acknowledgementTimeout = window.setTimeout(() => {
    pending = null;
    feedback.textContent = 'Finish your command or press Ctrl+C in the terminal, then retry.';
    updateRunButton();
  }, 3000);
  if (window.matchMedia('(max-width: 760px)').matches) {
    document.querySelector('#live-terminal').scrollIntoView({block: 'start', behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'});
  }
});
document.querySelector('#copy-example').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(examples[selected]);
    feedback.textContent = 'Copied.';
  } catch {
    feedback.textContent = 'Clipboard unavailable. Select and copy the command above.';
  }
});
function startBootTimer() {
  window.clearTimeout(bootTimeout);
  bootTimeout = window.setTimeout(() => { help.hidden = false; }, 45000);
}
const restartButton = document.querySelector('#restart');
const restartConfirmation = document.querySelector('#restart-confirmation');
function closeRestartConfirmation() {
  restartConfirmation.hidden = true;
  restartButton.setAttribute('aria-expanded', 'false');
  restartButton.focus();
}
restartButton.addEventListener('click', () => {
  restartConfirmation.hidden = false;
  restartButton.setAttribute('aria-expanded', 'true');
  document.querySelector('#cancel-restart').focus();
});
document.querySelector('#cancel-restart').addEventListener('click', closeRestartConfirmation);
restartConfirmation.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault();
    closeRestartConfirmation();
  }
});
document.querySelector('#confirm-restart').addEventListener('click', () => {
  closeRestartConfirmation();
  ready = false;
  active = null;
  pending = null;
  window.clearTimeout(commandTimeout);
  window.clearTimeout(acknowledgementTimeout);
  completed.clear();
  tabs.forEach((tab) => tab.classList.remove('completed'));
  document.querySelector('#progress').textContent = '0 / ' + ids.length + ' explored';
  machineStatus.textContent = 'Booting a fresh machine…';
  led.className = 'terminal-led';
  help.hidden = true;
  feedback.textContent = '';
  updateRunButton();
  frame.src = 'terminal.html?boot=32&tutorial=1';
  startBootTimer();
});
window.addEventListener('message', (event) => {
  if (event.origin !== window.location.origin || event.source !== frame.contentWindow) return;
  const message = event.data;
  if (!message || typeof message !== 'object') return;
  if (message.type === 'dartemu:ready') {
    pending = null;
    window.clearTimeout(acknowledgementTimeout);
    ready = true;
    window.clearTimeout(bootTimeout);
    help.hidden = true;
    led.className = 'terminal-led ready';
    machineStatus.textContent = 'Linux is ready';
    feedback.textContent = '';
    updateRunButton();
  } else if (message.type === 'dartemu:running' && ids.includes(message.id)) {
    active = message.id;
    pending = null;
    window.clearTimeout(acknowledgementTimeout);
    machineStatus.textContent = 'Running example…';
    feedback.textContent = '';
    updateRunButton();
    commandTimeout = window.setTimeout(() => {
      feedback.textContent = 'Still running. Keep this tab visible, or press Ctrl+C in the terminal to stop.';
    }, active === 'script' ? 45000 : 15000);
  } else if (message.type === 'dartemu:complete' && message.id === active) {
    completed.add(active);
    document.querySelector('#tab-' + active).classList.add('completed');
    document.querySelector('#progress').textContent = completed.size + ' / ' + ids.length + ' explored';
    active = null;
    window.clearTimeout(commandTimeout);
    machineStatus.textContent = 'Linux is ready';
    feedback.textContent = '';
    updateRunButton();
  } else if (message.type === 'dartemu:error') {
    active = null;
    pending = null;
    ready = false;
    window.clearTimeout(commandTimeout);
    window.clearTimeout(acknowledgementTimeout);
    window.clearTimeout(bootTimeout);
    machineStatus.textContent = 'Restart needed';
    led.className = 'terminal-led error';
    help.hidden = false;
    feedback.textContent = typeof message.message === 'string' ? message.message : 'Linux could not start. Select Restart to retry.';
    updateRunButton();
  }
});
startBootTimer();
