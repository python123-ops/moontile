import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync, rmSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
const temp = mkdtempSync(join(tmpdir(), 'moontile-files-'));
const invoke = (file, flags=[]) => spawnSync(moon, ['run','cmd/main','--target','native','--',file,...flags], {encoding:'utf8'});
try {
  const source = JSON.parse(readFileSync(new URL('../examples/complete-input.json', import.meta.url), 'utf8'));
  source.note = '🌙';
  const content = JSON.stringify(source);
  const input = join(temp, 'input.json');
  const mapping = join(temp, 'mapping.json');
  const mappingText = JSON.stringify([{class_id:0,category_id:7},{class_id:1,category_id:42}]);
  writeFileSync(input, content);
  writeFileSync(mapping, mappingText);
  const size = Buffer.byteLength(content);
  const cases = [[], ['--inspect-grid'], ['--inspect-grid','0'], ['--mbmot-frame','1'], ['--coco-map',mapping]];
  for (const flags of cases) {
    const baseline = invoke(input, flags);
    const exact = invoke(input, [...flags,'--max-file-bytes',String(size)]);
    assert.equal(baseline.status, 0, baseline.stderr);
    assert.equal(exact.status, 0, exact.stderr);
    assert.equal(exact.stdout, baseline.stdout);
    const short = invoke(input, [...flags,'--max-file-bytes',String(size-1)]);
    assert.equal(short.status, 2);
    assert.equal(short.stdout, '');
    assert.match(short.stderr, /input file byte limit exceeded/);
  }
  const paddedMapping = mappingText + ' '.repeat(size);
  writeFileSync(mapping, paddedMapping);
  const mappingShort = invoke(input, ['--coco-map',mapping,'--max-file-bytes',String(size)]);
  assert.equal(mappingShort.status, 2);
  assert.equal(mappingShort.stdout, '');
  assert.match(mappingShort.stderr, /mapping file byte limit exceeded/);
  const mappingExact = invoke(input, ['--coco-map',mapping,'--max-file-bytes',String(Buffer.byteLength(paddedMapping))]);
  assert.equal(mappingExact.status, 0, mappingExact.stderr);
  const padded = content + ' '.repeat(4096 - size);
  writeFileSync(input, padded);
  assert.equal(Buffer.byteLength(padded), 4096);
  assert.equal(invoke(input, ['--max-file-bytes','4096']).status, 0);
  const blockShort = invoke(input, ['--max-file-bytes','4095']);
  assert.equal(blockShort.status, 2);
  assert.equal(blockShort.stdout, '');
  assert.match(blockShort.stderr, /input file byte limit exceeded/);
  writeFileSync(input, padded + ' ');
  assert.equal(invoke(input, ['--max-file-bytes','4097']).status, 0);
  assert.equal(invoke(input, ['--max-file-bytes','4096']).status, 2);
  writeFileSync(input, Buffer.from([0xff]));
  const invalid = invoke(input, ['--max-file-bytes','1']);
  assert.equal(invalid.status, 2);
  assert.equal(invalid.stdout, '');
  assert.match(invalid.stderr, /cannot read UTF-8 input/);
  const zero = invoke(input, ['--max-file-bytes','0']);
  assert.equal(zero.status, 2);
  assert.match(zero.stderr, /input file byte limit exceeded/);
  writeFileSync(input, '');
  const empty = invoke(input, ['--max-file-bytes','0']);
  assert.equal(empty.status, 2);
  assert.match(empty.stderr, /invalid JSON/);
  const missing = invoke(join(temp,'missing.json'), ['--max-file-bytes','100']);
  assert.equal(missing.status, 2);
  assert.match(missing.stderr, /cannot read UTF-8 input/);
  for (const value of ['-1','1.5','2147483648','no']) {
    const bad = invoke(input, ['--max-file-bytes',value]);
    assert.equal(bad.status, 2);
    assert.equal(bad.stdout, '');
    assert.match(bad.stderr, /max-file-bytes must/);
  }
  const plan = join(temp,'plan.json');
  const planText = readFileSync(new URL('../examples/plan.json', import.meta.url));
  writeFileSync(plan, planText);
  const planResult = invoke(plan, ['--plan','--max-file-bytes',String(planText.length)]);
  assert.equal(planResult.status, 0, planResult.stderr);
  assert.equal(JSON.parse(planResult.stdout).tiles.length, 2);
} finally { rmSync(temp, {recursive:true,force:true}); }
console.log('Bounded file reads cover input, mapping, UTF-8, size boundaries and CLI modes.');
