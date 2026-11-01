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
const merged = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/partial-input.json'], {encoding:'utf8'});
assert.equal(merged.status, 0, merged.stderr);
const mergedReport = JSON.parse(merged.stdout);
const browserMerged = JSON.parse(moontile_process(readFileSync(new URL('../examples/partial-input.json', import.meta.url), 'utf8')));
assert.deepEqual(browserMerged, mergedReport);
assert.equal(mergedReport.kept.length, 1);
assert.deepEqual(mergedReport.kept[0].box, {x1:45,y1:10,x2:70,y2:30});
assert.equal(mergedReport.suppressed[0].suppressed_id, 2);
const mergedCoco = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/partial-input.json','--coco-map','examples/coco-map.json'], {encoding:'utf8'});
assert.equal(mergedCoco.status, 0, mergedCoco.stderr);
assert.deepEqual(JSON.parse(mergedCoco.stdout), [{image_id:1,category_id:7,bbox:[45,10,25,20],score:0.95}]);
const mergedTracking = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/partial-input.json','--mbmot-frame','1'], {encoding:'utf8'});
assert.equal(mergedTracking.status, 0, mergedTracking.stderr);
assert.deepEqual(JSON.parse(mergedTracking.stdout), {frame:1,detections:[{xyxy:[45,10,70,30],score:0.95,class_id:0}]});
const transformedSource = readFileSync(new URL('../examples/model-input.json', import.meta.url), 'utf8');
assert.deepEqual(JSON.parse(moontile_process(transformedSource)), mergedReport);
for (const extra of [[], ['--coco-map', 'examples/coco-map.json'], ['--mbmot-frame', '1']]) {
  const transformed = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/model-input.json', ...extra], {encoding:'utf8'});
  const original = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/partial-input.json', ...extra], {encoding:'utf8'});
  assert.equal(transformed.status, 0, transformed.stderr);
  assert.equal(original.status, 0, original.stderr);
  assert.deepEqual(JSON.parse(transformed.stdout), JSON.parse(original.stdout));
}
for (const frame of [1, 2]) {
  const tracking = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json','--mbmot-frame',String(frame)], {encoding:'utf8'});
  assert.equal(tracking.status, 0, tracking.stderr);
  assert.deepEqual(JSON.parse(tracking.stdout), {frame, detections:[
    {xyxy:[45,10,58,30], score:0.95, class_id:0},
    {xyxy:[70,20,80,40], score:0.8, class_id:1},
  ]});
}
for (const frame of ['0', '-1', '1.5', '2147483648', 'not-a-frame']) {
  const bad = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json','--mbmot-frame',frame], {encoding:'utf8'});
  assert.notEqual(bad.status, 0);
  assert.equal(bad.stdout, '');
  assert.match(bad.stderr, /frame must/);
}
console.log('Browser and native JSON outputs agree.');
