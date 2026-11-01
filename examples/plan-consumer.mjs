// A synthetic detector stand-in showing a non-MoonBit end-to-end integration.
import {spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const moon = process.platform === 'win32' ? 'moon.exe' : 'moon';
function run(...args) {
  const result = spawnSync(moon, ['run', 'cmd/main', '--target', 'native', '--', ...args], {cwd:root, encoding:'utf8'});
  if (result.status !== 0) throw new Error(result.stderr || String(result.error));
  return JSON.parse(result.stdout);
}
const work = mkdtempSync(path.join(tmpdir(), 'moontile-consumer-'));
try {
  const plan = run('examples/plan.json', '--plan');
  // Replace these synthetic boxes with the detector's tile-local predictions.
  const fixture = JSON.parse(readFileSync(path.join(root, 'examples/partial-input.json'), 'utf8'));
  const request = {...fixture, image_width:plan.image_width, image_height:plan.image_height,
    tiles:plan.tiles.map((tile, i) => ({tile, detections:fixture.tiles[i].detections}))};
  const input = path.join(work, 'predictions.json');
  writeFileSync(input, JSON.stringify(request));
  console.log(JSON.stringify(run(input)));
} finally {
  rmSync(work, {recursive:true, force:true});
}
