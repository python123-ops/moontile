"""Build and measure batch tile replacement, then verify real COCO fixtures.

Run from the repository root: python validation/batch_bench/run.py
The production-scale workload is deterministic synthetic data; real detections
are used separately for equivalence, not represented as a timing benchmark.
"""
import hashlib
import json
import platform
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def digest_lf(path):
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def main():
    subprocess.run(['moon', 'build', 'validation/batch_bench', '--target', 'native', '--release', '--deny-warn'], cwd=ROOT, check=True)
    base = ROOT / '_build/native/release/build/validation/batch_bench/batch_bench'
    binary = base.with_suffix('.exe') if sys.platform == 'win32' else base
    fixture = ROOT / 'validation/scale/predictions.json'
    original = json.loads((ROOT / 'validation/scale/results.json').read_text(encoding='utf8'))
    if digest(fixture) != original['hashes']['raw']:
        raise AssertionError('real fixture hash differs from inference record')
    real = json.loads(subprocess.check_output([str(binary), '--real', str(fixture)], cwd=ROOT, encoding='utf8'))
    if not real['results_identical'] or real['images'] != original['images'] or real['tiles'] != original['tiles'] or real['detections'] != original['predictions_before'] or real['replaced_tiles'] <= 0:
        raise AssertionError('real-fixture comparison incomplete')
    bench = json.loads(subprocess.check_output([str(binary)], cwd=ROOT, encoding='utf8'))
    if not bench['results_identical'] or min(bench['sequential_microseconds'] + bench['batch_microseconds']) <= 0:
        raise AssertionError('benchmark failed or clock returned invalid durations')
    sequential = statistics.median(bench['sequential_microseconds'])
    batch = statistics.median(bench['batch_microseconds'])
    report = {'status': 'passed', 'command': 'python validation/batch_bench/run.py',
              'source_base_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, encoding='utf8').strip(),
              'source_sha256_lf': {str(path.relative_to(ROOT)).replace('\\', '/'): digest_lf(path) for path in (ROOT / 'accumulator.mbt', HERE / 'main.mbt', HERE / 'moon.pkg', Path(__file__).resolve())},
              'binary_sha256': digest(binary), 'real_fixture_sha256': digest(fixture),
              'python': sys.version.split()[0], 'platform': platform.platform(), 'processor': platform.processor(),
              'toolchain': subprocess.check_output(['moon', 'version', '--all'], cwd=ROOT, encoding='utf8').strip(),
              'build': 'native release', 'seed': None, 'real_fixture_equivalence': real,
              'synthetic': {**bench, 'detections': bench['tile_count'] * bench['detections_per_tile'],
                            'sequential_median_microseconds': sequential, 'batch_median_microseconds': batch,
                            'median_speedup': sequential / batch},
              'measurement': 'Monotonic clock measures only 500 sequential replacements versus one 500-tile batch; initialization and merge are excluded. One warmup, five measured pairs with alternating order. Every pair compares all restored boxes, kept boxes and suppression records.',
              'scope': 'Synthetic identical boxes across ten classes. Real COCO data is used for functional equivalence, not performance. Not an end-to-end throughput, memory, or production capacity measurement.'}
    (HERE / 'results.json').write_bytes((json.dumps(report, indent=2) + '\n').encode('utf8'))
    print(json.dumps(report))


if __name__ == '__main__':
    main()
