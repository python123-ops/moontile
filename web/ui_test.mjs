import assert from 'node:assert/strict';

// Minimal DOM harness: exercise the actual built browser module and MoonBit JS.
class Element {
  constructor(value='') { this.value=value; this.children=[]; this.listeners={}; this.attributes={}; this.disabled=false; this.textContent=''; }
  addEventListener(type, callback) { this.listeners[type]=callback; }
  dispatch(type) { this.listeners[type]?.({preventDefault(){}}); }
  setAttribute(key, value) { this.attributes[key]=String(value); }
  append(child) { this.children.push(child); }
  replaceChildren() { this.children=[]; }
}
const defaults = {'image-width':'100','image-height':'60','tile-width':'60','tile-height':'60','overlap-x':'20','overlap-y':'0'};
const ids = ['input','canvas','report','merge-status','plan-canvas','plan-status','use-plan','plan-form','run',...Object.keys(defaults)];
const elements = Object.fromEntries(ids.map(id => [id, new Element(defaults[id] ?? '')]));
globalThis.document = {
  querySelector(selector) { return elements[selector.slice(1)]; },
  createElementNS(_namespace, name) { const node = new Element(); node.tagName=name; return node; },
};
await import('../_build/site/app.mjs');
const e = id => elements[id];
assert.match(e('plan-status').textContent, /2 个切片/);
assert.equal(e('plan-canvas').children.filter(n => n.tagName === 'rect').length, 2);
assert.deepEqual(e('plan-canvas').children.filter(n => n.tagName === 'text').map(n => n.textContent), ['0','1']);
assert.equal(JSON.parse(e('report').textContent).kept.length, 1);
const original = e('input').value;
e('overlap-x').value = '60'; e('overlap-x').dispatch('input');
assert.equal(e('use-plan').disabled, true);
assert.equal(e('plan-canvas').children.length, 0);
e('plan-form').dispatch('submit');
assert.match(e('plan-status').textContent, /规划失败/);
assert.equal(e('input').value, original);
e('overlap-x').value = '0'; e('plan-form').dispatch('submit');
assert.equal(e('use-plan').disabled, false);
e('use-plan').dispatch('click');
const generated = JSON.parse(e('input').value);
assert.equal(generated.tiles.length, 2);
assert.ok(generated.tiles.every(group => group.detections.length === 0));
assert.deepEqual(JSON.parse(e('report').textContent).kept, []);
e('input').value = '{bad'; e('run').dispatch('click');
assert.match(e('report').textContent, /处理失败/);
assert.equal(e('canvas').children.length, 0);
e('image-width').value='51'; e('image-height').value='21';
e('tile-width').value='1'; e('tile-height').value='1';
e('overlap-y').value='0'; e('plan-form').dispatch('submit');
assert.match(e('plan-status').textContent, /1071 个切片.*前 1000 个/);
assert.equal(e('plan-canvas').children.length, 1000);
e('use-plan').dispatch('click');
assert.equal(JSON.parse(e('input').value).tiles.length, 1071);
assert.equal(e('canvas').children.length, 1000);
assert.match(e('merge-status').textContent, /前 1000 个切片/);
console.log('Browser planning and merge interactions pass.');
