"""Lifecycle and privacy contracts using synthetic payloads, never real conversations."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys

cli = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='longhaul-hook-test-') as folder:
    root = Path(folder)
    def call(command, payload=None):
        result = subprocess.run([str(cli), '--root', folder, *command], input=json.dumps(payload).encode() if payload else None, capture_output=True, check=True, timeout=5)
        return json.loads(result.stdout or b'{}')
    def hook(event, **extra):
        payload = dict(session_id='test-session', turn_id='test-turn', hook_event_name=event, prompt='PRIVATE_PAYLOAD_MUST_NOT_BE_STORED')
        payload.update(extra)
        return call(['hook', 'fixture'], payload)
    def event():
        return call(['status'])[0]
    assert hook('UserPromptSubmit') == {}
    assert event()['phase'] == 'running'
    hook('PreToolUse'); assert event()['phase'] == 'waiting'
    hook('PermissionRequest'); assert event()['phase'] == 'needsInput'
    hook('PostToolUse'); assert event()['phase'] == 'running'
    e = event()
    request = dict(id='recovery-request', jobID=e['id'], source=e['source'], session=e['session'], reason='test', deadline=(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))
    name = hashlib.sha256(request['id'].encode()).hexdigest()+'.json'
    (root/'requests'/name).write_text(json.dumps(request))
    response = hook('PreToolUse')
    assert 'checkpoint-ack' in response['hookSpecificOutput']['additionalContext']
    artifact = root/'saved.txt'; artifact.write_text('Durable test output\n')
    call(['checkpoint-ack', request['id'], '--files', str(artifact)])
    assert len(list((root/'receipts').glob('*.json'))) == 1
    assert hook('Stop') == {}; assert event()['phase'] == 'completed'
    stop_sequence = event()['sequence']
    assert event()['continuableHookStop'] == stop_sequence
    hook('PreToolUse'); assert event()['phase'] == 'waiting'
    assert event()['continuableHookStop'] == stop_sequence
    hook('PostToolUse'); assert event()['phase'] == 'running'
    hook('Interrupt'); assert event()['phase'] == 'cancelled'
    hook('PreToolUse'); assert event()['phase'] == 'cancelled'
    hook('UserPromptSubmit', turn_id='second-turn')
    hook('Stop', turn_id='second-turn')
    call(['hook','fixture'], dict(session_id='test-session',hook_event_name='SessionEnd',reason='other'))
    hook('PreToolUse', turn_id='second-turn')
    hook('Stop', turn_id='second-turn')
    hook('PostToolUse', turn_id='second-turn')
    assert all(e['phase'] in ('completed','cancelled') for e in call(['status']))
    for path in root.rglob('*.json'):
        assert 'PRIVATE_PAYLOAD_MUST_NOT_BE_STORED' not in path.read_text()
    # A malformed local producer must not block the policy reader while opening a FIFO.
    for name in ['events', 'requests']:
        os.mkfifo(root/name/'malformed-fifo.json', 0o600)
    assert len(call(['status'])) == 2
    hook('PreToolUse')
print('PASS: hook lifecycle, terminal guards, session cleanup, checkpoint acknowledgement, payload privacy and bounded FIFO rejection')

# Public setup commands share the native app's checked installer. All profiles,
# recovery output and command aliases here are disposable fixtures.
with tempfile.TemporaryDirectory(prefix='longhaul-setup-cli-') as folder:
    base = Path(folder).resolve()
    home = base/'home'; home.mkdir(mode=0o700)
    profile = home/".codex-work's profile"; profile.mkdir(mode=0o700)
    (profile/'config.toml').write_text('# Fixture only; contents must not be read.\n')
    mailbox = base/'mailbox'
    ignored = home/'.codex-no-config'; ignored.mkdir(mode=0o700)
    alias_profile = home/'.codex-link'; alias_profile.symlink_to(profile)
    def setup(*args, executable=cli, success=True):
        result = subprocess.run([str(executable), '--root', str(mailbox), *args], capture_output=True, timeout=5)
        assert (result.returncode == 0) == success, (args, result.stderr.decode())
        return json.loads(result.stdout) if success else result
    assert setup('profiles', '--home', str(home)) == [dict(name=profile.name, path=str(profile))]
    assert setup('hooks', 'status', '--profile', str(profile))['state'] == 'Not installed'
    assert not mailbox.exists(), 'Read-only setup commands must not create a mailbox'
    unrelated = dict(customMetadata=dict(preserve=True), hooks=dict(Stop=[dict(hooks=[dict(type='command', command='true')])]))
    hooks = profile/'hooks.json'; hooks.write_text(json.dumps(unrelated))
    original = hooks.read_bytes()
    installed = setup('hooks', 'install', '--profile', str(profile))
    assert installed['managedCount'] == 9 and installed['state'] == 'Installed / Needs trust'
    assert installed['trustVerified'] is False and installed['hooksPath'] == str(hooks)
    config = json.loads(hooks.read_text())
    assert config['customMetadata'] == unrelated['customMetadata']
    assert config['hooks']['Stop'][0] == unrelated['hooks']['Stop'][0]
    assert any(p.read_bytes() == original for p in (mailbox/'recovery').glob('*.backup'))
    assert setup('hooks', 'install', '--profile', str(profile))['managedCount'] == 9
    # A PATH symlink must resolve to the same native executable identity, so it
    # installs and removes the same groups as the app's bundled command path.
    alias = base/'longhaul-alias'; alias.symlink_to(cli)
    assert setup('hooks', 'status', '--profile', str(profile), executable=alias)['managedCount'] == 9
    assert setup('hooks', 'install', '--profile', str(profile), executable=alias)['managedCount'] == 9
    assert str(alias) not in hooks.read_text()
    assert setup('hooks', 'remove', '--profile', str(profile), executable=alias)['managedCount'] == 0
    assert json.loads(hooks.read_text()) == unrelated
    setup('hooks', 'install', '--profile', str(profile))
    config = json.loads(hooks.read_text())
    config['hooks']['PreToolUse'][0]['hooks'][0]['timeout'] = 99
    hooks.write_text(json.dumps(config)); modified = hooks.read_bytes()
    assert setup('hooks', 'status', '--profile', str(profile))['state'] == 'Needs attention'
    setup('hooks', 'install', '--profile', str(profile), success=False)
    assert hooks.read_bytes() == modified
    setup('hooks', 'remove', '--profile', str(profile))
    remaining = json.loads(hooks.read_text())
    assert remaining['hooks']['PreToolUse'] == config['hooks']['PreToolUse']
    assert remaining['hooks']['Stop'] == unrelated['hooks']['Stop']
    setup('hooks', 'status', '--profile', 'relative', success=False)
    setup('hooks', 'unknown', '--profile', str(profile), success=False)
    setup('profiles', '--home', str(base/'missing'), success=False)
    setup('hooks', 'status', '--profile', str(alias_profile), success=False)
    help_result = subprocess.run([str(cli), '--help'], capture_output=True, check=True, timeout=5)
    assert b'hooks status|install|remove' in help_result.stdout
print('PASS: public profile discovery, read-only status, exact install/remove, backups, executable aliases and trust boundaries')
