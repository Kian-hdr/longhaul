"""Local Resolve scripting bridge. Requires a compatible installed Resolve API."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from longhaul_common import JobPublisher, root_directory, secure_directory


def connect(app):
    module = app / "Contents/Resources/Developer/Scripting/Modules"
    library = app / "Contents/Libraries/Fusion/fusionscript.so"
    if not module.is_dir() or not library.is_file():
        raise RuntimeError("Resolve scripting components were not found in the selected app.")
    sys.path.insert(0, str(module))
    os.environ["RESOLVE_SCRIPT_LIB"] = str(library)
    import DaVinciResolveScript
    resolve = DaVinciResolveScript.scriptapp("Resolve")
    if resolve is None:
        raise RuntimeError("Resolve is not running or this edition/configuration does not permit local scripting.")
    return resolve


def run(app, probe=False):
    resolve = connect(app)
    if probe:
        print(json.dumps({"connected": True, "version": resolve.GetVersionString(),
                          "product": resolve.GetProductName(), "rendering": bool(resolve.GetProjectManager().GetCurrentProject() and resolve.GetProjectManager().GetCurrentProject().IsRenderingInProgress())}))
        return
    jobs = {}
    try:
        while True:
            manager = resolve.GetProjectManager()
            project = manager.GetCurrentProject()
            active = bool(project and project.IsRenderingInProgress())
            if active:
                name = project.GetName()
                if name not in jobs:
                    jobs[name] = JobPublisher("DaVinci Resolve", "Exporting " + name, True)
                publisher = jobs[name]
                statuses = []
                for item in project.GetRenderJobList() or []:
                    identifier = item.get("JobId") or item.get("jobId")
                    if identifier:
                        statuses.append(project.GetRenderJobStatus(identifier))
                percentages = [s.get("CompletionPercentage") for s in statuses if s and s.get("JobStatus") == "Rendering"]
                publisher.update(**({"progress": min(1, max(0, float(percentages[0]) / 100))} if percentages and percentages[0] is not None else {}))
                for request in publisher.requests():
                    saved = bool(manager.SaveProject())
                    directory = secure_directory(root_directory() / "artifacts" / publisher.id)
                    exported = directory / "project.drp"
                    exported_ok = bool(saved and manager.ExportProject(name, str(exported)))
                    publisher.acknowledge(request, [exported] if exported_ok and exported.is_file() else [],
                                          "Resolve project exported. Restart the export after opening this project; partial encoded output is not resumable.", exported_ok)
            else:
                for name, publisher in jobs.items():
                    # Idle is not proof of a successful export. Inspect the actual queue statuses.
                    statuses = []
                    if project and project.GetName() == name:
                        for item in project.GetRenderJobList() or []:
                            identifier = item.get("JobId") or item.get("jobId")
                            if identifier:
                                statuses.append((project.GetRenderJobStatus(identifier) or {}).get("JobStatus", ""))
                    if statuses and all(s == "Complete" for s in statuses):
                        phase = "completed"
                    elif any(s in ("Cancelled", "Canceled") for s in statuses):
                        phase = "cancelled"
                    else:
                        phase = "failed"
                    publisher.finish(phase)
                jobs.clear()
            time.sleep(5)
    finally:
        for publisher in jobs.values():
            publisher.finish("failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("/Applications/DaVinci Resolve.app"))
    parser.add_argument("--probe", action="store_true")
    arguments = parser.parse_args()
    try:
        run(arguments.app, arguments.probe)
    except Exception as error:
        print(json.dumps({"connected": False, "reason": str(error)}))
        sys.exit(1)
