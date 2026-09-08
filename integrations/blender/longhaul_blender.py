bl_info = {"name": "Longhaul Job Protection", "author": "Longhaul contributors",
           "version": (0, 1, 0), "blender": (5, 0, 0), "location": "Automatic render handlers",
           "description": "Reports render lifecycle and saves recovery scene copies", "category": "System"}

import bpy
from bpy.app.handlers import persistent
from pathlib import Path
import sys

# Installed beside this module; development layout keeps the shared bridge one level up.
for folder in [Path(__file__).parent, Path(__file__).parent.parent]:
    if (folder / "longhaul_common.py").exists() and str(folder) not in sys.path:
        sys.path.insert(0, str(folder))
from longhaul_common import JobPublisher, root_directory, secure_directory

_job = None
_scene_copy = None
_frames = []


def checkpoint(scene):
    if _job is None:
        return
    for request in _job.requests():
        paths = ([_scene_copy] if _scene_copy and _scene_copy.is_file() else []) + list(_frames[-31:])
        _job.acknowledge(request, paths,
                         "Recovery scene captured at render start; completed frame outputs listed. Restart the remaining frames in Blender.",
                         bool(_scene_copy and _scene_copy.is_file()))


@persistent
def render_start(scene, *_):
    global _job, _scene_copy, _frames
    if _job is not None:
        _job.finish("cancelled")
    _job = JobPublisher("Blender", "Rendering " + (Path(bpy.data.filepath).stem or "Untitled scene"), True)
    _frames = []
    _scene_copy = secure_directory(root_directory() / "artifacts" / _job.id) / "render-start.blend"
    try:
        outcome = bpy.ops.wm.save_as_mainfile(filepath=str(_scene_copy), copy=True)
        if "FINISHED" not in outcome:
            _scene_copy = None
    except Exception:
        _scene_copy = None
    checkpoint(scene)


@persistent
def render_write(scene, *_):
    if _job is None:
        return
    path = Path(bpy.path.abspath(scene.render.frame_path(frame=scene.frame_current)))
    if path.is_file() and path not in _frames:
        _frames.append(path)
    count = max(1, scene.frame_end - scene.frame_start + 1)
    _job.update(progress=min(1, max(0, (scene.frame_current - scene.frame_start + 1) / count)),
                **({"outputPath": str(path)} if path.is_file() else {}))
    checkpoint(scene)


def finish(scene, phase):
    global _job
    if _job is not None:
        checkpoint(scene)
        _job.finish(phase)
        _job = None


@persistent
def render_complete(scene, *_):
    finish(scene, "completed")


@persistent
def render_cancel(scene, *_):
    finish(scene, "cancelled")


def register():
    for name, callback in [("render_init", render_start), ("render_write", render_write),
                            ("render_complete", render_complete), ("render_cancel", render_cancel)]:
        handlers = getattr(bpy.app.handlers, name)
        if callback not in handlers:
            handlers.append(callback)


def unregister():
    global _job
    for name, callback in [("render_init", render_start), ("render_write", render_write),
                            ("render_complete", render_complete), ("render_cancel", render_cancel)]:
        handlers = getattr(bpy.app.handlers, name)
        if callback in handlers:
            handlers.remove(callback)
    if _job:
        _job.finish("cancelled")
        _job = None
