# SketchUp MCP for SketchUp Make 2017

An MCP (Model Context Protocol) server that lets Claude and other MCP clients see,
inspect and edit the model open in **SketchUp Make 2017**.

It is a fork of [Tarkiin/sketchup-mcp](https://github.com/Tarkiin/sketchup-mcp)
(commit `a47ca45`, MIT licence), which targets SketchUp 2024–2026. This fork is
patched to run on Make 2017 (Ruby 2.2) and adds tools for working on survey models
of real buildings: screenshots, measuring, geometry audits, and guarded edits such
as moving walls or cutting door openings.

![MCP](https://img.shields.io/badge/MCP-Compatible-brightgreen)
![Python](https://img.shields.io/badge/Python-3.10+-blue)
![SketchUp](https://img.shields.io/badge/SketchUp-Make%202017-orange)
![License](https://img.shields.io/badge/License-MIT-yellow)

## How it works

```
┌──────────────┐    MCP (stdio)    ┌──────────────┐    HTTP :8080    ┌──────────────┐
│  MCP client  │ ◄───────────────► │  Python MCP  │ ◄──────────────► │   SketchUp   │
│  (Claude…)   │                   │  server      │                  │  Ruby plugin │
└──────────────┘                   └──────────────┘                  └──────────────┘
```

1. **Ruby plugin** (`sketchup_plugin/sketchup_mcp_server.rb`) runs inside SketchUp and
   serves a small HTTP API on `127.0.0.1:8080`.
2. **Python MCP server** (`src/sketchup_mcp/`) translates MCP tool calls into requests to
   that plugin.

## Changes from the original

| Change | Why |
|---|---|
| Removed Ruby 2.3+ syntax (`&.`) | Make 2017 ships Ruby 2.2; the original file would not load at all |
| Server polls on SketchUp's main thread (no Ruby threads) | Background threads stall inside SketchUp when it is idle, causing hangs/timeouts |
| All lengths are in **metres** (or cm, mm, inches; see [Units](#units)) | SketchUp's API always works in inches; the original passed numbers through unchanged, so "4" meant 4 inches |
| Python dependency pinned to `mcp < 2` | `mcp` 2.x removed the API this server uses |
| Tool descriptions tell the model about Ruby 2.2 and Make limits | So it doesn't write code that fails on 2017 or needs SketchUp Pro |
| 17 new tools (see below) | Seeing, understanding and safely editing an existing model |

Tested in SketchUp Make 2017 on Windows. Other SketchUp versions are not supported by
this fork; use the [original project](https://github.com/Tarkiin/sketchup-mcp) for
SketchUp 2024 and later.

---

## Setup on Windows

### 1. Install the SketchUp plugin

1. Close SketchUp.
2. Copy `sketchup_plugin\sketchup_mcp_server.rb` into
   `%APPDATA%\SketchUp\SketchUp 2017\SketchUp\Plugins\`
   (paste that path into the File Explorer address bar).
3. Start SketchUp Make 2017. If it asks whether to load an unidentified extension, allow it.
   Pick a metric template (e.g. *Architectural Design – Meters*) so the model displays in metres.
4. Check: **Window → Ruby Console** should show
   `Server started on http://127.0.0.1:8080 (lengths in m)`.
   You also get an **Extensions → MCP Server** menu (Start / Stop / Status).

### 2. Install the Python server

1. Clone this repository somewhere permanent, e.g. `C:\Tools\sketchup-mcp-make2017`:
   ```powershell
   git clone https://github.com/ToungaGH/SketchupMake_MCP.git C:\Tools\sketchup-mcp-make2017
   ```
   (Or download the ZIP from GitHub and unzip it there.)
2. Install **uv** (Python manager). In PowerShell:
   ```powershell
   powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
   ```
   Close and reopen PowerShell afterwards.
3. Install the server:
   ```powershell
   cd C:\Tools\sketchup-mcp-make2017
   uv sync
   ```
   (uv downloads a suitable Python automatically if you don't have 3.10+.)

### 3. Connect it to Claude

1. In the Claude desktop app: **Settings → Developer → Edit Config**. This opens
   `claude_desktop_config.json`.
2. Add (adjust the path if you installed elsewhere):
   ```json
   {
     "mcpServers": {
       "sketchup": {
         "command": "uv",
         "args": ["--directory", "C:\\Tools\\sketchup-mcp-make2017", "run", "sketchup-mcp"]
       }
     }
   }
   ```
   If the file already has an `"mcpServers"` section, add only the `"sketchup"` entry inside it.
3. Fully quit Claude (system tray → Quit) and reopen it.
4. With SketchUp open, ask Claude: *"Get the SketchUp model info."*
   You should see `"tool_unit": "m"` in the answer (or the unit you configured).

Other MCP clients (Claude Code, Cursor, …) use the same command and arguments.

### Units

Tools take and return lengths in metres by default. To work in centimetres, millimetres or
inches instead, add an `env` entry to the `sketchup` server in the config above:

```json
"sketchup": {
  "command": "uv",
  "args": ["--directory", "C:\\Tools\\sketchup-mcp-make2017", "run", "sketchup-mcp"],
  "env": { "SKETCHUP_MCP_UNIT": "cm" }
}
```

Allowed values: `m`, `cm`, `mm`, `inch`. Restart Claude after changing it. The tool
descriptions Claude sees switch to the same unit, so it sends and reads numbers in that unit.
Internal tolerances are fixed real-world sizes (e.g. 1.5 mm) whatever the unit.

This is independent of the units SketchUp *displays* (Window → Model Info → Units). The
roof-truss tool keeps its original US units (span in feet, other sizes in inches).

---

## Tools

All coordinates are in the configured unit (metres by default), in **world space** (group/component transforms applied).
Entities are identified by **`persistent_id`**, which is stable across sessions, not by
`id` (SketchUp's `entityID`, reassigned every session).

Groups are named by their SketchUp name. The understanding and editing tools below find a
group at any nesting depth; the view tools (`isolate`, `zoom_to`, `select` by name) work
with top-level groups. If two groups share a name, the tools refuse and list where they are,
rather than guessing. A top-level group takes precedence over nested groups of the same name.

### From the original project

| Group | Tools |
|---|---|
| Query | `get_model_info`, `list_layers`, `list_materials`, `list_entities`, `list_components` |
| Create | `create_face`, `create_edge`, `create_group`, `create_box`, `create_circle`, `create_arc`, `create_polygon` |
| Geometry | `push_pull`, `follow_me` |
| Transform | `move_entity`, `rotate_entity`, `scale_entity` |
| Components | `create_component`, `place_component` |
| Construction | `create_roof_truss` |
| Advanced | `execute_ruby` (run arbitrary Ruby inside SketchUp) |

The server also exposes reference documents on roof trusses, framing and stairs as MCP
resources (`resources/`).

### Seeing

Read-only; none of these change the model or the undo stack.

| Tool | Inputs | Notes |
|---|---|---|
| `get_selection` | – | The current selection: `id`, `persistent_id`, `type`, `layer`, world `bounds_min`/`bounds_max`; faces also get `normal` and `plane_point`. Works for a face selected inside a group open for editing. |
| `select` | `ids` (persistent_id array) or `group_names` | Replaces the selection. SketchUp can only select entities in the active editing context; a target nested elsewhere is replaced by its container in that context, and the reply's `notes` explain the substitution. |
| `zoom_to` | `ids` or `group_names` | Zooms the view to those entities. |
| `screenshot` | `view` (`"current"` / `"iso"` / `"top"` / `"front"` / `"back"` / `"left"` / `"right"` / `{eye:[x,y,z], target:[x,y,z]}`), `width` (default 1280, max 1920), `height`, `hide_tags:[…]`, `isolate:[group names]`, `zoom_to:[group names]`, `section:{z: 1.0}`, `hide_guides` (default `true`) | Returns a PNG. Named and custom views are orthographic and zoomed to fit. `section:{z:…}` cuts horizontally for a floor plan. The camera, tag visibility, hidden entities and section plane are all restored afterwards, and the model's modified flag is left alone. |

### Understanding

Read-only.

| Tool | Inputs | Notes |
|---|---|---|
| `list_wall_planes` | `group` (required), `axis` (`"x"`/`"y"`, omit for both), `min_height` (default 1 m), `recursive` (default false) | Vertical, axis-aligned faces in `group`, grouped by plane coordinate. Faces within 1.5 mm are clustered into one entry (`{axis, at, spans:[…]}`). Faces shorter than `min_height` are skipped so sills and lintels don't clutter the list. |
| `measure` | One of: `point_a`+`point_b`; `face_id_a`+`face_id_b`; `axis`+`at` (+ optional `group`) | Probe mode (`axis`+`at`) fires a line along `axis` at the two fixed coordinates in `at` (e.g. `{"y":6.0,"z":1.0}` for `axis:"x"`) and returns every face it crosses, in order, plus the gaps between them: wall thicknesses and room widths directly. Openings are respected. With `group`, groups nested inside it are probed too, and each crossing names the innermost group it belongs to. |
| `audit_geometry` | `group` (omit to audit every top-level group), `details` | Recurses into nested groups. Without `group`, returns only the counts per group unless `details: true`. Reports face/edge counts and: stray edges, open edges, non-manifold edges, duplicate edges (the "deleting a line deletes the wall" problem), near-coincident vertices (< 2 mm), tiny faces (< 0.005 m²), non-planar faces, and mergeable coplanar seams. Each category returns up to 50 locations plus a total. |
| `changes_since` | `token` (optional; omit on the first call) | Returns `{token, modified, changed}`, so the assistant can tell whether the model was edited since it last looked. Treat `token` as an opaque string. |

### Editing safely

Every editing tool makes **exactly one undo step**, runs a post-check, and returns a change
report. `dry_run: true` measures everything and rolls back, so it reports what *would* happen.

The post-check, on every edit:

- **aborts** (changing nothing) if any face would be left non-planar;
- **aborts** if the edit split faces unexpectedly (pass `allow_splits: true` when a split is intended);
- deletes edges the edit stranded (pre-existing stray edges are left alone);
- reports before/after/delta for faces, edges, open edges and near-coincident vertex pairs.

| Tool | Inputs | Notes |
|---|---|---|
| `move_plane` | `group`, `axis`, `from`, `to`, optional `x_range`/`y_range`/`z_range`, `include`/`exclude`, `tolerance` (default 0.0015 m), `dry_run`, `allow_splits`, `allow_distortion` | Moves every vertex on one axis-aligned plane by `to - from`. The wall-move / room-resize operation. |
| `remap_planes` | `group`, `axis`, `map: [{from,to}, …]`, optional `shift_beyond: {from, delta}`, same options as `move_plane` | Several plane moves in one undo step. Refuses if a vertex lies strictly between mapped planes with no rule covering it, since that vertex would stay put while its neighbours move. |
| `cut_opening` | `group`, `axis` (`x`/`y`), `wall_faces: [outer, inner]`, `y_range` (or `x_range`), `z_range`, `from_floor`, optional `frame`, `dry_run` | Cuts a hole through both wall faces and adds side and head reveals. `from_floor: true` makes a door (no sill). Refuses if an opening already exists there. Optional `frame` builds a solid U-shaped frame. Reports a `self_check` that the opening is clear and its surroundings still covered. |
| `fill_opening` | same rectangle arguments | Removes the reveals and refills both wall faces, copying material and orientation from the neighbouring face, so each side is one face again. |
| `merge_coplanar` | `group`, `dry_run`, `ignore_back_material` | Erases seam edges between coplanar faces with the same orientation and material. |
| `weld_vertices` | `group`, `tolerance` (default 0.002 m), `dry_run`, `allow_splits`, `cross_group`, `keep` | Merges near-coincident vertex pairs by moving one onto the other. |
| `add_dimension` | `point_a`, `point_b`, optional `offset`, `tag` (default `Dimensions`) | Adds a real linear dimension, not a text label. |
| `save` / `save_copy` | `save_copy` takes an optional `suffix` (default: timestamp) | `save_copy` writes `<name>_<suffix>.skp` next to the original and leaves the open file untouched. Take a backup before a risky batch of edits. |

#### Guards against silent distortion

Moving *part* of a rectangular wall face does not split it or make it non-planar: the face
just **tilts**, staying perfectly flat, so every structural check passes while the wall is
now skewed. `move_plane` and `remap_planes` therefore refuse, before changing anything, when:

- within one face, only *some* of the corners on the moved plane would move; or
- a vertical or horizontal face would stop being vertical or horizontal.

A face merely *touching* the plane is fine: a perpendicular wall with two corners on the
plane has both of them move, and simply stretches. Override with `allow_distortion: true`.

#### Check the per-collection counts

A plane move takes *everything* on that plane, including geometry that only happens to
share it, such as a door frame sitting flush with a wall face. The report breaks the moved
vertices down by the group they live in, e.g.
`{"Basement": 8, "Basement/Rear wall": 12, "Basement/Garden door – frame": 8}`, and a move
that spans more than one group is refused unless you name the groups to move in `include`
(or leave some out with `exclude`). Read this breakdown in a `dry_run` before applying.

---

## Tips

- Give Claude outer dimensions, wall thicknesses (e.g. outer 0.30 m, inner 0.10 m), room sizes
  and door/window positions. A photo of a hand sketch with measurements works well.
- Ask it to put walls, doors and windows on separate tags so you can hide them.
- Ask for a `screenshot` after each change so it can check its own work.
- For a 2D plan: *Camera → Standard Views → Top* and *Camera → Parallel Projection*,
  then *File → Export → 2D Graphic*.
- Each tool call is one undo step, so Ctrl+Z works if something goes wrong.

## Security

The plugin runs a small web server inside SketchUp, reachable only from your own computer
(`127.0.0.1`). Through `execute_ruby` it can run any Ruby code, and Ruby inside SketchUp can
do anything your Windows account can. Two things follow from that:

- **Web pages cannot use it.** A web page open in your browser could otherwise send requests
  to `127.0.0.1:8080` and run code on your machine. The plugin therefore refuses any request
  that comes from a browser (it carries an `Origin` header), any request addressed to
  another host name, and any request without the `X-SketchUp-MCP-Unit` header that the
  Python server always sends. MCP clients are not affected, since they all go through the
  Python server.
- **Review what Claude runs.** Text inside a model, such as a group name in a file downloaded
  from 3D Warehouse, can contain instructions aimed at the AI. Leave `execute_ruby` on "ask
  every time" in your MCP client rather than "always allow", and read the code before
  approving it.

SketchUp Make 2017 has not had security updates since 2017, so only open `.skp` files from
sources you trust, with or without this plugin.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Port 8080 already in use" | Another program uses 8080. Change `PORT = 8080` in the `.rb` file (e.g. to `8765`) and add `"env": {"SKETCHUP_MCP_HOST": "http://127.0.0.1:8765"}` to the `sketchup` entry in the Claude config |
| "The SketchUp plugin does not support SKETCHUP_MCP_UNIT" | The plugin in SketchUp is older than the Python server. Copy the current `sketchup_mcp_server.rb` into the Plugins folder and restart SketchUp |
| Claude says it cannot connect to SketchUp | SketchUp must be open with the server started (Extensions → MCP Server → Server Status) |
| No MCP Server menu / nothing in Ruby Console | Check the file is in the 2017 Plugins folder and not blocked by Windows (right-click → Properties → Unblock) |
| Errors mentioning `subtract`, `union`, `outer_shell` | Those are SketchUp Pro only; ask Claude to draw the geometry directly instead |
| "Refused: …" (403) | The request did not come from the Python server, e.g. a hand-written test. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the headers to send |
| Anything else | Check `%TEMP%\sketchup_mcp_debug.log` and Window → Ruby Console |

Implementation notes and SketchUp 2017 API gotchas are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Licence

MIT. See [LICENSE](LICENSE). Original work © Tarkiin.
