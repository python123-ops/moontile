import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn, spawnSync} from 'node:child_process';
import {createInterface} from 'node:readline';

const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
const lines = readFileSync(new URL('../examples/stream.ndjson', import.meta.url), 'utf8').trim().split(/\r?\n/);
const child = spawn(moon, ['run','cmd/main','--target','native','--','--mbmot-stream'], {stdio:['pipe','pipe','pipe']});
const output = createInterface({input:child.stdout});
const seen = [];
let errors = '';
output.on('line', line => seen.push(line));
child.stderr.setEncoding('utf8');
child.stderr.on('data', chunk => { errors += chunk; });
const closed = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
function nextLine() {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { child.kill(); reject(new Error('stream did not emit a frame before EOF')); }, 15000);
    output.once('line', line => { clearTimeout(timeout); resolve(line); });
    child.once('error', error => { clearTimeout(timeout); reject(error); });
  });
}
// Each frame must arrive while stdin is still open, not only after EOF.
let pending = nextLine();
child.stdin.write(lines[0] + '\n');
const first = JSON.parse(await pending);
assert.equal(first.frame, 1);
assert.equal(first.detections.length, 1);
pending = nextLine();
child.stdin.write(lines[1] + '\n');
assert.equal(JSON.parse(await pending).frame, 2);
// Duplicate frame causes a nonzero exit without writing a partial third line.
child.stdin.end(lines[1] + '\n');
assert.notEqual(await closed, 0);
assert.equal(seen.length, 2);
assert.match(errors, /line 3: frame must increase: previous 2, received 2/);
const invalid = spawnSync(moon, ['run','cmd/main','--target','native','--','--mbmot-stream'],
  {encoding:'utf8', input:lines[0] + '\n{bad json}\n'});
assert.notEqual(invalid.status, 0);
assert.equal(invalid.stdout.trim().split(/\r?\n/).length, 1);
assert.match(invalid.stderr, /line 2: invalid JSON/);
const empty = spawnSync(moon, ['run','cmd/main','--target','native','--','--mbmot-stream'],
  {encoding:'utf8', input:''});
assert.equal(empty.status, 0);
assert.equal(empty.stdout, '');
const withoutTrailingNewline = spawnSync(moon, ['run','cmd/main','--target','native','--','--mbmot-stream'],
  {encoding:'utf8', input:lines[0]});
assert.equal(withoutTrailingNewline.status, 0);
assert.equal(JSON.parse(withoutTrailingNewline.stdout).frame, 1);
const partial = JSON.parse(readFileSync(new URL('../examples/partial-input.json', import.meta.url), 'utf8'));
const streamMerged = spawnSync(moon, ['run','cmd/main','--target','native','--','--mbmot-stream'],
  {encoding:'utf8', input:JSON.stringify({frame:1,input:partial}) + '\n'});
assert.equal(streamMerged.status, 0, streamMerged.stderr);
assert.deepEqual(JSON.parse(streamMerged.stdout).detections[0].xyxy, [45,10,70,30]);
const transformed = JSON.parse(readFileSync(new URL('../examples/model-input.json', import.meta.url), 'utf8'));
const transformedStream = spawnSync(moon, ['run','cmd/main','--target','native','--','--mbmot-stream'],
  {encoding:'utf8', input:JSON.stringify({frame:1,input:transformed}) + '\n'});
assert.equal(transformedStream.status, 0, transformedStream.stderr);
assert.deepEqual(JSON.parse(transformedStream.stdout), JSON.parse(streamMerged.stdout));
partial.strategy = 'unknown';
const unsupported = spawnSync(moon, ['run','cmd/main','--target','native','--','--mbmot-stream'],
  {encoding:'utf8', input:JSON.stringify({frame:1,input:partial}) + '\n'});
assert.notEqual(unsupported.status, 0);
assert.equal(unsupported.stdout, '');
assert.match(unsupported.stderr, /strategy must be nms or greedy_nmm/);
console.log('Live stream emits complete frames before EOF and preserves its valid prefix.');
