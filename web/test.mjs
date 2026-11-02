import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {moontile_process, moontile_plan, moontile_inspect} from '../_build/site/moontile.mjs';
const source = readFileSync(new URL('../examples/input.json', import.meta.url), 'utf8');
const browser = JSON.parse(moontile_process(source));
const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
const planSource = readFileSync(new URL('../examples/plan.json', import.meta.url), 'utf8');
const plan = JSON.parse(moontile_plan(planSource));
const nativePlan = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/plan.json','--plan'], {encoding:'utf8'});
assert.equal(nativePlan.status, 0, nativePlan.stderr);
assert.deepEqual(plan, JSON.parse(nativePlan.stdout));
assert.deepEqual(plan.tiles, [{id:0,x:0,y:0,width:60,height:60},{id:1,x:40,y:0,width:60,height:60}]);
assert.ok(JSON.parse(moontile_plan('{')).error);
assert.match(JSON.parse(moontile_plan(JSON.stringify({image_width:1001,image_height:1000,tile_width:1,tile_height:1,overlap_x:0,overlap_y:0}))).error, /tile count exceeds 1000000/);
const invalidPlan = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json','--plan'], {encoding:'utf8'});
assert.notEqual(invalidPlan.status, 0);
assert.equal(invalidPlan.stdout, '');
assert.match(invalidPlan.stderr, /invalid planning fields/);
const native = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/input.json'], {encoding:'utf8'});
assert.equal(native.status, 0, native.stderr);
assert.deepEqual(browser, JSON.parse(native.stdout));
assert.equal(browser.kept.length, 2);
assert.equal(browser.suppressed[0].suppressed_id, 2);
assert.ok(JSON.parse(moontile_process('{')).error);
const completeSource = readFileSync(new URL('../examples/complete-input.json', import.meta.url), 'utf8');
const completeBrowser = JSON.parse(moontile_process(completeSource));
const completeNative = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/complete-input.json'], {encoding:'utf8'});
assert.equal(completeNative.status, 0, completeNative.stderr);
assert.deepEqual(completeBrowser, browser);
assert.deepEqual(completeBrowser, JSON.parse(completeNative.stdout));
const missingTile = JSON.parse(completeSource);
missingTile.tiles.pop();
assert.match(JSON.parse(moontile_process(JSON.stringify(missingTile))).error, /tile count does not match grid/);
const clippedSource = readFileSync(new URL('../examples/clipped-input.json', import.meta.url), 'utf8');
const clippedBrowser = JSON.parse(moontile_process(clippedSource));
const clippedNative = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/clipped-input.json'], {encoding:'utf8'});
assert.equal(clippedNative.status, 0, clippedNative.stderr);
assert.deepEqual(clippedBrowser, JSON.parse(clippedNative.stdout));
assert.deepEqual(clippedBrowser.restored[0].box, {x1:40,y1:20,x2:100,y2:50});
const rejectedClip = JSON.parse(clippedSource);
rejectedClip.tiles[0].clip_local = false;
assert.ok(JSON.parse(moontile_process(JSON.stringify(rejectedClip))).error);
const fractionalId = JSON.parse(source);
fractionalId.tiles[0].detections[0].class_id = 0.5;
assert.match(JSON.parse(moontile_process(JSON.stringify(fractionalId))).error, /IDs must be integers/);
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
const plannedInput = JSON.parse(readFileSync(new URL('../examples/partial-input.json', import.meta.url), 'utf8'));
assert.deepEqual(plannedInput.tiles.map(group => group.tile), plan.tiles);
plannedInput.tiles = plan.tiles.map((tile, i) => ({tile, detections:plannedInput.tiles[i].detections}));
assert.deepEqual(JSON.parse(moontile_process(JSON.stringify(plannedInput))), mergedReport);
const consumer = spawnSync(process.execPath, ['examples/plan-consumer.mjs'], {encoding:'utf8'});
assert.equal(consumer.status, 0, consumer.stderr);
assert.deepEqual(JSON.parse(consumer.stdout), mergedReport);
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
const formatsSource = readFileSync(new URL('../examples/formats-input.json', import.meta.url), 'utf8');
assert.deepEqual(JSON.parse(moontile_process(formatsSource)), mergedReport);
for (const extra of [[], ['--coco-map', 'examples/coco-map.json'], ['--mbmot-frame', '1']]) {
  const transformed = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/model-input.json', ...extra], {encoding:'utf8'});
  const original = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/partial-input.json', ...extra], {encoding:'utf8'});
  assert.equal(transformed.status, 0, transformed.stderr);
  assert.equal(original.status, 0, original.stderr);
  assert.deepEqual(JSON.parse(transformed.stdout), JSON.parse(original.stdout));
  const formats = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/formats-input.json', ...extra], {encoding:'utf8'});
  assert.equal(formats.status, 0, formats.stderr);
  assert.deepEqual(JSON.parse(formats.stdout), JSON.parse(original.stdout));
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

const completeInspection = JSON.parse(moontile_inspect(completeSource));
assert.equal(completeInspection.complete, true);
assert.equal(completeInspection.expected_tiles, 2);
const incompleteInspection = JSON.parse(moontile_inspect(JSON.stringify(missingTile)));
assert.equal(incompleteInspection.complete, false);
assert.deepEqual(incompleteInspection.missing_ids, [1]);
const nativeInspection = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/complete-input.json','--inspect-grid'], {encoding:'utf8'});
assert.equal(nativeInspection.status, 0, nativeInspection.stderr);
assert.deepEqual(JSON.parse(nativeInspection.stdout), completeInspection);
assert.match(JSON.parse(moontile_inspect(source)).error, /tile_plan is required/);
for (const limit of ['-1','10001','1.5','no']) {
  const bad = spawnSync(moon, ['run','cmd/main','--target','native','--','examples/complete-input.json','--inspect-grid',limit], {encoding:'utf8'});
  assert.notEqual(bad.status, 0);
  assert.equal(bad.stdout, '');
  assert.match(bad.stderr, /max_reported/);
}

const brokenGrid = JSON.parse(completeSource);
brokenGrid.tiles.pop();
brokenGrid.tiles[0].tile.width--;
brokenGrid.tiles[0].detections = [];
brokenGrid.tiles.push({tile:{id:7,x:0,y:0,width:1,height:1},detections:[]});
const tempDir = mkdtempSync(join(tmpdir(), 'moontile-inspect-'));
try {
  const filename = join(tempDir, 'input.json');
  writeFileSync(filename, JSON.stringify(brokenGrid));
  const expected = JSON.parse(moontile_inspect(JSON.stringify(brokenGrid)));
  assert.deepEqual([expected.missing_count,expected.mismatched_count,expected.unexpected_count], [1,1,1]);
  assert.deepEqual([expected.missing_ids,expected.mismatched_ids,expected.unexpected_ids], [[1],[0],[7]]);
  for (const limit of ['0','1','100']) {
    const actual = spawnSync(moon, ['run','cmd/main','--target','native','--',filename,'--inspect-grid',limit], {encoding:'utf8'});
    assert.equal(actual.status, 0, actual.stderr);
    const report = JSON.parse(actual.stdout);
    assert.deepEqual([report.missing_count,report.mismatched_count,report.unexpected_count], [1,1,1]);
    assert.deepEqual(report.missing_ids, limit === '0' ? [] : [1]);
    if (limit !== '0') assert.deepEqual(report, expected);
  }
  const duplicate = JSON.parse(completeSource);
  duplicate.tiles.push(duplicate.tiles[0]);
  writeFileSync(filename, JSON.stringify(duplicate));
  const invalid = spawnSync(moon, ['run','cmd/main','--target','native','--',filename,'--inspect-grid'], {encoding:'utf8'});
  assert.notEqual(invalid.status, 0);
  assert.equal(invalid.stdout, '');
  assert.ok(JSON.parse(moontile_inspect(JSON.stringify(duplicate))).error);
  const mixed = JSON.parse(completeSource);
  mixed.tiles[1].detections[0].image_id = 2;
  const mixedReport = JSON.parse(moontile_inspect(JSON.stringify(mixed)));
  assert.equal(mixedReport.mixed_images, true);
  assert.equal(mixedReport.complete, false);
} finally { rmSync(tempDir, {recursive:true,force:true}); }
