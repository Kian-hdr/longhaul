#!/usr/bin/env python3
import hashlib
import copy
import json
from pathlib import Path
import tempfile
import unittest
from verify_lid_session import verify


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='longhaul-session-evidence-')
        self.root=Path(self.tmp.name)
        self.identity=dict(bootID='00000000-0000-0000-0000-000000000001',sessionID='00000000-0000-0000-0000-000000000002',appPID=999,appBirth=123)
        self.backend=dict(serviceFound=True,openResult=0,callResult=0,closeResult=0)
        def sample(t):
            closed=20<=t<=45
            return dict(time=t,inspection=dict(serviceFound=True,openResult=0,closeResult=0,snapshot=dict(lidClosed=closed,clamshellCausesSleep=not closed,sleepDisabled=False)),
                        powerKnown=True,ownerScanComplete=True,knownOwners=[],
                        power=dict(onAC=True,discharging=False,percent=60,thermalLevel=0,warningLevel=1))
        self.watch=[dict(event='enable-result',time=10,backend=self.backend)]
        self.watch += [dict(event='heartbeat',time=t,sample=sample(t)) for t in range(11,72,5)]
        self.watch += [dict(event='cleanup-result',time=72,backend=self.backend)]
        self.monitor=[dict(event='app-policy',time=t+.01,grant=dict(version=1,identity=self.identity,sequence=i+1,kind='renew',evaluatedAt=t,expiresAt=t+10)) for i,t in enumerate(range(9,72,2))]
        self.monitor += [dict(event='final-observation',time=73,sample=sample(73),cleanupRequired=False)]
        self.work=[];chain=bytes(32)
        for i in range(401):
            chain=hashlib.sha256(chain+i.to_bytes(8,'big')).digest()
            self.work.append(dict(index=i,continuous=i*.2,wall=1000+i*.2,digest=chain.hex()))
        self.work[-1].update(completed=True,startedContinuous=0,requestedSeconds=80)
        self.power=dict(command=['/usr/bin/pmset','-g','log'],capturedAt=1083,records=[dict(wall=900,kind='Wake')])
        self.ledger=dict(version=1,identity=self.identity,stage='cleanupAccepted',cleanupResult=self.backend,enableResult=self.backend,enabledIntentAt=9.9,cleanupAttemptedAt=71.9,updatedAt=72)
    def tearDown(self):self.tmp.cleanup()
    def check(self, completed_job=False, battery=False):
        for name,data in [('monitor.jsonl',self.monitor),('watchdog.jsonl',self.watch),('work.jsonl',self.work)]:
            (self.root/name).write_text(''.join(json.dumps(r)+'\n' for r in data))
        for name,data in [('cleanup-result.json',self.backend),('cleanup-attempt.json',dict(time=72)),('power.json',self.power),('ledger.json',self.ledger)]:
            (self.root/name).write_text(json.dumps(data))
        arguments = dict(completed_job=True) if completed_job else {}
        if battery: arguments["battery"] = True
        return verify(self.root,self.root/'work.jsonl',self.root/'power.json',self.root/'ledger.json',**arguments)
    def rejects(self):
        with self.assertRaises(ValueError):self.check()
    def test_positive(self):self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_forged_deadline(self):self.monitor[9]['grant']['expiresAt']+=20;self.rejects()
    def test_original_lease_only(self):self.monitor=self.monitor[:1]+self.monitor[-1:];self.rejects()
    def test_replayed_policy(self):self.monitor[5]['grant']['sequence']=1;self.rejects()
    def test_changed_identity(self):self.monitor[7]['grant']['identity']=dict(self.identity,appBirth=124);self.rejects()
    def test_policy_gap(self):self.monitor=self.monitor[:2]+self.monitor[12:];self.rejects()
    def test_missing_final_work(self):self.work.pop();self.rejects()
    def test_sleep(self):self.power['records'].append(dict(wall=1025,kind='Sleep'));self.rejects()
    def test_unresolved_ledger(self):self.ledger['stage']='unresolved';self.rejects()
    def test_no_reopen(self):
        for r in self.watch:
            if r.get('sample') and r['time']>45:r['sample']['inspection']['snapshot'].update(lidClosed=True,clamshellCausesSleep=False)
        self.rejects()
    def test_connected_discharge_above_reserve(self):
        self.watch[5]['sample']['power']['discharging']=True
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_battery_reserve(self):self.watch[5]['sample']['power']['percent']=19.9;self.rejects()
    def test_ac_disconnected(self):self.watch[5]['sample']['power']['onAC']=False;self.rejects()
    def test_thermal_warning(self):self.watch[5]['sample']['power']['thermalLevel']=1;self.rejects()
    def test_clear_failed(self):self.watch[-1]=dict(event='cleanup-result',time=72,backend=dict(self.backend,callResult=1));self.rejects()
    def test_work_gap(self):self.work[150]['continuous']+=3;self.rejects()
    def test_native_gap(self):del self.watch[4:6];self.rejects()

    def test_renewals_stop_early(self):self.monitor=self.monitor[:18]+self.monitor[-1:];self.rejects()
    def test_invalid_identity(self):self.identity['appPID']=0;self.rejects()
    def test_invalid_uuid(self):self.identity['bootID']='invalid';self.rejects()
    def test_invalid_power_history(self):self.power['records'].append(dict(wall=float('nan'),kind='Sleep'));self.rejects()
    def test_invalid_inspection(self):self.watch[4]['sample']['inspection']['openResult']=1;self.rejects()
    def test_infinite_battery(self):self.watch[4]['sample']['power']['percent']=float('inf');self.rejects()

    def test_invalid_ledger_version(self):self.ledger['version']=2;self.rejects()
    def test_invalid_ledger_chronology(self):self.ledger['cleanupAttemptedAt']=73;self.rejects()
    def test_divergent_wall_clock(self):
        for r in self.work:r['wall']=1000+2*r['continuous']
        self.power['capturedAt']=1200;self.rejects()
    def test_exactly_sixty_seconds(self):self.watch[-1]['time']=70;self.rejects()


class CompletedJobEvidenceTests(unittest.TestCase):
    """A completed job can end while other jobs keep the same hold active."""
    def setUp(self):
        EvidenceTests.setUp(self)
        template = copy.deepcopy(self.watch[1]['sample'])
        def sample(t):
            value = copy.deepcopy(template)
            value['time'] = t
            value['inspection']['snapshot'].update(lidClosed=20<=t<=90,
                                                   clamshellCausesSleep=not (20<=t<=90))
            return value
        self.watch = [dict(event='enable-result',time=10,backend=self.backend)]
        self.watch += [dict(event='heartbeat',time=t,sample=sample(t)) for t in range(11,142,5)]
        self.watch += [dict(event='cleanup-result',time=142,backend=self.backend)]
        self.monitor = [dict(event='app-policy',time=t+.01,grant=dict(version=1,identity=self.identity,
            sequence=i+1,kind='renew',evaluatedAt=t,expiresAt=t+10)) for i,t in enumerate(range(9,142,2))]
        self.monitor += [dict(event='final-observation',time=143,sample=sample(143),cleanupRequired=False)]
        self.work = []
        chain = bytes(32)
        for i in range(501):
            chain = hashlib.sha256(chain+i.to_bytes(8,'big')).digest()
            self.work.append(dict(index=i,continuous=i*.2,wall=1000+i*.2,digest=chain.hex()))
        self.work[-1].update(completed=True,startedContinuous=0,requestedSeconds=100)
        self.ledger.update(cleanupAttemptedAt=141.9,updatedAt=142)
        self.power['capturedAt'] = 1146
    def tearDown(self):
        EvidenceTests.tearDown(self)
    def check(self):
        return EvidenceTests.check(self,completed_job=True)
    def rejects(self):
        with self.assertRaises(ValueError): self.check()
    def test_completed_job_before_cleanup(self):
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_normal_mode_preserves_full_work_span_requirement(self):
        with self.assertRaisesRegex(ValueError,'Workload does not cover'):
            EvidenceTests.check(self)
    def test_missing_completion(self):
        self.work[-1].pop('completed'); self.rejects()
    def test_broken_completed_hash_chain(self):
        self.work[-1]['digest']='0'*64; self.rejects()
    def test_short_closed_work_overlap(self):
        for row in self.watch:
            if 'sample' in row and row['time']>75:
                row['sample']['inspection']['snapshot'].update(lidClosed=False,clamshellCausesSleep=True)
        self.rejects()
    def test_closed_observations_after_work_do_not_count(self):
        # Closure itself exceeds sixty seconds, but less than sixty seconds of
        # actual sampled closed-lid work occurs before this job completes.
        for row in self.watch:
            if 'sample' in row:
                closed=50<=row['time']<=130
                row['sample']['inspection']['snapshot'].update(lidClosed=closed,clamshellCausesSleep=not closed)
        self.rejects()
    def test_missing_late_grants(self):
        self.monitor=self.monitor[:40]+self.monitor[-1:]; self.rejects()
    def test_missing_late_native_coverage(self):
        self.watch=[r for r in self.watch if r['event']!='heartbeat' or r['time']<100]
        self.rejects()
    def test_missing_initial_native_coverage(self):
        del self.watch[1:3]; self.rejects()
    def test_delayed_final_native_observation(self):
        self.monitor[-1]['time']=150; self.monitor[-1]['sample']['time']=150
        self.power['capturedAt']=1153; self.rejects()
    def test_stale_power_capture_after_work_before_cleanup(self):
        self.power['capturedAt']=1103; self.rejects()
    def test_sleep_after_work_before_cleanup(self):
        self.power['records'].append(dict(wall=1120,kind='Sleep')); self.rejects()
    def test_wrong_ledger_identity(self):
        self.ledger['identity']=dict(self.identity,appBirth=124); self.rejects()
    def test_missing_reopening_before_cleanup(self):
        for row in self.watch:
            if 'sample' in row and row['time']>90:
                row['sample']['inspection']['snapshot'].update(lidClosed=True,clamshellCausesSleep=False)
        self.rejects()
    def test_native_gap_after_work(self):
        self.watch=[r for r in self.watch if r['event']!='heartbeat' or not 110<=r['time']<=120]
        self.rejects()


class BatteryEvidenceTests(unittest.TestCase):
    def setUp(self):
        CompletedJobEvidenceTests.setUp(self)
        for row in self.watch:
            if 'sample' in row and row['time'] >= 21:
                row['sample']['power'].update(onAC=False,discharging=True)
        self.monitor[-1]['sample']['power'].update(onAC=False,discharging=True)
    def tearDown(self): EvidenceTests.tearDown(self)
    def check(self): return EvidenceTests.check(self,completed_job=True,battery=True)
    def rejects(self):
        with self.assertRaises(ValueError): self.check()
    def test_completed_battery_job(self):
        result=self.check()
        self.assertEqual(result['proofMode'],'battery-completed-job')
        self.assertEqual(result['batteryClosedWorkSeconds'],65)
        self.assertEqual(result['observedACToBatteryTransitions'],1)
    def test_whole_session_battery_job(self):
        self.watch=[r for r in self.watch if r['event']!='heartbeat' or r['time']<92]
        self.watch[-1]['time']=92
        self.monitor=[r for r in self.monitor if r['event']!='app-policy' or r['time']<92]
        self.monitor[-1]['time']=93; self.monitor[-1]['sample']['time']=93
        self.ledger.update(cleanupAttemptedAt=91.9,updatedAt=92)
        result=EvidenceTests.check(self,battery=True)
        self.assertEqual(result['proofMode'],'battery-whole-session-workload')
    def test_default_mode_rejects_battery(self):
        with self.assertRaisesRegex(ValueError,'Unsafe conditions'):
            EvidenceTests.check(self,completed_job=True)
    def test_ac_only_cannot_qualify_battery(self):
        for row in self.watch:
            if 'sample' in row: row['sample']['power'].update(onAC=True,discharging=False)
        self.rejects()
    def test_startup_battery_without_transition(self):
        for row in self.watch:
            if 'sample' in row: row['sample']['power'].update(onAC=False,discharging=True)
        self.rejects()
    def test_short_battery_interval(self):
        for row in self.watch:
            if 'sample' in row and row['time']<=40:
                row['sample']['power'].update(onAC=True,discharging=False)
        self.rejects()
    def test_reconnection_breaks_continuous_battery_witness(self):
        next(r for r in self.watch if r['time']==51)['sample']['power'].update(onAC=True,discharging=False)
        self.rejects()
    def test_battery_after_work_does_not_count(self):
        for row in self.watch:
            if 'sample' in row: row['sample']['power'].update(onAC=row['time']<=100)
        self.rejects()
    def test_exact_twenty_percent_battery_reserve(self):
        for row in self.watch:
            if 'sample' in row: row['sample']['power']['percent']=20
        self.monitor[-1]['sample']['power']['percent']=20
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_low_reserve(self): self.watch[6]['sample']['power']['percent']=19.9; self.rejects()
    def test_thermal_warning(self): self.watch[6]['sample']['power']['thermalLevel']=1; self.rejects()
    def test_os_warning(self): self.watch[6]['sample']['power']['warningLevel']=2; self.rejects()
    def test_unknown_power(self): self.watch[6]['sample']['powerKnown']=False; self.rejects()
    def test_fake_on_ac_flags(self):
        sample=self.watch[6]['sample']['power']
        for invalid in (0,1,'false','true',None):
            with self.subTest(onAC=invalid):
                sample['onAC']=invalid; self.rejects()
    def test_fake_discharging_flag(self): self.watch[6]['sample']['power']['discharging']='true'; self.rejects()
    def test_policy_gap(self): self.monitor=self.monitor[:3]+self.monitor[12:]; self.rejects()
    def test_native_gap(self): del self.watch[7:9]; self.rejects()
    def test_late_native_gap(self):
        self.watch=[r for r in self.watch if r['event']!='heartbeat' or r['time']<100]
        self.rejects()
    def test_sleep_after_work(self): self.power['records'].append(dict(wall=1120,kind='Sleep')); self.rejects()
    def test_missing_completion(self): self.work[-1].pop('completed'); self.rejects()
    def test_stale_power_capture(self): self.power['capturedAt']=1103; self.rejects()
    def test_failed_cleanup(self): self.ledger['stage']='cleanupFailed'; self.rejects()


class CutoffPolicyEvidenceTests(unittest.TestCase):
    def setUp(self): BatteryEvidenceTests.setUp(self)
    def tearDown(self): EvidenceTests.tearDown(self)
    def check(self): return EvidenceTests.check(self,completed_job=True,battery=True)
    def rejects(self):
        with self.assertRaises(ValueError): self.check()
    def policy(self, enabled=True, percent=20):
        for row in self.monitor:
            if 'grant' in row:
                row['grant'].update(version=2,batteryPolicy=dict(cutoffEnabled=enabled,cutoffPercent=percent))
    def charge(self, percent):
        for row in self.watch:
            if 'sample' in row: row['sample']['power']['percent']=percent
        self.monitor[-1]['sample']['power']['percent']=percent
    def test_legacy_missing_policy_defaults_to_twenty(self):
        self.charge(20); self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
        self.charge(19.9); self.rejects()
    def test_legacy_policy_key_is_rejected_even_null(self):
        for value in (None,dict(cutoffEnabled=False,cutoffPercent=5)):
            with self.subTest(policy=value):
                self.monitor[0]['grant']['batteryPolicy']=value; self.rejects()
    def test_v2_cutoff_five(self):
        self.policy(percent=5); self.charge(5)
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
        self.charge(4.9); self.rejects()
    def test_v2_off_has_no_hidden_numeric_floor(self):
        self.policy(enabled=False,percent=80); self.charge(0)
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_v2_missing_policy(self):
        self.monitor[0]['grant']['version']=2; self.rejects()
    def test_v2_null_policy(self):
        self.policy(); self.monitor[0]['grant']['batteryPolicy']=None; self.rejects()
    def test_invalid_policy_shape_and_types(self):
        self.policy()
        for value in ({},[],dict(cutoffEnabled=1,cutoffPercent=20),dict(cutoffEnabled='false',cutoffPercent=20),
                      dict(cutoffEnabled=True,cutoffPercent=True),dict(cutoffEnabled=True,cutoffPercent=20.5),
                      dict(cutoffEnabled=True,cutoffPercent=0),dict(cutoffEnabled=True,cutoffPercent=101),
                      dict(cutoffEnabled=False,cutoffPercent=0)):
            with self.subTest(policy=value):
                self.monitor[0]['grant']['batteryPolicy']=value; self.rejects()
    def test_invalid_grant_versions(self):
        for value in (True,1.0,3):
            with self.subTest(version=value):
                self.monitor[0]['grant']['version']=value; self.rejects()
    def test_cutoff_raise_at_sample_is_enforced(self):
        self.policy(percent=5)
        for row in self.monitor:
            if 'grant' in row and row['grant']['evaluatedAt']>=41:
                row['grant']['batteryPolicy']['cutoffPercent']=80
                if row['grant']['evaluatedAt']==41: row['time']=41
        self.rejects()
    def test_future_cutoff_lowering_does_not_authorize_earlier_sample(self):
        self.policy(percent=20)
        for row in self.monitor:
            if 'grant' in row and row['grant']['evaluatedAt']>=41:
                row['grant']['batteryPolicy']['cutoffPercent']=5
        next(r for r in self.watch if r['time']==41)['sample']['power']['percent']=10
        self.rejects()
    def test_evaluated_earlier_but_received_later_cannot_authorize_sample(self):
        self.policy(percent=20)
        for row in self.monitor:
            if 'grant' in row and row['grant']['evaluatedAt']>=41:
                row['grant']['batteryPolicy']['cutoffPercent']=5
                if row['grant']['evaluatedAt']==41: row['grant']['evaluatedAt']=40
        next(r for r in self.watch if r['time']==41)['sample']['power']['percent']=10
        self.rejects()
    def test_cutoff_lowering_received_at_sample_is_effective(self):
        self.policy(percent=20)
        for row in self.monitor:
            if 'grant' in row and row['grant']['evaluatedAt']>=41:
                row['grant']['batteryPolicy']['cutoffPercent']=5
                if row['grant']['evaluatedAt']==41: row['time']=41
        next(r for r in self.watch if r['time']==41)['sample']['power']['percent']=10
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_future_raise_does_not_retroactively_reject_safe_sample(self):
        self.policy(percent=5)
        for row in self.monitor:
            if 'grant' in row and row['grant']['evaluatedAt']>=41:
                row['grant']['batteryPolicy']['cutoffPercent']=80
        for row in self.watch:
            if 'sample' in row and row['time']>41: row['sample']['power']['percent']=90
        self.monitor[-1]['sample']['power']['percent']=90
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_final_sample_uses_effective_policy(self):
        self.policy(percent=5); self.monitor[-1]['sample']['power']['percent']=4; self.rejects()
    def test_off_preserves_unknown_thermal_and_warning_checks(self):
        self.policy(enabled=False,percent=5); self.charge(1)
        sample=self.watch[6]['sample']
        for target,key,value in ((sample,'powerKnown',False),(sample['power'],'thermalLevel',1),
                                 (sample['power'],'warningLevel',2),(sample['power'],'percent',float('nan')),
                                 (sample['power'],'percent',-1),(sample['power'],'percent',True)):
            before=target[key]
            with self.subTest(field=key,value=value):
                target[key]=value; self.rejects()
            target[key]=before
    def test_off_preserves_lease_and_native_gap_checks(self):
        self.policy(enabled=False,percent=5); self.charge(1)
        self.monitor=self.monitor[:3]+self.monitor[12:]; self.rejects()
    def test_nonmonotonic_policy_receipts_rejected(self):
        self.monitor[4]['time']=self.monitor[3]['time']-.1; self.rejects()
    def test_grant_sequence_requires_unsigned_integer(self):
        for value in (True,1.5,2**64):
            with self.subTest(sequence=value):
                self.monitor[0]['grant']['sequence']=value; self.rejects()

    def test_v2_upper_cutoff_boundary(self):
        self.policy(percent=100); self.charge(100)
        self.assertTrue(self.check()['appDrivenDisposableContinuityVerified'])
    def test_revoke_also_requires_valid_policy(self):
        self.policy()
        previous=self.monitor[-2]['grant']
        self.monitor.insert(-1,dict(event='app-policy',time=141.5,grant=dict(previous,sequence=previous['sequence']+1,
            kind='revoke',evaluatedAt=141.5,expiresAt=141.5,batteryPolicy=None)))
        self.rejects()
    def test_native_samples_after_revoke_are_not_authorized(self):
        self.policy()
        self.monitor=[r for r in self.monitor if 'grant' not in r or r['grant']['evaluatedAt']<91]
        previous=self.monitor[-2]['grant']
        self.monitor.insert(-1,dict(event='app-policy',time=91,grant=dict(previous,sequence=previous['sequence']+1,
            kind='revoke',evaluatedAt=91,expiresAt=91)))
        with self.assertRaisesRegex(ValueError,'Native sample outside original lease'): self.check()
    def test_enable_cannot_precede_first_grant_receipt(self):
        self.monitor[0]['time']=11
        with self.assertRaisesRegex(ValueError,'Policy does not cover physical interval'): self.check()


if __name__=='__main__':unittest.main()
