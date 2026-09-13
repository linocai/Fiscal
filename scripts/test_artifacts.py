#!/usr/bin/env python3
"""Run Apple tests with explicit retention; delete only reviewed, unchanged artifacts."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MEDIA = {'.png', '.jpg', '.jpeg', '.mp4', '.mov', '.heic', '.m4v'}


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    os.replace(temp, path)


def fingerprint(path):
    """Hash content and symlink targets without following links; include root identity."""
    path = Path(path)
    st = path.lstat()
    digest = hashlib.sha256()
    allocated = 0
    logical = 0
    entries = [path]
    if path.is_dir() and not path.is_symlink():
        for directory, dirs, files in os.walk(path, followlinks=False):
            entries.extend(Path(directory) / name for name in dirs + files)
    for item in sorted(set(entries)):
        stat = item.lstat()
        allocated += stat.st_blocks * 512
        digest.update(str(item.relative_to(path) if item != path else '.').encode())
        if item.is_symlink():
            digest.update(b'link:' + os.readlink(item).encode())
        elif item.is_file():
            logical += stat.st_size
            digest.update(b'file:')
            with item.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
        else:
            digest.update(b'dir:')
    return {'sha256': digest.hexdigest(), 'inode': st.st_ino, 'device': st.st_dev,
            'logical_bytes': logical, 'allocated_bytes': allocated}


def contained(path, root):
    return path == root or root in path.parents


def candidate(root, relative):
    path = root / relative
    build = root / 'build'
    if path.is_symlink() or path.absolute() != path.resolve():
        raise ValueError('Candidate or ancestor is a symlink/non-canonical path: ' + relative)
    if path == build or not contained(path, build):
        raise ValueError('Only individual build artifacts may be deleted: ' + relative)
    if not (path.name.endswith('.xcresult') and path.is_dir()) and not (
        path.suffix.lower() in MEDIA and path.is_file()
    ):
        raise ValueError('Not a test result or exported media artifact: ' + relative)
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--', relative])
    if tracked:
        raise ValueError('Tracked files are protected: ' + relative)
    return path


def prepare(root, decisions):
    kept = []
    deletes = []
    for item in decisions.get('keep', []):
        if not item.get('reason'):
            raise ValueError('Retention needs a reason')
        path = root / item['path']
        if not path.exists():
            raise ValueError('Retained path missing: ' + str(path))
        kept.append(dict(item, fingerprint=fingerprint(path)))
    paths = [candidate(root, x['path']) for x in decisions['delete']]
    if len(paths) != len(set(paths)):
        raise ValueError('Duplicate candidates')
    for index, path in enumerate(paths):
        if any(contained(path, other) or contained(other, path) for other in paths[index + 1:]):
            raise ValueError('Overlapping candidates')
        if any(contained(root / k['path'], path) or contained(path, root / k['path']) for k in kept):
            raise ValueError('Candidate overlaps retained evidence')
    for item, path in zip(decisions['delete'], paths):
        if not item.get('reason') or not item.get('evidence'):
            raise ValueError('Deletion requires a reason and surviving evidence')
        evidence = []
        for relative in item['evidence']:
            proof = root / relative
            if not proof.exists() or any(contained(proof.resolve(), p) for p in paths):
                raise ValueError('Evidence is missing or would be deleted: ' + relative)
            evidence.append({'path': relative, 'fingerprint': fingerprint(proof)})
        deletes.append(dict(item, fingerprint=fingerprint(path), evidence=evidence))
    return {'schema': 1, 'root': str(root), 'keep': kept, 'delete': deletes,
            'status': 'planned', 'planned_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}


def check_idle(paths):
    processes = subprocess.check_output(['ps', '-Ao', 'comm='], text=True).splitlines()
    if any(Path(x.strip()).name in {'xcodebuild', 'swift-frontend', 'xctest'} for x in processes):
        raise RuntimeError('Apple build/test is running; cleanup must wait')
    opened = subprocess.run(['lsof', '-n', '-P', '-F', 'n', '-u', str(os.getuid())],
                            capture_output=True, text=True)
    if opened.returncode not in (0, 1):
        raise RuntimeError('Unable to inspect open files')
    for line in opened.stdout.splitlines():
        if line.startswith('n/') and any(contained(Path(line[1:]), p) for p in paths):
            raise RuntimeError('Artifact is open: ' + line[1:])


def apply(root, plan, receipt_path, idle_check=check_idle):
    if plan['status'] != 'planned' or plan['root'] != str(root):
        raise ValueError('Wrong root or plan state')
    paths = [candidate(root, x['path']) for x in plan['delete']]
    # Check the ENTIRE manifest before the first deletion.
    for entry, path in zip(plan['delete'], paths):
        if fingerprint(path) != entry['fingerprint']:
            raise ValueError('Artifact changed after planning: ' + entry['path'])
        for proof in entry['evidence']:
            p = root / proof['path']
            if any(contained(p.resolve(), c) for c in paths) or fingerprint(p) != proof['fingerprint']:
                raise ValueError('Evidence changed or overlaps deletion: ' + proof['path'])
    for entry in plan['keep']:
        if fingerprint(root / entry['path']) != entry['fingerprint']:
            raise ValueError('Retained evidence changed: ' + entry['path'])
    idle_check(paths)
    receipt = {'status': 'applying', 'deleted': [], 'planned_allocated_bytes':
               sum(x['fingerprint']['allocated_bytes'] for x in plan['delete'])}
    write_json(receipt_path, receipt)
    for entry, path in zip(plan['delete'], paths):
        # Recheck immediately before removal, after the batch validation above.
        candidate(root, entry['path'])
        if fingerprint(path) != entry['fingerprint']:
            raise ValueError('Artifact changed during cleanup: ' + entry['path'])
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        receipt['deleted'].append(entry['path'])
        write_json(receipt_path, receipt)
    for entry in plan['keep']:
        if fingerprint(root / entry['path']) != entry['fingerprint']:
            raise RuntimeError('Retention verification failed')
    for disposition, entries in [('retained', plan['keep']), ('retired', plan['delete'])]:
        for entry in entries:
            artifact = root / entry['path']
            state_path = artifact.parent / 'run.json'
            if artifact.name == 'tests.xcresult' and state_path.exists():
                state = json.loads(state_path.read_text())
                state.update(cleanup_status=disposition, retention_reason=entry['reason'])
                write_json(state_path, state)
    receipt.update(status='complete', retained_evidence_verified=True,
                   completed_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
    write_json(receipt_path, receipt)
    return receipt


def capture_summary(bundle):
    result = {}
    for kind in ('summary', 'tests'):
        p = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
                            '--path', str(bundle), '--compact'], capture_output=True, text=True)
        result[kind] = json.loads(p.stdout) if p.returncode == 0 else {'unavailable': p.stderr[-2000:]}
    return result


def check_closeout(root, plan):
    """Unclassified test artifacts and unfinished runs block resource closeout."""
    expected = {x['path'] for x in plan['keep']}
    pending = []
    unknown = []
    for directory, dirs, files in os.walk(root / 'build'):
        for name in list(dirs):
            if name.endswith('.xcresult'):
                path = str((Path(directory) / name).relative_to(root))
                if path not in expected:
                    unknown.append(path)
                dirs.remove(name)
        for name in files:
            path = Path(directory) / name
            relative = str(path.relative_to(root))
            if path.suffix.lower() in MEDIA and relative not in expected:
                unknown.append(relative)
            if name == 'run.json':
                state = json.loads(path.read_text())
                if 'cleanup_status' in state and state['cleanup_status'] == 'pending':
                    pending.append(relative)
    changed = [x['path'] for x in plan['keep'] if not (root / x['path']).exists()
               or fingerprint(root / x['path']) != x['fingerprint']]
    remaining = [x['path'] for x in plan['delete'] if (root / x['path']).exists()]
    return {'status': 'complete' if not (unknown or pending or changed or remaining) else 'pending',
            'unclassified_artifacts': unknown, 'unclosed_runs': pending,
            'changed_retained_evidence': changed, 'remaining_deletions': remaining}


def run_tests(root, args):
    directory = root / args.directory
    if not contained(directory.resolve(), root / 'build') or directory.exists():
        raise ValueError('Use a new run directory inside build/')
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or command[0] != 'xcodebuild' or 'test' not in command:
        raise ValueError('Runner accepts xcodebuild test only')
    if '-resultBundlePath' in command or 'clean' in command:
        raise ValueError('Runner owns result path; global clean is prohibited')
    if '-derivedDataPath' not in command:
        raise ValueError('Specify the existing shared DerivedData explicitly')
    derived = Path(command[command.index('-derivedDataPath') + 1]).expanduser()
    if not derived.is_dir():
        raise ValueError('DerivedData must already exist; do not create a per-run cache')
    check_idle([])
    directory.mkdir(parents=True)
    state = {'purpose': args.purpose, 'scope': args.scope, 'source_commit':
             subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
             'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'status': 'running', 'cleanup_status': 'pending', 'automatic_attachment_export': False}
    state['app_diff_sha256'] = hashlib.sha256(subprocess.check_output(
        ['git', '-C', str(root), 'diff', 'HEAD', '--', 'App'])).hexdigest()
    bundle = directory / 'tests.xcresult'
    command = command + ['-resultBundlePath', str(bundle), '-jobs', '2', '-parallel-testing-enabled', 'NO']
    write_json(directory / 'run.json', state)
    code = 130
    try:
        with (directory / 'test.log').open('w') as log:
            process = subprocess.Popen(command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait()
            except KeyboardInterrupt:
                import signal
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait()
    finally:
        state.update(status='passed' if code == 0 else 'failed_or_interrupted', exit_code=code,
                     finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        if bundle.exists():
            try:
                write_json(directory / 'summary.json', capture_summary(bundle))
            except (OSError, ValueError) as error:
                state['summary_error'] = str(error)
        write_json(directory / 'run.json', state)
        print('Tests ended; retention/cleanup is pending. Classify final or unresolved evidence before closeout.')
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('plan'); p.add_argument('--decisions', required=True); p.add_argument('--output', required=True)
    p = sub.add_parser('apply'); p.add_argument('--plan', required=True); p.add_argument('--receipt', required=True)
    p = sub.add_parser('check'); p.add_argument('--plan', required=True); p.add_argument('--output', required=True)
    p = sub.add_parser('run'); p.add_argument('--directory', required=True)
    p.add_argument('--purpose', choices=['regression', 'visual-acceptance', 'diagnosis'], required=True)
    p.add_argument('--scope', required=True); p.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'plan':
        plan = prepare(ROOT, json.loads(Path(args.decisions).read_text()))
        write_json(args.output, plan)
        print(json.dumps({'candidates': len(plan['delete']), 'allocated_bytes': sum(
            x['fingerprint']['allocated_bytes'] for x in plan['delete'])}))
    elif args.action == 'apply':
        result = apply(ROOT, json.loads(Path(args.plan).read_text()), args.receipt)
        print(json.dumps({'status': result['status'], 'deleted_count': len(result['deleted'])}))
    elif args.action == 'check':
        result = check_closeout(ROOT, json.loads(Path(args.plan).read_text()))
        write_json(args.output, result)
        print(json.dumps(result))
        return 0 if result['status'] == 'complete' else 1
    else:
        return run_tests(ROOT, args)
    return 0


if __name__ == '__main__':
    sys.exit(main())
