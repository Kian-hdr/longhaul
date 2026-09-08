# Longhaul licensing record

On 2026-09-06, the owner selected GNU GPLv3 for Longhaul. The project uses
**GNU General Public License version 3 only (SPDX: GPL-3.0-only)**. This records
version 3 without extending the grant to later license versions.

Copyright © 2026 Kian Konrad Tajbakhsh. Created by Kian Konrad Tajbakhsh.

Longhaul is free software: you may redistribute it and/or modify it under the
GNU General Public License version 3 as published by the Free Software Foundation.
It is distributed without any warranty, including the implied warranties of
merchantability or fitness for a particular purpose. The exact terms are in
[LICENSE](LICENSE), downloaded verbatim from the
[Free Software Foundation](https://www.gnu.org/licenses/gpl-3.0.txt).
The identifier follows [SPDX](https://spdx.org/licenses/GPL-3.0-only.html).
The app bundles the same file and exposes it through About Longhaul.

## Component inventory

This inventory covers the v1.0.0 source and app configuration. Final binary
contents must match this inventory before publication.

| Component | Shipped form and origin | License evidence | Duties and compatibility | Action / confidence |
| --- | --- | --- | --- | --- |
| Longhaul app, core, bridge, CLI and relay | Original source and compiled binaries in this repository | Owner's explicit GPLv3 selection; LICENSE | Preserve copyright/license/no-warranty notices; distribute corresponding source for conveyed binaries under GPLv3 | Apply GPL-3.0-only; directly inspected |
| Integration scripts, including Blender add-on | Original Python and shell source in integrations/ | Same project license | Preserve notices and provide source; GPLv3-compatible licensing selected for the add-on | No separate proprietary add-on license; directly inspected |
| App icon | Original drawing in script/make_icon.swift, generated Resources/Longhaul.icns and Resources/Longhaul.png | Same project license | Keep editable generator with source | No downloaded artwork; directly inspected |
| Documentation and build scripts | Original repository files | Same project license unless a file explicitly states otherwise | Keep notices and scripts needed to build/install the corresponding binaries | Directly inspected |
| Apple SDKs, system frameworks, system SQLite and runtime SF Symbols | System-provided APIs/assets used at runtime; no vendored framework or symbol artwork | Installed SDK/framework interfaces; Package.swift and project.yml | Third-party/system terms remain their own; this project does not relicense Apple assets | Recheck final distribution against applicable platform terms |
| GNU license document | Verbatim FSF text in LICENSE and app resources | Copy permission stated in the document | Preserve verbatim, including FSF copyright | Canonical text downloaded and bundled unchanged |
| Nodebay, Amphetamine, Blender, Resolve and Codex applications | Separate external applications; not bundled here | This repository's integration boundaries | Their licenses remain separate; no implementation files from them are copied here | No external app relicensing or redistribution claimed |

Package.swift contains only local targets and no fetched third-party packages.
No updater, analytics, payment SDK, model, dataset, custom font or downloaded
media is bundled. No additional patent license, trademark grant or licensing
exception is added beyond the selected license itself.

This resolves the governing-license decision. It does not establish public
release readiness, App Store compatibility or blanket clearance for future
dependencies. Before any distribution, recheck the actual artifact inventory,
retain notices, and offer corresponding source for the exact binaries using a
GPLv3-compliant distribution route. The release owner verifies the final artifact against this inventory.
