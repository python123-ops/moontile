"""Measure whole-process peak resident memory and merge time for finish APIs.

Run from the repository root: python validation/memory_scale/run.py
Windows uses sampled PeakWorkingSetSize; Linux reads sampled /proc/PID/status
VmHWM. A short-lived final peak could be missed between sampling and exit.
"""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_sha(path):
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def memory_reader(process):
    if sys.platform == 'win32':
        import ctypes
        from ctypes import wintypes
        class Counters(ctypes.Structure):
            _fields_ = [('cb', wintypes.DWORD), ('page_faults', wintypes.DWORD),
                        ('peak_working_set', ctypes.c_size_t), ('working_set', ctypes.c_size_t),
                        ('peak_paged_pool', ctypes.c_size_t), ('paged_pool', ctypes.c_size_t),
                        ('peak_nonpaged_pool', ctypes.c_size_t), ('nonpaged_pool', ctypes.c_size_t),
                        ('pagefile', ctypes.c_size_t), ('peak_pagefile', ctypes.c_size_t)]
        api = ctypes.WinDLL('psapi', use_last_error=True).GetProcessMemoryInfo
        api.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
        api.restype = wintypes.BOOL
        def read():
            counters = Counters()
            counters.cb = ctypes.sizeof(Counters)
            return counters.peak_working_set if api(process._handle, ctypes.byref(counters), counters.cb) else 0
        return read, 'sampled Windows PeakWorkingSetSize'
    if sys.platform.startswith('linux'):
        status = Path('/proc') / str(process.pid) / 'status'
        def read():
            try:
                for line in status.read_text().splitlines():
                    if line.startswith('VmHWM:'):
                        return int(line.split()[1]) * 1024
            except (FileNotFoundError, ProcessLookupError):
                pass
            return 0
        return read, 'sampled Linux VmHWM'
    raise RuntimeError('memory sampling currently supports Windows and Linux')


def run(binary, count, mode, sample_seconds):
    start = time.perf_counter()
    process = subprocess.Popen([str(binary), str(count), mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    read, method = memory_reader(process)
    peak = 0
    while process.poll() is None:
        peak = max(peak, read())
        time.sleep(sample_seconds)
    elapsed = time.perf_counter() - start
    stdout, stderr = process.communicate()
    if process.returncode:
        raise RuntimeError(stderr.decode('utf8', errors='replace'))
    if not peak:
        raise RuntimeError('could not sample process peak memory')
    result = json.loads(stdout)
    if not result['verified'] or result['count'] != count or result['mode'] != mode:
        raise AssertionError('incomplete output validation')
    return {'merge_microseconds': result['merge_microseconds'], 'process_seconds': elapsed,
            'peak_bytes': peak, 'restored': result['restored'], 'kept': result['kept'],
            'suppressed': result['suppressed']}, method


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--counts', nargs='+', type=int, default=[100000, 300000])
    p.add_argument('--repeat', type=int, default=3)
    p.add_argument('--sample-ms', type=float, default=2)
    p.add_argument('--output', type=Path, default=HERE / 'results.json')
    args = p.parse_args()
    if args.repeat < 1 or args.sample_ms <= 0 or any(n < 10 or n > 1000000 for n in args.counts):
        p.error('counts must be 10..1000000, repeat and sample-ms must be positive')
    subprocess.run(['moon', 'build', 'validation/memory_scale', '--target', 'native', '--release', '--deny-warn'], cwd=ROOT, check=True)
    binary = ROOT / '_build/native/release/build/validation/memory_scale/memory_scale'
    # MoonBit native builds may use the .exe suffix on Linux as well.
    if binary.with_suffix('.exe').is_file():
        binary = binary.with_suffix('.exe')
    measurements = []
    method = ''
    for count in args.counts:
        for mode in ('snapshot', 'take'):
            run(binary, count, mode, args.sample_ms / 1000)
        samples = {'snapshot': [], 'take': []}
        for turn in range(args.repeat):
            modes = ('snapshot', 'take') if turn % 2 == 0 else ('take', 'snapshot')
            for mode in modes:
                sample, method = run(binary, count, mode, args.sample_ms / 1000)
                samples[mode].append(sample)
        if any((s['restored'], s['kept'], s['suppressed']) != (count, 10, count - 10) for a in samples.values() for s in a):
            raise AssertionError('inconsistent output counts')
        summaries = {}
        for mode, items in samples.items():
            summaries[mode] = {'samples': items, 'median_peak_bytes': statistics.median(s['peak_bytes'] for s in items),
                               'median_merge_microseconds': statistics.median(s['merge_microseconds'] for s in items),
                               'median_process_seconds': statistics.median(s['process_seconds'] for s in items)}
        measurements.append({'detections': count, 'modes': summaries})
    report = {'status': 'passed', 'command': 'python validation/memory_scale/run.py', 'counts': args.counts,
              'repeat': args.repeat, 'warmups_per_mode_and_count': 1, 'sample_interval_ms': args.sample_ms,
              'memory_method': method, 'build': 'native release', 'seed': None, 'platform': platform.platform(),
              'python': sys.version.split()[0], 'toolchain': subprocess.check_output(['moon', 'version', '--all'], cwd=ROOT, text=True).strip(),
              'binary_sha256': sha(binary), 'sources_sha256_lf': {str(path.relative_to(ROOT)).replace('\\', '/'): source_sha(path) for path in [ROOT / 'accumulator.mbt', ROOT / 'nms.mbt', HERE / 'main.mbt', HERE / 'moon.pkg', Path(__file__).resolve()]},
              'measurement': 'Separate process per sample; peak memory covers startup, accumulation, merge and verification. Merge clock excludes setup and verification. Samples are alternated; a final short-lived peak can be missed.',
              'scope': 'Synthetic identical boxes in 10 classes, 1000 detections per tile. Each restored record, kept ID and suppression relation is checked. Not representative production throughput or memory.',
              'measurements': measurements}
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
