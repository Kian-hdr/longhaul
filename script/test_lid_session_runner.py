#!/usr/bin/env python3
"""Disposable policy-session process tests; native sensors/mutations compile out."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import Darwin
import LonghaulBridge
@main struct Entry {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "lid-session-watchdog" { exit(LidSessionRunner.watchdog(arguments: Array(args.dropFirst()))) }
        if args.first == "lid-watchdog" { exit(LidProbeRunner.watchdog(arguments: Array(args.dropFirst()))) }
        if args.first == "facts", args.count == 2, let pid = Int32(args[1]) {
            let value: [String: Any] = ["time": LidProbeRunner.clock(), "birth": ProcessIdentity.birth(pid),
                                       "bootID": try LidSessionLedger.currentBootID()]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value)); return
        }
        if args.first == "identity", args.count == 3, let pid = Int32(args[1]), let birth = UInt64(args[2]) {
            exit(ProcessIdentity.isSame(pid: pid, birth: birth) ? 0 : 1)
        }
        if args.first == "forge-baseline", args.count == 2 {
            let root = URL(fileURLWithPath: args[1])
            let lock = try LidProbeRunner.lockProbe(in: root); defer { Darwin.close(lock) }
            let ledger = try LidSessionLedger(root: root)
            let prior = try ledger.currentRecord(); precondition(prior != nil)
            let directory = try LidProbeRunner.newDirectory(in: root)
            let input = Pipe(), output = Pipe(), task = Process()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            task.arguments = [LidSessionRunner.watchdogCommand]
            task.standardInput = input; task.standardOutput = output
            task.standardError = FileHandle(fileDescriptor: lock, closeOnDealloc: false)
            try task.run()
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            defer { try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
            let channel = try LidSessionRunner.Channel<LidSessionRunner.Wire>(readFD: output.fileHandleForReading.fileDescriptor,
                writeFD: input.fileHandleForWriting.fileDescriptor)
            let now = LidProbeRunner.clock(), token = UUID().uuidString
            let birth = ProcessIdentity.birth(getpid())
            let identity = LidSessionIdentity(bootID: try LidSessionLedger.currentBootID(), sessionID: UUID().uuidString,
                                              appPID: getpid(), appBirth: birth)
            let grant = LidSessionGrant(identity: identity, sequence: 1, kind: .renew, evaluatedAt: now, expiresAt: now+8)
            let auth = LidSessionRunner.Wire(kind: "authorize", token: token, time: now,
                pid: task.processIdentifier, birth: ProcessIdentity.birth(task.processIdentifier), parentPID: getpid(), parentBirth: birth,
                directory: directory.path, lockRoot: root.path, grant: grant, priorCleanup: nil)
            try channel.send(auth)
            let reply = try channel.next(until: now+4)
            precondition(reply.kind == "done")
            task.waitUntilExit(); return
        }
        guard args.count == 2 else { exit(2) }
        let box = try Mailbox(root: URL(fileURLWithPath: args[1]))
        if args[0] == "fixture" { exit(LidSessionRunner.run(arguments: [], box: box)) }
        if args[0] == "probe" { exit(LidProbeRunner.run(arguments: [LidProbeRunner.acknowledgement], box: box)) }
        exit(2)
    }
}
'''


def rows(path):
    try:
        values = []
        for line in path.read_text().splitlines():
            try: values.append(json.loads(line))
            except json.JSONDecodeError: pass
        return values
    except FileNotFoundError:
        return []


def wait_for(predicate, name, timeout=6):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate(): return
        time.sleep(.025)
    raise AssertionError('Timed out: ' + name)


def driver(executable, root):
    environment = dict(os.environ, LONGHAUL_LID_TEST_DIR=str(root))
    def facts():
        return json.loads(subprocess.check_output([str(executable), 'facts', str(os.getpid())], env=environment))
    original = facts()
    identity = dict(bootID=original['bootID'], sessionID=str(uuid.uuid4()), appPID=os.getpid(), appBirth=original['birth'])
    child = subprocess.Popen([str(executable), 'fixture', str(root/'mailbox')], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment)
    (root/'monitor.json').write_text(json.dumps(dict(pid=child.pid, birth=facts_for(executable, root, child.pid)['birth'])))
    def read():
        with (root/'status.jsonl').open('ab') as output:
            while True:
                line = child.stdout.readline()
                if not line: return
                output.write(line); output.flush()
    reader = threading.Thread(target=read, daemon=True); reader.start()
    sequence = 0
    first = None
    try:
        while child.poll() is None:
            if (root/'close-input').exists():
                child.stdin.close(); break
            if (root/'stop-grants').exists():
                time.sleep(.1); continue
            now = facts()['time']; sequence += 1
            revoke = (root/'revoke').exists()
            policy = dict(cutoffEnabled=True, cutoffPercent=20)
            if (root/'policy.json').exists(): policy = json.loads((root/'policy.json').read_text())
            grant = dict(version=2, identity=identity, sequence=sequence, kind='revoke' if revoke else 'renew',
                         evaluatedAt=now, expiresAt=now if revoke else now+8, batteryPolicy=policy)
            if (root/'legacy-grants').exists():
                grant['version'] = 1; grant.pop('batteryPolicy')
            if (root/'missing-policy').exists(): grant.pop('batteryPolicy', None)
            if (root/'null-policy').exists(): grant['batteryPolicy'] = None
            if (root/'legacy-with-policy').exists(): grant['version'] = 1
            if (root/'future-version').exists(): grant['version'] = 3
            if (root/'replay').exists() and first is not None: grant = first
            if (root/'foreign').exists(): grant = dict(grant, identity=dict(identity, sessionID=str(uuid.uuid4())))
            if (root/'overlong').exists(): grant['expiresAt'] = now+11
            if (root/'stale').exists(): grant.update(evaluatedAt=now-9, expiresAt=now-1)
            if (root/'wrong-boot').exists(): grant['identity'] = dict(identity, bootID=str(uuid.uuid4()))
            if first is None: first = grant
            data = json.dumps(grant, separators=(',', ':')).encode()+b'\n'
            assert len(data) <= 511, 'Grant exceeds original app atomic transport bound'
            with (root/'grants.jsonl').open('ab') as out: out.write(data)
            child.stdin.write(data); child.stdin.flush()
            if revoke:
                child.stdin.close(); break
            time.sleep(.25)
    except BrokenPipeError:
        pass
    code = child.wait(timeout=8); reader.join(timeout=2)
    (root/'exit.json').write_text(json.dumps(dict(code=code)))


def facts_for(executable, root, pid):
    return json.loads(subprocess.check_output([str(executable), 'facts', str(pid)],
        env=dict(os.environ, LONGHAUL_LID_TEST_DIR=str(root))))


if len(sys.argv) == 4 and sys.argv[1] == '--driver':
    driver(Path(sys.argv[2]), Path(sys.argv[3])); sys.exit(0)

WORK = Path(tempfile.mkdtemp(prefix='longhaul-lid-session-tests-'))
os.chmod(WORK, 0o700)
scenarios = []
success = False


def command(args):
    result = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
    if result.returncode: raise RuntimeError(result.stdout+result.stderr)


class Scenario:
    def __init__(self, name, executable, markers=(), existing=None, expect_enable=True, policy=None):
        self.executable = executable
        self.root = existing or WORK/name
        self.root.mkdir(mode=0o700, exist_ok=True)
        for marker in markers: (self.root/marker).touch(mode=0o600)
        if policy is not None: self.set_policy(policy)
        (self.root/'monitor.json').unlink(missing_ok=True)
        self.driver = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--driver', str(executable), str(self.root)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.monitor = self.watchdog = None
        scenarios.append(self)
        wait_for(lambda: (self.root/'monitor.json').exists(), name+' monitor')
        self.monitor = json.loads((self.root/'monitor.json').read_text())
        if expect_enable:
            wait_for(lambda: (self.root/'held').exists(), name+' fake enable')
            wait_for(lambda: list((self.root/'mailbox').glob('lid-probe-*/watchdog.jsonl')), name+' watchdog log')
            self.directory = max((self.root/'mailbox').glob('lid-probe-*'), key=lambda p: p.stat().st_mtime_ns)
            first = rows(self.directory/'watchdog.jsonl')[0]
            self.watchdog = dict(pid=first['pid'], birth=first['birth'])
    def living(self, participant):
        if not participant: return False
        return subprocess.run([str(self.executable), 'identity', str(participant['pid']), str(participant['birth'])],
                              stdout=subprocess.DEVNULL).returncode == 0
    def signal(self, participant, sig):
        if self.living(participant): os.kill(participant['pid'], sig)
    def operations(self): return [r['disabled'] for r in rows(self.root/'mutations.jsonl')]
    def assert_original_hold(self):
        assert self.operations() == [True] and self.driver.poll() is None
        assert self.living(self.monitor) and self.living(self.watchdog)
        grants = rows(self.root/'grants.jsonl')
        statuses = rows(self.root/'status.jsonl')
        assert grants and statuses
        assert all(r['identity'] == grants[0]['identity'] for r in statuses)
        assert len(list((self.root/'mailbox').glob('lid-probe-*'))) == 1
    def wait_power(self, on_ac, after=None):
        # Both helpers must independently observe the changed source while the
        # original app continues granting the same session.
        for name in ['monitor', 'watchdog']:
            start = (after or {}).get(name, 0)
            def observed():
                return any(r.get('sample', {}).get('power', {}).get('onAC') is on_ac and
                           r['sample']['power'].get('discharging') is (not on_ac)
                           for r in rows(self.directory/(name+'.jsonl'))[start:])
            wait_for(observed, name+' observed '+('AC' if on_ac else 'battery'))
    def set_policy(self, policy):
        temporary = self.root/'policy-next.json'
        temporary.write_text(json.dumps(policy)); os.chmod(temporary, 0o600)
        temporary.replace(self.root/'policy.json')
    def wait_policy(self, policy):
        for name in ['monitor','watchdog']:
            wait_for(lambda: any(r.get('grant', {}).get('batteryPolicy') == policy
                                 for r in rows(self.directory/(name+'.jsonl'))),
                     name+' accepted configured cutoff')
    def wait_renewed(self):
        first_deadline = rows(self.root/'grants.jsonl')[0]['expiresAt']
        wait_for(lambda: any(r['state'] == 'active' and r['observedAt'] > first_deadline
                             for r in rows(self.root/'status.jsonl')), 'renewed beyond original policy lease')
        self.assert_original_hold()
    def stage(self): return json.loads((self.root/'mailbox/lid-current-session.json').read_text())['stage']
    def finish(self):
        if self.driver.poll() is None: self.driver.kill()
        self.driver.communicate(timeout=3)
        self.signal(self.monitor, signal.SIGKILL); self.signal(self.watchdog, signal.SIGKILL)
    def exited(self):
        self.driver.communicate(timeout=7)
        wait_for(lambda: not self.living(self.watchdog), 'watchdog exit')
    def cleaned(self):
        wait_for(lambda: self.operations() == [True, False], 'exactly one balancing clear')
        wait_for(lambda: not self.living(self.watchdog), 'watchdog cleanup exit')
        assert not (self.root/'held').exists()
        assert self.stage() == 'cleanupAccepted', self.stage()
        time.sleep(.1); assert self.operations() == [True, False]


try:
    build = WORK/'build'
    command(['swift', 'build', '--scratch-path', str(build), '--product', 'longhaul'])
    debug = build/'arm64-apple-macosx/debug'
    harness = WORK/'Harness.swift'; harness.write_text(HARNESS)
    executable = WORK/'lid-session-simulation'
    objects = [str(p) for target in ['LonghaulCore','LonghaulBridge','CLonghaulSupport'] for p in (debug/(target+'.build')).glob('*.o')]
    command(['swiftc','-D','LONGHAUL_LID_PROBE_TESTING','-parse-as-library','-target','arm64-apple-macos26.0',
             '-I',str(debug/'Modules'),'-I',str(debug/'CLonghaulSupport.build'),
             'Sources/LonghaulCLI/LidProbeRunner.swift','Sources/LonghaulCLI/LidSessionRunner.swift',str(harness),*objects,
             '-framework','AppKit','-framework','IOKit','-o',str(executable)])
    assert subprocess.run([str(executable),'lid-session-watchdog'], capture_output=True).returncode == 2
    rejected = Scenario('wrong-boot', executable, markers=('wrong-boot',), expect_enable=False)
    rejected.exited(); assert rejected.operations() == []
    print('PASS inherited transport alone cannot authorize a foreign boot identity', flush=True)
    s = Scenario('sustained', executable, markers=('stale-true-after-enable', 'stale-false-after-clear'))
    time.sleep(16.0)  # 64 simulated seconds: beyond the old probe cap and many original leases.
    assert s.operations() == [True] and s.driver.poll() is None
    statuses = rows(s.root/'status.jsonl'); grants = rows(s.root/'grants.jsonl')
    active = [r for r in statuses if r['state'] == 'active']; assert len(active) >= 30
    assert all(r['leaseExpiresAt'] in {g['expiresAt'] for g in grants} for r in active)
    assert all(a['sequence'] < b['sequence'] for a,b in zip(statuses,statuses[1:]))
    assert all(r['identity'] == grants[0]['identity'] for r in statuses)
    (s.root/'revoke').touch(); s.exited(); s.cleaned()
    print('PASS sustained original policy renewals, unchanged deadlines, monotonic status, revoke, stale registry', flush=True)
    logged = [r['grant'] for r in rows(s.directory/'monitor.jsonl') if r['event'] == 'app-policy']
    assert len(logged) >= 40 and all(g in rows(s.root/'grants.jsonl') for g in logged)
    assert rows(s.directory/'monitor.jsonl')[-1]['event'] == 'final-observation'
    assert rows(s.directory/'monitor.jsonl')[-1]['cleanupRequired'] is False
    first_false = Scenario('first-false', executable, markers=('clear-has-run','stale-false-after-clear'), expect_enable=False)
    first_false.exited(); assert first_false.operations() == []
    print('PASS first session rejects stale-false publication without previous accepted ledger', flush=True)
    env = dict(os.environ,LONGHAUL_LID_TEST_DIR=str(s.root))
    forged = subprocess.run([str(executable),'forge-baseline',str(s.root/'mailbox')],env=env,capture_output=True,timeout=4)
    assert forged.returncode == 0, forged.stderr.decode()
    assert s.operations() == [True,False]
    print('PASS watchdog independently rejects forged/missing prior-clear proof', flush=True)
    (s.root/'revoke').unlink()
    next_session = Scenario('accepted-false', executable, existing=s.root)
    wait_for(lambda: next_session.operations() == [True,False,True], 'second accepted hold')
    (s.root/'revoke').touch(); next_session.exited()
    assert next_session.operations() == [True,False,True,False] and next_session.stage() == 'cleanupAccepted'
    print('PASS next episode accepts stale false only after same-boot successful cleanup', flush=True)
    # A structurally valid foreign-boot receipt must not provide a stale-false baseline.
    record_path = s.root/'mailbox/lid-current-session.json'
    record = json.loads(record_path.read_text()); record['identity']['bootID'] = str(uuid.uuid4())
    record_path.write_text(json.dumps(record)); os.chmod(record_path,0o600)
    (s.root/'revoke').unlink()
    foreign_prior = Scenario('foreign-prior', executable, existing=s.root, expect_enable=False)
    foreign_prior.exited(); assert foreign_prior.operations() == [True,False,True,False]
    assert rows(s.root/'status.jsonl')[-1]['state'] == 'unavailable'
    print('PASS foreign-boot cleanup cannot admit a stale-false session', flush=True)

    for marker in ['stop-grants','close-input','replay','foreign','overlong','stale']:
        s = Scenario(marker, executable); (s.root/marker).touch(); s.exited(); s.cleaned()
        print('PASS '+marker+': one enable/clear, no helper-authored policy extension', flush=True)

    s = Scenario('app-death', executable)
    s.driver.kill(); s.driver.communicate(timeout=3); s.cleaned()
    print('PASS original app death releases hold', flush=True)
    for actor, sig in [('monitor',signal.SIGKILL),('monitor',signal.SIGSTOP),('watchdog',signal.SIGKILL),('watchdog',signal.SIGSTOP)]:
        s = Scenario(actor+'-'+str(sig), executable)
        s.signal(getattr(s,actor),sig)
        s.cleaned()
        if sig == signal.SIGSTOP: s.signal(getattr(s,actor),signal.SIGCONT)
        s.exited()
        print('PASS '+actor+' '+str(sig)+': peer detects loss and balances once', flush=True)

    s = Scenario('connected-discharge', executable, markers=('ac-discharge',))
    time.sleep(.8)
    assert s.operations() == [True] and s.driver.poll() is None
    (s.root/'revoke').touch(); s.exited(); s.cleaned()
    print('PASS connected discharge preserves the original hold above battery reserve', flush=True)
    s = Scenario('ac-battery-ac', executable)
    s.wait_power(True)
    checkpoints = {name: len(rows(s.directory/(name+'.jsonl'))) for name in ['monitor','watchdog']}
    (s.root/'ac-disconnected').touch(); (s.root/'ac-discharge').touch()
    s.wait_power(False, after=checkpoints); s.assert_original_hold()
    checkpoints = {name: len(rows(s.directory/(name+'.jsonl'))) for name in ['monitor','watchdog']}
    (s.root/'ac-disconnected').unlink(); (s.root/'ac-discharge').unlink()
    s.wait_power(True, after=checkpoints); s.assert_original_hold()
    (s.root/'revoke').touch(); s.exited(); s.cleaned()
    print('PASS AC to battery to AC: same original session and helpers, one enable, clear only on revoke', flush=True)

    s = Scenario('battery-startup', executable, markers=('ac-disconnected','ac-discharge'))
    s.wait_power(False); s.assert_original_hold()
    (s.root/'revoke').touch(); s.exited(); s.cleaned()
    print('PASS startup on discharging battery above reserve, accepted cleanup on revoke', flush=True)

    s = Scenario('battery-reserve-boundary', executable,
                 markers=('ac-disconnected','ac-discharge','reserve-boundary'))
    s.wait_power(False)
    first_deadline = rows(s.root/'grants.jsonl')[0]['expiresAt']
    wait_for(lambda: any(r['state'] == 'active' and r['observedAt'] > first_deadline
                         for r in rows(s.root/'status.jsonl')),
             '20 percent hold renewed beyond original lease')
    s.assert_original_hold()
    for name in ['monitor','watchdog']:
        samples = [r['sample'] for r in rows(s.directory/(name+'.jsonl'))
                   if r['event'] == 'heartbeat' and 'sample' in r]
        assert samples and all(r['power']['percent'] == 20 and r['power']['onAC'] is False
                               and r['power']['discharging'] is True for r in samples)
    (s.root/'unsafe-power').touch(); s.exited(); s.cleaned()
    final = rows(s.directory/'monitor.jsonl')[-1]
    assert final['event'] == 'final-observation' and final['cleanupRequired'] is False
    assert final['sample']['power']['percent'] == 19 and final['sample']['power']['onAC'] is False
    print('PASS battery boundary: startup and original-session renewals at 20 percent, one accepted clear at 19', flush=True)

    battery = ('ac-disconnected','ac-discharge')
    default_policy = dict(cutoffEnabled=True, cutoffPercent=20)
    off_policy = dict(cutoffEnabled=False, cutoffPercent=20)
    legacy = Scenario('legacy-v1', executable, markers=battery+('legacy-grants','reserve-boundary'))
    legacy.wait_renewed(); (legacy.root/'revoke').touch(); legacy.exited(); legacy.cleaned()
    legacy_low = Scenario('legacy-v1-reserve', executable, markers=battery+('legacy-grants','unsafe-power'), expect_enable=False)
    legacy_low.exited(); assert legacy_low.operations() == []
    print('PASS v1 absent policy retains enabled20 default; legacy low-battery startup refused', flush=True)
    for marker in ['missing-policy','null-policy','legacy-with-policy','future-version']:
        s = Scenario('invalid-'+marker, executable, markers=(marker,), expect_enable=False)
        s.exited(); assert s.operations() == []
    for policy in [dict(cutoffEnabled=True,cutoffPercent=0), dict(cutoffEnabled=False,cutoffPercent=101),
                   dict(cutoffEnabled=True,cutoffPercent=20.5)]:
        s = Scenario('invalid-cutoff-'+str(policy['cutoffPercent']), executable, policy=policy, expect_enable=False)
        s.exited(); assert s.operations() == []
    print('PASS unsupported/missing/null/mistyped/out-of-range policy cannot enable', flush=True)
    s = Scenario('configured-startup-refused', executable, policy=dict(cutoffEnabled=True,cutoffPercent=80), expect_enable=False)
    s.exited(); assert s.operations() == []
    print('PASS first configured cutoff controls admission instead of a helper default', flush=True)

    s = Scenario('dynamic-lower-cutoff', executable, markers=battery+('reserve-boundary',))
    lowered = dict(cutoffEnabled=True, cutoffPercent=10)
    s.set_policy(lowered); s.wait_policy(lowered)
    (s.root/'unsafe-power').touch(); s.wait_renewed()
    for name in ['monitor','watchdog']:
        wait_for(lambda: any(r.get('sample', {}).get('power', {}).get('percent') == 19
                             for r in rows(s.directory/(name+'.jsonl'))), name+' continued below old cutoff')
    s.assert_original_hold()
    s.set_policy(default_policy); s.exited(); s.cleaned()
    print('PASS lower cutoff applies through original grants; raising above battery clears once', flush=True)

    for marker in ['unsafe-power','battery-five']:
        s = Scenario('off-'+marker, executable, markers=battery+(marker,), policy=off_policy)
        s.wait_policy(off_policy); s.wait_renewed()
        (s.root/'revoke').touch(); s.exited(); s.cleaned()
        print('PASS cutoff Off holds at '+('19' if marker == 'unsafe-power' else '5')+' percent without bypassing original lease', flush=True)

    s = Scenario('dynamic-cutoff-off', executable, markers=battery+('reserve-boundary',))
    s.set_policy(off_policy); s.wait_policy(off_policy)
    (s.root/'battery-five').touch(); s.wait_renewed(); s.assert_original_hold()
    s.set_policy(default_policy); s.exited(); s.cleaned()
    print('PASS live toggle Off continues same hold at5; toggle On restores reserve and clears once', flush=True)

    for marker in ['battery-warning','thermal-warning','unknown-power','unknown-percent']:
        s = Scenario('off-safety-'+marker, executable, markers=battery+('battery-five',), policy=off_policy)
        s.wait_policy(off_policy); s.assert_original_hold()
        (s.root/marker).touch(); s.exited(); s.cleaned()
        print('PASS cutoff Off preserves '+marker+' stop and exactly-one cleanup', flush=True)

    s = Scenario('invalid-policy-after-enable', executable)
    s.set_policy(dict(cutoffEnabled=False, cutoffPercent=0)); s.exited(); s.cleaned()
    print('PASS invalid changed policy stops instead of falling back to a helper default', flush=True)

    for marker in ['unsafe-power','battery-warning','thermal-warning','unknown-power']:
        s = Scenario('battery-'+marker, executable, markers=('ac-disconnected','ac-discharge'))
        s.wait_power(False); s.assert_original_hold()
        (s.root/marker).touch(); s.exited(); s.cleaned()
        final = rows(s.directory/'monitor.jsonl')[-1]
        assert final['event'] == 'final-observation' and final['cleanupRequired'] is False
        assert final['sample']['power']['onAC'] is False and final['sample']['power']['discharging'] is True
        print('PASS battery '+marker+': independent safety stop and exactly one accepted cleanup', flush=True)

    for marker in ['unsafe-power','service-unavailable','competing-owner','unknown-owner','stall-after-clear-write','stall-after-clear-receipt']:
        pre = (marker,) if marker.startswith('stall') else ()
        s = Scenario(marker, executable, markers=pre)
        (s.root/('revoke' if pre else marker)).touch(); s.exited()
        if marker == 'unsafe-power' or marker == 'stall-after-clear-receipt':
            s.cleaned()
        elif marker in ('stall-after-clear-write','service-unavailable'):
            assert s.operations() == [True,False] and s.stage() == 'unresolved'
        else:
            assert s.operations() == [True] and s.stage() == 'unresolved'
        print('PASS '+marker+': cleanup outcome preserved without blind retry', flush=True)

    s = Scenario('both-death', executable)
    s.signal(s.monitor,signal.SIGSTOP); s.signal(s.watchdog,signal.SIGSTOP)
    s.signal(s.watchdog,signal.SIGKILL); s.signal(s.monitor,signal.SIGKILL)
    s.exited(); assert s.operations() == [True] and s.stage() == 'enabled'
    # Simulate a registry that appears normal. Durable unresolved state must still veto enable.
    (s.root/'held').unlink()
    environment = dict(os.environ,LONGHAUL_LID_TEST_DIR=str(s.root))
    blocked = subprocess.run([str(executable),'probe',str(s.root/'mailbox')], env=environment, capture_output=True, timeout=3)
    assert blocked.returncode == 2 and s.operations() == [True]
    (s.root/'revoke').unlink(missing_ok=True)
    restarted = Scenario('blocked-session', executable, existing=s.root, expect_enable=False)
    restarted.exited(); assert s.operations() == [True]
    assert rows(s.root/'status.jsonl')[-1]['state'] == 'cleanupRequired'
    print('PASS both-helper death leaves durable debt blocking new probe and new session', flush=True)
    print(f'{len(scenarios)} disposable session scenarios passed; native mutations/sensors compiled out.',flush=True)
    success = True
finally:
    for scenario in scenarios: scenario.finish()
    if success: shutil.rmtree(WORK)
    else: print('Retained failed session evidence:',WORK,flush=True)
