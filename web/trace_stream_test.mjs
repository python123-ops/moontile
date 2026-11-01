import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn, spawnSync} from 'node:child_process';
import {createInterface} from 'node:readline';
import {moontile_process} from '../_build/site/moontile.mjs';

const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
const args = ['run','cmd/main','--target','native','--','--trace-stream'];
const lines = readFileSync(new URL('../examples/stream.ndjson', import.meta.url), 'utf8').trim().split(/\r?\n/);
const child = spawn(moon, args, {stdio:['pipe','pipe','pipe']});
const output = createInterface({input:child.stdout});
let stderr = '';
child.stderr.setEncoding('utf8');
child.stderr.on('data', chunk => { stderr += chunk; });
const closed = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
function nextLine() {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { child.kill(); reject(new Error('trace stream did not emit before EOF')); }, 15000);
    output.once('line', line => { clearTimeout(timeout); resolve(line); });
    child.once('error', error => { clearTimeout(timeout); reject(error); });
  });
}
for (const line of lines) {
  const waiting = nextLine();
  child.stdin.write(line + '\n');
  const actual = JSON.parse(await waiting), source = JSON.parse(line);
  assert.deepEqual(actual, {frame:source.frame, result:JSON.parse(moontile_process(JSON.stringify(source.input)))});
}
child.stdin.end();
assert.equal(await closed, 0, stderr);
const frame = JSON.parse(lines[0]);
const invalid = structuredClone(frame);
invalid.frame = 2;
invalid.input.tiles[1].detections[0].image_id = 2;
const rejected = spawnSync(moon, args, {encoding:'utf8', input:lines[0] + '\n' + JSON.stringify(invalid) + '\n'});
assert.notEqual(rejected.status, 0);
assert.equal(rejected.stdout.trim().split(/\r?\n/).length, 1);
assert.match(rejected.stderr, /line 2: one frame cannot contain multiple image IDs/);
const transformed = JSON.parse(readFileSync(new URL('../examples/model-input.json', import.meta.url), 'utf8'));
const result = spawnSync(moon, args, {encoding:'utf8', input:JSON.stringify({frame:1,input:transformed})});
assert.equal(result.status, 0, result.stderr);
const trace = JSON.parse(result.stdout);
assert.deepEqual(trace.result.kept[0].box, {x1:45,y1:10,x2:70,y2:30});
assert.equal(trace.result.suppressed[0].suppressed_id, 2);
console.log('Trace stream emits complete, attributed frames before EOF.');
