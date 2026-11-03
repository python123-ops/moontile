import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn, spawnSync} from 'node:child_process';

const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
const frame = JSON.parse(readFileSync(new URL('../examples/stream.ndjson', import.meta.url), 'utf8').split(/\r?\n/)[0]);
frame.input.note = '🌙';
const line = JSON.stringify(frame);
const size = Buffer.byteLength(line);
const invoke = (mode, flags, input) => spawnSync(moon, ['run','cmd/main','--target','native','--',mode,...flags], {encoding:'utf8',input});
for (const mode of ['--mbmot-stream','--trace-stream']) {
  const baseline = invoke(mode, [], line + '\n');
  const exact = invoke(mode, ['--max-line-bytes',String(size)], line + '\n');
  assert.equal(baseline.status, 0, baseline.stderr);
  assert.equal(exact.status, 0, exact.stderr);
  assert.equal(exact.stdout, baseline.stdout);
  const eof = invoke(mode, ['--max-line-bytes',String(size)], line);
  assert.equal(eof.status, 0, eof.stderr);
  assert.equal(eof.stdout, baseline.stdout);
  const tooShort = invoke(mode, ['--max-line-bytes',String(size-1)], line + '\n');
  assert.equal(tooShort.status, 2);
  assert.equal(tooShort.stdout, '');
  assert.match(tooShort.stderr, /line 1: line byte limit exceeded/);
  const crlf = invoke(mode, ['--max-line-bytes',String(size)], line + '\r\n');
  assert.equal(crlf.status, 2);
  const crlfOk = invoke(mode, ['--max-line-bytes',String(size+1)], line + '\r\n');
  assert.equal(crlfOk.status, 0, crlfOk.stderr);
  assert.equal(crlfOk.stdout, baseline.stdout);
  const next = JSON.stringify({...frame, frame:2}) + ' ';
  const rejected = invoke(mode, ['--max-line-bytes',String(size)], line + '\n' + next + '\n');
  assert.equal(rejected.status, 2);
  assert.equal(rejected.stdout, baseline.stdout);
  assert.match(rejected.stderr, /line 2: line byte limit exceeded/);
  const badUtf8 = invoke(mode, ['--max-line-bytes','20'], Buffer.from([0xff,0x0a]));
  assert.equal(badUtf8.status, 2);
  assert.equal(badUtf8.stdout, '');
  assert.match(badUtf8.stderr, /line 1: invalid UTF-8/);
  const empty = invoke(mode, ['--max-line-bytes','0'], '');
  assert.equal(empty.status, 0);
  const emptyLine = invoke(mode, ['--max-line-bytes','0'], '\n');
  assert.equal(emptyLine.status, 2);
  assert.match(emptyLine.stderr, /line 1: invalid JSON/);
  for (const flags of [['--max-line-bytes','-1'],['--max-line-bytes','1.2'],['--max-line-bytes','2147483648'],['--max-line-bytes'],['--max-line-bytes','2','--max-line-bytes','3']]) {
    const bad = invoke(mode, flags, '');
    assert.equal(bad.status, 2);
    assert.equal(bad.stdout, '');
    assert.match(bad.stderr, /max-line-bytes|usage:/);
  }
  for (const flags of [
    ['--max-line-bytes',String(size),'--policy',String(line.length),'2','2'],
    ['--policy',String(line.length),'2','2','--max-line-bytes',String(size)],
  ]) {
    const combined = invoke(mode, flags, line + '\n');
    assert.equal(combined.status, 0, combined.stderr);
    assert.equal(combined.stdout, baseline.stdout);
  }
}
// The child must reject an over-limit line even though no LF or EOF was sent.
const child = spawn(moon, ['run','cmd/main','--target','native','--','--mbmot-stream','--max-line-bytes','8'], {stdio:['pipe','pipe','pipe']});
let stderr = '';
child.stderr.setEncoding('utf8'); child.stderr.on('data', chunk => { stderr += chunk; });
const closed = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
child.stdin.write('123456789');
const timer = setTimeout(() => child.kill(), 15000);
assert.equal(await closed, 2);
clearTimeout(timer);
assert.match(stderr, /line 1: line byte limit exceeded/);
// Split the multi-byte input across writes and require output before EOF.
const live = spawn(moon, ['run','cmd/main','--target','native','--','--trace-stream','--max-line-bytes',String(size)], {stdio:['pipe','pipe','pipe']});
let liveOutput = '', liveError = '';
live.stdout.setEncoding('utf8'); live.stdout.on('data', chunk => { liveOutput += chunk; });
live.stderr.setEncoding('utf8'); live.stderr.on('data', chunk => { liveError += chunk; });
const liveClosed = new Promise((resolve, reject) => { live.once('error', reject); live.once('close', resolve); });
const firstData = new Promise((resolve, reject) => {
  const timeout = setTimeout(() => { live.kill(); reject(new Error('live output timed out')); }, 15000);
  live.stdout.once('data', value => { clearTimeout(timeout); resolve(value); });
  live.once('error', reject);
});
for (const byte of Buffer.from(line + '\n')) live.stdin.write(Buffer.from([byte]));
await firstData;
live.stdin.end();
assert.equal(await liveClosed, 0, liveError);
assert.equal(JSON.parse(liveOutput).frame, 1);
console.log('CLI byte limit handles UTF-8, EOF, CRLF, combined policy and live rejection.');
