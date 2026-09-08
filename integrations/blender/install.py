"""Run using Blender --background --python install.py -- INTEGRATIONS ROOT."""
import bpy
import addon_utils
import datetime
import json
from pathlib import Path
import shutil
import sys

args = sys.argv[sys.argv.index('--') + 1:]
source, root = map(Path, args)
if bpy.app.version < (5, 0, 0):
    raise RuntimeError('Longhaul requires Blender 5 or later.')
backup = root / 'recovery' / ('blender-setup-' + datetime.datetime.now().strftime('%Y%m%dT%H%M%S'))
backup.mkdir(parents=True, mode=0o700)
prefs = Path(bpy.utils.user_resource('CONFIG')) / 'userpref.blend'
if prefs.is_file():
    shutil.copy2(prefs, backup / 'userpref.blend')
addons = Path(bpy.utils.user_resource('SCRIPTS', path='addons', create=True))
target = addons / 'longhaul_blender'
if target.exists():
    if target.is_symlink() or not (target / 'LONGHAUL-INTEGRATION').is_file():
        raise RuntimeError('An unrecognized add-on uses the Longhaul folder. No changes were made.')
    shutil.copytree(target, backup / 'longhaul_blender')
target.mkdir(exist_ok=True)
shutil.copy2(source / 'blender' / 'longhaul_blender.py', target / '__init__.py')
shutil.copy2(source / 'longhaul_common.py', target / 'longhaul_common.py')
(target / 'LONGHAUL-INTEGRATION').write_text('Managed Longhaul integration, version 1\n')
bpy.utils.refresh_script_paths()
addon_utils.modules_refresh()
addon_utils.enable('longhaul_blender', default_set=True, persistent=True)
if not addon_utils.check('longhaul_blender')[1]:
    raise RuntimeError('Blender did not enable the Longhaul add-on.')
result = bpy.ops.wm.save_userpref()
if 'FINISHED' not in result:
    raise RuntimeError('Blender could not save its preferences.')
print('LONGHAUL_SETUP_OK ' + json.dumps({'addon': str(target), 'backup': str(backup)}))
