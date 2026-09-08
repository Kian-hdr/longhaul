#!/usr/bin/env python3
"""Assess a real app-driven lid session; never changes power state."""
import argparse
import hashlib
import json
import math
import uuid
from pathlib import Path
from verify_lid_continuity import require, rows


def verify(directory, workload, power, ledger, completed_job=False, battery=False):
    directory = Path(directory)
    monitor, watchdog = rows(directory/'monitor.jsonl'), rows(directory/'watchdog.jsonl')
    work = rows(workload)
    history, debt = json.loads(Path(power).read_text()), json.loads(Path(ledger).read_text())
    require(len(work) >= 2, 'Missing workload')
    chain = bytes(32)
    for index, r in enumerate(work):
        chain = hashlib.sha256(chain + index.to_bytes(8, 'big')).digest()
        require(r['index'] == index and r['digest'] == chain.hex(), 'Invalid workload chain')
        require(all(math.isfinite(r[k]) for k in ('wall', 'continuous')), 'Invalid workload clock')
    for a, b in zip(work, work[1:]):
        require(all(0 < b[k]-a[k] <= 1 for k in ('wall', 'continuous')), 'Workload continuity gap')
    require(abs((work[-1]['wall']-work[0]['wall'])-(work[-1]['continuous']-work[0]['continuous']))<=.5, 'Wall and continuous clocks diverged')
    last = work[-1]
    require(last.get('completed') is True and not any(r.get('completed') for r in work[:-1]), 'Missing final workload observation')
    require(1 <= last['requestedSeconds'] <= 120 and
            0 <= work[0]['continuous']-last['startedContinuous'] < 1 and
            last['requestedSeconds'] <= last['continuous']-last['startedContinuous'] <= last['requestedSeconds']+1,
            'Interrupted workload duration')
    def single(name):
        values = [r for r in watchdog if r['event'] == name]
        require(len(values) == 1, 'Expected exactly one '+name)
        r = values[0]
        require(r['backend'].get('serviceFound') is True and
                all(r['backend'].get(k) == 0 for k in ('openResult','callResult','closeResult')), 'Native call failed')
        return r
    enable, clear = single('enable-result'), single('cleanup-result')
    require(clear['time']-enable['time'] > 60, 'Session did not exceed sixty seconds')
    require((directory/'cleanup-attempt.json').is_file() and not (directory/'owner-conflict').exists(), 'Missing cleanup intent or owner conflict')
    require(json.loads((directory/'cleanup-result.json').read_text()) == clear['backend'], 'Cleanup receipt mismatch')
    final = monitor[-1]
    require(final['event'] == 'final-observation' and final.get('cleanupRequired') is False, 'Cleanup not confirmed')
    require(final['sample']['inspection']['snapshot']['lidClosed'] is False, 'Final lid is not open')
    native = [r['sample'] for r in watchdog if r['event'] == 'heartbeat']
    require(len(native) >= 10 and native[-1]['time']-native[0]['time'] >= 55, 'Insufficient native coverage')
    require(enable['time'] <= native[0]['time'] and clear['time'] >= native[-1]['time'], 'Observations outside hold')
    for a,b in zip(native,native[1:]):
        require(0 < b['time']-a['time'] <= 6, 'Native observation gap')
    closed = [r for r in native if r['inspection']['snapshot']['lidClosed'] is True]
    require(len(closed) >= 3 and closed[-1]['time']-closed[0]['time'] >= 10, 'Insufficient closed-lid interval')
    begin,end = closed[0]['time'],closed[-1]['time']
    require(any(r['time'] < begin and r['inspection']['snapshot']['lidClosed'] is False for r in native), 'Missing initial open lid')
    require(any(r['time'] > end and r['inspection']['snapshot']['lidClosed'] is False for r in native), 'Missing reopening before cleanup')
    policies = [r for r in monitor if r['event']=='app-policy']
    require(len(policies)>=3, 'Missing app policy renewals')
    identity,seq,previous,deadline = policies[0]['grant']['identity'],0,-1,-1
    try:
        uuid.UUID(identity['bootID']);uuid.UUID(identity['sessionID'])
    except (ValueError,AttributeError):
        raise ValueError('Invalid session identity')
    require(type(identity['appPID']) is int and identity['appPID']>1 and type(identity['appBirth']) is int and identity['appBirth']>0, 'Invalid app process identity')
    renewals=[]
    validated_policies=[]
    previous_receipt=-1
    revoked=False
    stop_time=None
    for r in policies:
        g=r['grant']; t=g['evaluatedAt']
        require(type(g.get('version')) is int and g['version'] in (1,2), 'Invalid grant version')
        if g['version']==1:
            require('batteryPolicy' not in g, 'Legacy grant must omit battery policy')
            battery_policy={'cutoffEnabled':True,'cutoffPercent':20}
        else:
            battery_policy=g.get('batteryPolicy')
            require(isinstance(battery_policy,dict) and type(battery_policy.get('cutoffEnabled')) is bool and
                    type(battery_policy.get('cutoffPercent')) is int and 1<=battery_policy['cutoffPercent']<=100,
                    'Invalid battery cutoff policy')
        require(not revoked and g['identity']==identity and type(g['sequence']) is int and seq<g['sequence']<=2**64-1 and
                math.isfinite(r['time']) and previous_receipt<=r['time'] and math.isfinite(t) and
                math.isfinite(g['expiresAt']) and previous<=t<=r['time'], 'Invalid original grant')
        if g['kind']=='renew':
            require(r['time']<g['expiresAt']<=t+10 and t>=0, 'Expired or overlong grant')
            if renewals: require(r['time']<deadline, 'Policy renewal gap')
            deadline=g['expiresAt'];renewals.append(g)
        else:
            require(g['kind']=='revoke' and g['expiresAt']==t and r['time']<deadline, 'Invalid revocation');revoked=True;stop_time=t
        seq,previous=g['sequence'],t
        previous_receipt=r['time']
        validated_policies.append((r['time'],g,battery_policy))
    policy_index=-1
    for r in native+[final['sample']]:
        inspection=r['inspection']
        require(inspection.get('serviceFound') is True and inspection.get('openResult')==0 and inspection.get('closeResult')==0, 'Native inspection failed')
        require(math.isfinite(r['time']), 'Invalid native clock')
        snap,p = r['inspection']['snapshot'],r['power']
        require(r['powerKnown'] is True and r['ownerScanComplete'] is True and not r['knownOwners'], 'Unknown power or owner')
        require(type(p['onAC']) is bool and type(p['discharging']) is bool, 'Invalid power source flags')
        require(snap['sleepDisabled'] is False and (battery or p['onAC'] is True) and
                type(p['percent']) in (int,float) and math.isfinite(p['percent']) and 0<=p['percent']<=100 and
                p['thermalLevel']==0 and p['warningLevel']==1, 'Unsafe conditions')
        if begin<=r['time']<=end:
            require(snap['lidClosed'] is True and snap['clamshellCausesSleep'] is False, 'Discontinuous lid closure')
        while policy_index+1<len(validated_policies) and validated_policies[policy_index+1][0]<=r['time']:
            policy_index+=1
        require(policy_index>=0, 'Native sample preceded original policy receipt')
        _,grant,battery_policy=validated_policies[policy_index]
        if r is not final['sample']:
            require(grant['kind']=='renew' and r['time']<grant['expiresAt'], 'Native sample outside original lease')
        require(not battery_policy['cutoffEnabled'] or p['percent']>=battery_policy['cutoffPercent'],
                'Native sample below effective battery cutoff')
    require(clear['time']<=min(deadline,stop_time if stop_time is not None else deadline)+3, 'Original policy does not cover session until cleanup')
    require(renewals[0]['expiresAt']<end and any(begin<g['evaluatedAt']<end for g in renewals), 'Closure did not exercise original-policy renewal')
    require(policies[0]['time']<=enable['time'] and renewals[0]['evaluatedAt']<=enable['time'] and end<renewals[-1]['expiresAt'], 'Policy does not cover physical interval')
    require(debt.get('version')==1 and all(math.isfinite(debt[k]) for k in ('enabledIntentAt','cleanupAttemptedAt','updatedAt')) and
            0<=debt['enabledIntentAt']<=enable['time']<=debt['cleanupAttemptedAt']<=clear['time'] and
            debt['cleanupAttemptedAt']<=debt['updatedAt']<=final['sample']['time'] and debt['enableResult']==enable['backend'], 'Invalid durable ledger chronology')
    require(debt['identity']==identity and debt['stage']=='cleanupAccepted' and debt['cleanupResult']==clear['backend'], 'Durable session cleanup not confirmed')
    closed_work = [r for r in closed if work[0]['continuous'] <= r['time'] <= work[-1]['continuous']]
    closed_work_seconds = closed_work[-1]['time']-closed_work[0]['time'] if closed_work else 0
    battery_closed_work_seconds = 0
    battery_transitions = 0
    if battery:
        # Count one uninterrupted battery witness, never sum disconnected spans.
        # The transition must occur in this hold, not before monitoring started.
        previous_ac, transition_seen, run_start = None, False, None
        for sample in native:
            on_ac = sample['power']['onAC']
            if previous_ac is True and on_ac is False:
                transition_seen = True
                battery_transitions += 1
            if on_ac is True:
                transition_seen = False
            qualifies = (transition_seen and on_ac is False and
                         sample['inspection']['snapshot']['lidClosed'] is True and
                         work[0]['continuous'] <= sample['time'] <= work[-1]['continuous'])
            if qualifies:
                if run_start is None: run_start = sample['time']
                battery_closed_work_seconds = max(battery_closed_work_seconds, sample['time']-run_start)
            else:
                run_start = None
            previous_ac = on_ac
        require(battery_transitions > 0, 'Missing AC-to-battery transition within held session')
        require(battery_closed_work_seconds >= 60, 'Insufficient continuous closed-lid battery work')
    power_end_wall = work[-1]['wall']
    if completed_job:
        # A completed job need not outlive other jobs sharing the same hold.
        # Keep native and original-policy proof through the eventual cleanup.
        require(work[0]['continuous'] < enable['time'], 'Workload started after enable')
        require(closed_work_seconds >= 60, 'Insufficient closed-lid completed-work interval')
    else:
        require(work[0]['continuous']<enable['time'] and work[-1]['continuous']>final['sample']['time']>=clear['time'], 'Workload does not cover session and cleanup')
    if completed_job or battery:
        require(all(0 <= gap <= 6 for gap in (
            native[0]['time']-enable['time'],
            clear['time']-native[-1]['time'],
            final['sample']['time']-clear['time'],
        )), 'Native endpoint coverage missing')
        power_end_wall = max(power_end_wall, work[-1]['wall']-work[-1]['continuous']+final['sample']['time'])
    require(math.isfinite(history['capturedAt']) and all(math.isfinite(r['wall']) and r['kind'] in ('Sleep','DarkWake','Wake') for r in history['records']), 'Invalid power history')
    require(history['command']==['/usr/bin/pmset','-g','log'] and history['capturedAt']>=power_end_wall+2 and
            history['records'] and min(r['wall'] for r in history['records'])<=work[0]['wall'], 'Power history coverage missing')
    require(not any(r['kind']=='Sleep' and work[0]['wall']-1<=r['wall']<=history['capturedAt'] for r in history['records']), 'System slept during session')
    return dict(appDrivenDisposableContinuityVerified=True,closedSeconds=end-begin,sessionSeconds=clear['time']-enable['time'],
                originalPolicyRenewals=len(renewals),workloadSamples=len(work),nativeSamples=len(native),
                proofMode=('battery-' if battery else '') + ('completed-job' if completed_job else 'whole-session-workload'),
                closedWorkSeconds=closed_work_seconds,batteryClosedWorkSeconds=battery_closed_work_seconds,
                observedACToBatteryTransitions=battery_transitions,
                scope=('One attended app-driven AC-to-battery workload' if battery else 'One attended AC-powered app-driven workload') +
                      '; uninterrupted execution of every native Codex task and unattended operation remain unverified')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('directory','workload','power','ledger'):parser.add_argument(name)
    parser.add_argument('--completed-job',action='store_true',help='Verify a job that completed during a longer shared hold, with at least sixty seconds of closed-lid work and native/policy coverage through cleanup')
    parser.add_argument('--battery',action='store_true',help='Require a same-session AC-to-battery transition and at least sixty seconds of continuous closed-lid work on battery above the reserve')
    args=parser.parse_args()
    try: print(json.dumps(verify(args.directory,args.workload,args.power,args.ledger,completed_job=args.completed_job,battery=args.battery),indent=2))
    except (ValueError,KeyError,OSError) as error:parser.exit(1,'UNVERIFIED: '+str(error)+'\n')
