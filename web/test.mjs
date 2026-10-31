import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {moontile_process} from '../_build/site/moontile.mjs';
const source = readFileSync(new URL('../examples/input.json', import.meta.url), 'utf8');
const browser = JSON.parse(moontile_process(source));
const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
const native = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json'], {encoding:'utf8'});
assert.equal(native.status, 0, native.stderr);
assert.deepEqual(browser, JSON.parse(native.stdout));
assert.equal(browser.kept.length, 2);
assert.equal(browser.suppressed[0].suppressed_id, 2);
assert.ok(JSON.parse(moontile_process('{')).error);
const coco = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json','--coco-map','examples/coco-map.json'], {encoding:'utf8'});
assert.equal(coco.status, 0, coco.stderr);
assert.deepEqual(JSON.parse(coco.stdout), [
  {image_id:1, category_id:7, bbox:[45,10,13,20], score:0.95},
  {image_id:1, category_id:42, bbox:[70,20,10,20], score:0.8},
]);
const missingMap = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json','--coco-map','examples/missing-map.json'], {encoding:'utf8'});
assert.notEqual(missingMap.status, 0);
assert.equal(missingMap.stdout, '');
assert.match(missingMap.stderr, /cannot read UTF-8 mapping/);
const invalidMap = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json','--coco-map','examples/input.json'], {encoding:'utf8'});
assert.notEqual(invalidMap.status, 0);
assert.equal(invalidMap.stdout, '');
assert.match(invalidMap.stderr, /invalid mapping fields/);
console.log('Browser and native JSON outputs agree.');
