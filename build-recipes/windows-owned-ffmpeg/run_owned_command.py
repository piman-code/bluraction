"""Private Windows Job Object command deadline, reusing the reviewed source runner."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys

RUNNER_SHA256 = '312931a76abaeddc322f7a53a3802cd3fdac2f40685b1d5b53d3457720b8e276'
BOOTSTRAP = "import sys,subprocess\nif sys.stdin.buffer.read(1)!=b'G': raise SystemExit(125)\nraise SystemExit(subprocess.call(sys.argv[1:]))\n"

parser = argparse.ArgumentParser()
parser.add_argument('--repository', type=Path, required=True)
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--cwd', type=Path)
parser.add_argument('--stem', required=True)
parser.add_argument('--timeout', type=float, required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
if os.name != 'nt' or not math.isfinite(args.timeout) or not 1 <= args.timeout <= 3600:
    raise ValueError('bounded actual Windows command required')
if not args.stem or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in args.stem):
    raise ValueError('plain owned command stem required')
root = args.root.absolute()
if root.resolve() != root or not (root / 'owned.json').is_file():
    raise ValueError('attempt-owned root required')
cwd = root if args.cwd is None else args.cwd.absolute()
cwd.relative_to(root)
if cwd.resolve() != cwd:
    raise ValueError('plain owned working directory required')
argv = args.command[1:] if args.command[:1] == ['--'] else args.command
if not argv or not Path(argv[0]).is_absolute():
    raise ValueError('absolute command executable required')
runner = args.repository.absolute() / 'scripts' / 'verify_windows.py'
if hashlib.sha256(runner.read_bytes()).hexdigest() != RUNNER_SHA256:
    raise ValueError('reviewed process-tree implementation changed; update draft only after review')
spec = importlib.util.spec_from_file_location('owned_recipe_process_scope', runner)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
job = module.WindowsJob()
child = None
row = {'command': argv, 'runnerSHA256': RUNNER_SHA256, 'timeoutSeconds': args.timeout,
       'status': 'failed-or-incomplete', 'releaseApproved': False, 'fullGoalComplete': False}
log_path = root / 'logs' / (args.stem + '.log')
exit_status = 1
with log_path.open('xb') as log:
    try:
        child = subprocess.Popen([sys.executable, '-c', BOOTSTRAP, *argv], cwd=cwd,
                                 stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
        job.assign(child)
        child.stdin.write(b'G'); child.stdin.flush(); child.stdin.close()
        try:
            row['exitCode'] = child.wait(timeout=args.timeout)
            row['timedOut'] = False
        except subprocess.TimeoutExpired:
            row['timedOut'] = True
            job.terminate()
            row['exitCode'] = child.wait(timeout=10)
        job.drain()
        row['privateTreeDrained'] = True
        if row['exitCode'] == 0 and not row['timedOut']:
            row['status'] = 'owned-command-complete'
            exit_status = 0
    except BaseException as error:
        row.update(errorType=type(error).__name__, error=str(error))
    finally:
        try:
            job.drain()
        except BaseException as error:
            row.update(cleanupError=type(error).__name__ + ': ' + str(error), status='failed-or-incomplete')
            exit_status = 1
        finally:
            job.close()
            if child is not None and child.poll() is None:
                child.kill(); child.wait(timeout=10)
            if child is not None and child.stdin is not None and not child.stdin.closed:
                child.stdin.close()
row['logSHA256'] = hashlib.sha256(log_path.read_bytes()).hexdigest()
with (root / 'reports' / (args.stem + '.json')).open('x', encoding='utf-8') as output:
    json.dump(row, output, sort_keys=True, indent=2); output.write('\n')
raise SystemExit(exit_status)
