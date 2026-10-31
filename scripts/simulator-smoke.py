import json
from pathlib import Path
import subprocess
import time

report = {'status': 'running', 'phase': 'runtime'}
udid = None


def run(*args, timeout=40):
    print('+', ' '.join(args), flush=True)
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    print(result.stdout[-2000:], flush=True)
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    return result.stdout.strip()


try:
    runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    runtime = next(item['identifier'] for item in runtimes
                   if item.get('isAvailable') and item['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-'))
    report['runtime'] = runtime
    report['phase'] = 'create'
    udid = run('xcrun', 'simctl', 'create', 'JARVIS iPhone 13 Pro Max',
               'com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max', runtime)
    report['simulator'] = udid
    report['phase'] = 'boot'
    run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=90)
    report['phase'] = 'install'
    run('xcrun', 'simctl', 'install', udid,
        '.smoke-build/Build/Products/Release-iphonesimulator/JarvisPhone.app', timeout=45)
    report['phase'] = 'launch'
    report['process'] = run('xcrun', 'simctl', 'launch', udid, 'com.jarvisxlv.iphone', timeout=30)
    time.sleep(3)
    report['phase'] = 'screenshot'
    run('xcrun', 'simctl', 'io', udid, 'screenshot', 'JARVIS-IPHONE-SIMULADOR.png', timeout=30)
    report['status'] = 'passed'
    report['phase'] = 'complete'
except Exception as error:
    report['status'] = 'failed'
    report['error'] = str(error)
    if udid:
        try:
            logs = subprocess.run([
                'xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '1m',
                '--style', 'compact', '--predicate',
                'process == "JarvisPhone" OR process == "installd"'
            ], capture_output=True, text=True, timeout=15)
            Path('simulator-diagnostic.log').write_text(logs.stdout[-120000:] + logs.stderr, encoding='utf-8')
        except Exception:
            pass
finally:
    Path('simulator-smoke.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report), flush=True)
if report['status'] != 'passed':
    raise SystemExit(1)
