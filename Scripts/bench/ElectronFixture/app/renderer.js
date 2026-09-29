// Per-window fixture page: records every input event and effect through the preload
// channel, and answers the main process's state/reset/command requests.
'use strict';
const text = document.getElementById('text');
const button = document.getElementById('button');
const list = document.getElementById('scroll');
let presses = 0;
let commands = 0;

for (let i = 1; i <= 200; i += 1) {
  const row = document.createElement('p');
  row.textContent = `Fixture row ${i}`;
  list.appendChild(row);
}

function send(record) { window.dropyFixture.log(record); }

// Named like the AppKit fixture's event types, so the harness judges both the same way.
const mouseTypes = { 0: 'leftMouse', 2: 'rightMouse' };
window.addEventListener('keydown', (event) => send({ kind: 'event', type: 'keyDown', chars: event.key,
  cmd: event.metaKey, keyCode: event.keyCode }), true);
window.addEventListener('keyup', (event) => send({ kind: 'event', type: 'keyUp', chars: event.key,
  cmd: event.metaKey, keyCode: event.keyCode }), true);
window.addEventListener('mousedown', (event) => send({ kind: 'event', type: `${mouseTypes[event.button] || 'otherMouse'}Down`,
  x: event.clientX, y: event.clientY }), true);
window.addEventListener('mouseup', (event) => send({ kind: 'event', type: `${mouseTypes[event.button] || 'otherMouse'}Up`,
  x: event.clientX, y: event.clientY }), true);
window.addEventListener('wheel', (event) => send({ kind: 'event', type: 'scrollWheel', dy: event.deltaY }),
  { capture: true, passive: true });

text.addEventListener('input', () => send({ kind: 'effect', effect: 'text', length: text.value.length }));
button.addEventListener('click', () => {
  presses += 1;
  send({ kind: 'effect', effect: 'press', count: presses });
});
list.addEventListener('scroll', () => send({ kind: 'effect', effect: 'scroll', offset: Math.round(list.scrollTop) }),
  { passive: true });

window.fixtureState = () => ({
  text: text.value, presses, commands, scroll: Math.round(list.scrollTop),
  firstResponderIsText: document.activeElement === text, documentFocused: document.hasFocus(),
});
window.fixtureReset = () => {
  text.value = '';
  presses = 0;
  commands = 0;
  list.scrollTop = 0;
};
window.fixtureCommand = () => {
  commands += 1;
  send({ kind: 'effect', effect: 'command', count: commands });
};
window.fixtureFocusText = () => text.focus();

// Continuous RGB changes without moving controls, for preview presentation races.
let animation = 0;
window.fixtureAnimate = (enabled) => {
  cancelAnimationFrame(animation);
  if (!enabled) { document.body.style.backgroundColor = ''; return; }
  const tick = (time) => {
    document.body.style.backgroundColor = `rgb(${80 + Math.round(50 * Math.sin(time / 150))}, 120, 160)`;
    animation = requestAnimationFrame(tick);
  };
  animation = requestAnimationFrame(tick);
};
