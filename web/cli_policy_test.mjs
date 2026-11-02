import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';

const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
const input = JSON.parse(readFileSync(new URL('../examples/stream.ndjson', import.meta.url), 'utf8').split(/\r?\n/)[0]);
input.input.note = '🌙';
const line = JSON.stringify(input);
const next = structuredClone(input);
next.frame = 2;
next.input.tiles[0].detections.push({...next.input.tiles[0].detections[0], id:77});
const nextLine = JSON.stringify(next);
const invoke = (mode, options, text) => spawnSync(moon, ['run','cmd/main','--target','native','--',mode,...options], {encoding:'utf8', input:text});
for (const mode of ['--mbmot-stream','--trace-stream']) {
  const original = invoke(mode, [], line + '\n');
  const exact = invoke(mode, ['--policy',String(line.length),'2','2'], line + '\n');
  assert.equal(original.status, 0, original.stderr);
  assert.equal(exact.status, 0, exact.stderr);
  assert.equal(exact.stdout, original.stdout);
  const shortened = invoke(mode, ['--policy',String(line.length-1),'2','2'], line + '\n');
  assert.equal(shortened.status, 2);
  assert.equal(shortened.stdout, '');
  assert.match(shortened.stderr, /line 1: JSON text limit exceeded/);
  const crlf = invoke(mode, ['--policy',String(line.length),'2','2'], line + '\r\n');
  assert.equal(crlf.status, 2);
  assert.match(crlf.stderr, /JSON text limit exceeded/);
  const crlfOk = invoke(mode, ['--policy',String(line.length+1),'2','2'], line + '\r\n');
  assert.equal(crlfOk.status, 0, crlfOk.stderr);
  assert.equal(crlfOk.stdout, original.stdout);
  const rejected = invoke(mode, ['--policy',String(nextLine.length),'2','2'], line + '\n' + nextLine + '\n');
  assert.equal(rejected.status, 2);
  assert.equal(rejected.stdout, original.stdout);
  assert.match(rejected.stderr, /line 2: detection limit exceeded/);
  const tileLimit = invoke(mode, ['--policy',String(line.length),'1','2'], line + '\n');
  assert.equal(tileLimit.status, 2);
  assert.equal(tileLimit.stdout, '');
  assert.match(tileLimit.stderr, /line 1: tile limit exceeded/);
  for (const opts of [['--policy','-1','2','2'],['--policy','2.5','2','2'],['--policy','2147483648','2','2'],['--policy','1','2']]) {
    const bad = invoke(mode, opts, '');
    assert.equal(bad.status, 2);
    assert.equal(bad.stdout, '');
    assert.match(bad.stderr, /policy values|usage:/);
  }
}
console.log('CLI stream policies preserve output and reject over-limit frames.');
