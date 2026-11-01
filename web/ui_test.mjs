import assert from 'node:assert/strict';

// Minimal DOM harness: exercise the actual built browser module and MoonBit JS.
class Element {
  constructor(value='') { this.value=value; this.children=[]; this.listeners={}; this.attributes={}; this.disabled=false; this.textContent=''; }
  addEventListener(type, callback) { this.listeners[type]=callback; }
  dispatch(type) { this.listeners[type]?.({preventDefault(){}}); }
  setAttribute(key, value) { this.attributes[key]=String(value); }
  append(child) { this.children.push(child); }
  replaceChildren() { this.children=[]; }
  click() { downloads.push({name:this.download, url:this.href}); }
}
const defaults = {'image-width':'100','image-height':'60','tile-width':'60','tile-height':'60','overlap-x':'20','overlap-y':'0'};
const ids = ['input','canvas','report','merge-status','plan-canvas','plan-status','use-plan','plan-form','run','background-file','background-status','clear-background','input-file','file-status','save-input','save-result',...Object.keys(defaults)];
const elements = Object.fromEntries(ids.map(id => [id, new Element(defaults[id] ?? '')]));
const imageFiles = new Map(), revoked = [];
const downloads = [];
let urlId = 0;
URL.createObjectURL = file => { const url = `blob:test-${++urlId}`; imageFiles.set(url, file); return url; };
URL.revokeObjectURL = url => revoked.push(url);
globalThis.Image = class {
  set src(url) {
    const file = imageFiles.get(url);
    this.naturalWidth = file.width; this.naturalHeight = file.height;
    queueMicrotask(() => file.invalid ? this.onerror() : this.onload());
  }
};
globalThis.window = {addEventListener() {}};
globalThis.document = {
  querySelector(selector) { return elements[selector.slice(1)]; },
  createElementNS(_namespace, name) { const node = new Element(); node.tagName=name; return node; },
  createElement(name) { const node = new Element(); node.tagName=name; return node; },
};
await import('../_build/site/app.mjs');
const e = id => elements[id];
assert.match(e('plan-status').textContent, /2 个切片/);
assert.equal(e('plan-canvas').children.filter(n => n.tagName === 'rect').length, 2);
assert.deepEqual(e('plan-canvas').children.filter(n => n.tagName === 'text').map(n => n.textContent), ['0','1']);
assert.equal(JSON.parse(e('report').textContent).kept.length, 1);
const original = e('input').value;
e('background-file').files = [{name:'sample.png',type:'image/png',width:100,height:60}];
e('background-file').dispatch('change');
await Promise.resolve();
assert.match(e('background-status').textContent, /sample.png.*100 × 60/);
assert.equal(e('plan-canvas').children[0].tagName, 'image');
assert.equal(e('canvas').children[0].tagName, 'image');
assert.equal(e('input').value, original);
assert.equal(e('clear-background').disabled, false);
e('background-file').files = [{name:'other.webp',type:'image/webp',width:30,height:20}];
e('background-file').dispatch('change');
await Promise.resolve();
assert.match(e('plan-status').textContent, /尺寸与规划不一致/);
assert.match(e('merge-status').textContent, /尺寸与预测输入不一致/);
assert.notEqual(e('plan-canvas').children[0].tagName, 'image');
assert.notEqual(e('canvas').children[0].tagName, 'image');
assert.ok(revoked.includes('blob:test-1'));
e('clear-background').dispatch('click');
assert.match(e('background-status').textContent, /未选择/);
assert.equal(e('clear-background').disabled, true);
assert.ok(revoked.includes('blob:test-2'));
e('background-file').files = [{name:'invalid.svg',type:'image/svg+xml',width:100,height:60}];
e('background-file').dispatch('change');
assert.match(e('background-status').textContent, /请选择/);
e('background-file').files = [{name:'old.jpg',type:'image/jpeg',width:30,height:20}];
e('background-file').dispatch('change');
e('background-file').files = [{name:'new.jpg',type:'image/jpeg',width:100,height:60}];
e('background-file').dispatch('change');
await Promise.resolve();
assert.match(e('background-status').textContent, /new.jpg/);
assert.equal(e('plan-canvas').children[0].tagName, 'image');
assert.ok(revoked.includes('blob:test-3'));
e('background-file').files = [{name:'broken.png',type:'image/png',width:0,height:0,invalid:true}];
e('background-file').dispatch('change');
await Promise.resolve();
assert.match(e('background-status').textContent, /读取失败/);
assert.equal(e('input').value, original);
const imported = JSON.parse(original);
imported.tiles[0].detections[0].score = 0.97;
const importedText = JSON.stringify(imported);
e('input-file').files = [{name:'prediction.json',text:async () => importedText}];
e('input-file').dispatch('change');
await Promise.resolve();
assert.equal(e('input').value, importedText);
assert.match(e('file-status').textContent, /已导入并处理 prediction.json/);
assert.equal(JSON.parse(e('report').textContent).kept[0].score, 0.97);
e('save-input').dispatch('click');
assert.equal(downloads.at(-1).name, 'moontile-input.json');
assert.equal(await imageFiles.get(downloads.at(-1).url).text(), importedText);
e('save-result').dispatch('click');
assert.equal(downloads.at(-1).name, 'moontile-result.json');
assert.equal(JSON.parse(await imageFiles.get(downloads.at(-1).url).text()).kept[0].score, 0.97);
const previousReport = e('report').textContent;
e('input-file').files = [{name:'bad.json',text:async () => '{'}];
e('input-file').dispatch('change');
await Promise.resolve();
assert.match(e('file-status').textContent, /导入失败/);
assert.equal(e('input').value, importedText);
assert.equal(e('report').textContent, previousReport);
e('input-file').files = [{name:'fields.json',text:async () => '{}'}];
e('input-file').dispatch('change');
await Promise.resolve();
assert.match(e('file-status').textContent, /导入失败/);
assert.equal(e('input').value, importedText);
let finishRead;
e('input-file').files = [{name:'slow.json',text:() => new Promise(resolve => { finishRead=resolve; })}];
e('input-file').dispatch('change');
e('input').value = original;
e('input').dispatch('input');
finishRead(importedText);
await Promise.resolve();
assert.match(e('file-status').textContent, /读取期间输入已变化/);
assert.equal(e('input').value, original);
assert.equal(e('save-result').disabled, true);
e('run').dispatch('click');
assert.equal(e('save-result').disabled, false);
let finishOld;
e('input-file').files = [{name:'old.json',text:() => new Promise(resolve => { finishOld=resolve; })}];
e('input-file').dispatch('change');
e('input-file').files = [{name:'new.json',text:async () => importedText}];
e('input-file').dispatch('change');
await Promise.resolve();
finishOld(original);
await Promise.resolve();
assert.equal(e('input').value, importedText);
assert.match(e('file-status').textContent, /new.json/);
e('input').value = original;
e('input').dispatch('input');
e('run').dispatch('click');
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
e('input').dispatch('input');
assert.match(e('report').textContent, /输入已修改/);
assert.equal(e('canvas').children.length, 0);
e('input').value = '{bad'; e('run').dispatch('click');
assert.match(e('report').textContent, /处理失败/);
assert.equal(e('canvas').children.length, 0);
const downloadCount = downloads.length;
e('save-input').dispatch('click');
assert.equal(downloads.length, downloadCount);
assert.match(e('file-status').textContent, /无法下载输入/);
assert.equal(e('save-result').disabled, true);
e('image-width').value='51'; e('image-height').value='21';
e('tile-width').value='1'; e('tile-height').value='1';
e('overlap-y').value='0'; e('plan-form').dispatch('submit');
assert.match(e('plan-status').textContent, /1071 个切片.*前 1000 个/);
assert.equal(e('plan-canvas').children.length, 1000);
e('use-plan').dispatch('click');
assert.equal(JSON.parse(e('input').value).tiles.length, 1071);
assert.equal(e('canvas').children.length, 1000);
assert.match(e('merge-status').textContent, /前 1000 个切片/);
await new Promise(resolve => setTimeout(resolve, 0));
assert.ok(downloads.every(item => revoked.includes(item.url)));
console.log('Browser planning and merge interactions pass.');
