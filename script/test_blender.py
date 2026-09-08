"""Disposable two-frame render and scene recovery test, invoked with Blender -b."""
import bpy
import importlib.util
import os
from pathlib import Path
import sys
import time
import json

repository = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("longhaul_blender", repository / "integrations/blender/longhaul_blender.py")
addon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addon)
addon.register()
def allow_checkpoint_test(scene, *_):
    if os.environ.get("LONGHAUL_TEST_WAIT"):
        time.sleep(int(os.environ["LONGHAUL_TEST_WAIT"]))
bpy.app.handlers.render_init.append(allow_checkpoint_test)
root = Path(os.environ["LONGHAUL_DATA_DIR"])
output = root / "render-test"
output.mkdir(parents=True, exist_ok=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 1
scene.render.resolution_x = 32
scene.render.resolution_y = 32
scene.render.resolution_percentage = 100
scene.frame_start = 1
scene.frame_end = 2
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = str(output / "frame-")
bpy.ops.render.render(animation=True)
frames = list(output.glob("*.png"))
assert len(frames) == 2, frames
copies = list((root / "artifacts").glob("*/render-start.blend"))
assert copies and copies[0].stat().st_size > 0
if os.environ.get("LONGHAUL_TEST_WAIT"):
    receipts = [json.loads(p.read_text()) for p in (root / 'receipts').glob('*.json')]
    assert any(r['source'] == 'Blender' and r['success'] and r['savedPaths'] for r in receipts), receipts
addon.unregister()
bpy.ops.wm.open_mainfile(filepath=str(copies[0]))
assert bpy.context.scene.frame_end == 2
print("LONGHAUL_BLENDER_TEST_PASSED", len(frames), "frames and reopened recovery scene")
