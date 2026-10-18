# Development notes

Implementation notes for the tools this fork adds, and the SketchUp Make 2017 API
behaviour they work around. See the [README](../README.md) for setup and tool usage.

## Constraints

- **Ruby 2.2.** No `&.`, no `<<~`, no `Array#sum`, no `then`. Solid tools
  (`union`, `subtract`, `outer_shell`, …) are SketchUp Pro only.
- **Units.** The Ruby API works in inches. Every tool takes and returns lengths in the
  unit set by `SKETCHUP_MCP_UNIT` (default metres), in world coordinates, with
  group/instance transforms applied at any nesting depth. The Python server sends the unit
  on every request in an `X-SketchUp-MCP-Unit` header; the plugin echoes it back, and the
  server refuses to continue if it doesn't (an older plugin would silently use metres). In
  the plugin, convert caller-supplied lengths with `len` / `out_len` / `out_area`, and
  internal tolerances or defaults, which are fixed real-world sizes, with `metres(…)`.
  Tool descriptions are written in metres; `server.py` rewrites them for other units, so
  write fixed sizes in descriptions as real-world sizes ("default 1.5 mm"), not bare numbers.
- **Undo.** Every modifying tool runs inside one `start_operation` … `commit_operation`
  and calls `abort_operation` on any exception, so each call is one undo step.

## Adding a tool

A tool is one `types.Tool(...)` entry plus a dispatch case in
`src/sketchup_mcp/server.py`, and one `handle_<name>` method registered in `ROUTES` in
`sketchup_plugin/sketchup_mcp_server.rb`. Modifying tools should go through the shared
`with_edit` harness, which provides the undo step, `dry_run`, the post-check and the
change report.

To reload the Ruby plugin without restarting SketchUp, copy the updated file into the
Plugins folder and run this in the Ruby Console:

```ruby
load File.join(Sketchup.find_support_file('Plugins'), 'sketchup_mcp_server.rb')
```

The running server keeps going and picks up the redefined handlers. Restart the MCP
client to pick up Python changes. A debug log is written to `%TEMP%\sketchup_mcp_debug.log`.

## SketchUp 2017 gotchas

- **`view.camera` is a live wrapper, not a snapshot.** `saved = view.camera; …change
  camera…; view.camera = saved` does nothing: `saved` tracks the current camera. Capture
  `eye`/`target`/`up`/`perspective?`/`fov`/`height` as plain values and rebuild a
  `Sketchup::Camera` to restore. `handle_screenshot` does this.
- **`view.write_image` followed immediately by `view.refresh` can crash SketchUp** (a hard
  crash, not a Ruby exception) on some GPU/driver combinations. `screenshot` refreshes
  once, *before* `write_image`, and lets SketchUp repaint on its own afterwards.
- **`Sketchup.send_action("viewTop:")` silently does nothing** when called from a
  timer-driven context rather than a user gesture. Named views build the camera directly
  with `Sketchup::Camera.new` from `model.bounds` instead.
- **Up vector.** A camera looking straight down with `up = Z_AXIS` raises "Up vector cannot
  be parallel to view direction". `up` falls back to the Y axis when the view direction is
  within ~2.5° of vertical.
- **No `model.active_path=`.** A group cannot be opened for editing from Ruby, so testing
  nested-context behaviour needs a person to double-click into the group.
- **Section plane normal.** `add_section_plane(point, normal)` hides the geometry the normal
  points toward. For a floor plan (hide everything above the cut), use `[0, 0, 1]`.
- **Origin axes in screenshots.** `rendering_options["DisplaySketchAxes"]` must be turned
  off for the shot, or the axes show as lines across the plan.
- **Socket encoding.** Request bodies are not guaranteed to arrive as UTF-8; accented group
  names then break `JSON.generate`. The plugin calls `force_encoding('UTF-8')` on the body
  and on every decoded query key and value.
- **SketchUp splits faces instead of bending them.** Moving only some of a face's vertices
  rarely produces a non-planar face: SketchUp adds an edge and keeps both halves planar. The
  useful signal is an unexpected face/edge count increase, which is why `with_edit` aborts
  on it.
- **Moving part of a face can tilt it without splitting it.** A rectangle whose corners on
  one side move stays planar and unsplit, just no longer vertical. `move_plane` and
  `remap_planes` check for this explicitly before opening an operation.
- **A rolled-back operation still fires the model observer.** `start_operation` +
  `abort_operation` triggers `onTransactionCommit`, so a `dry_run` or a `screenshot` looked
  like a change to `changes_since`. Both suppress the counter while running an operation
  they roll back themselves.

## Design notes

- **`changes_since` tokens** are `"<session_id>:<counter>"`. The counter resets on every
  plugin load, so a bare number from before a reload could collide with an unrelated
  post-reload value. A token from a different session is always reported as changed.
- **Snapping.** Tools that add geometry next to existing geometry snap each new point onto
  an existing vertex within ~3.5 mm; otherwise duplicate edges appear.
- **`cut_opening` frames** are a single U-shaped profile extruded through the wall depth,
  not three boxes. Touching boxes leave internal faces and the group never reads as a solid.
- **`weld_vertices`** only welds within one entities collection; vertices in different
  groups are separate points. `cross_group: true` snaps them onto each other instead,
  closing the gap without merging them.
- **Group lookup.** `find_group` (view tools) searches top-level groups; `resolve_group`
  (analysis and editing tools) searches at any depth and records the group's world
  transform, which `world_transform` returns for the rest of that request. Use it instead
  of `grp.transformation`, which is only relative to the parent group.
- **Request reading** has one 2-second deadline for the whole request, so a client that
  stalls part-way can hold up SketchUp for at most that long (it used to be indefinitely).
- **Dropped connections** are logged with the reason (timeout, empty headers, bad request
  line) so a "server disconnected without a response" report leaves a trail.

## Calling the plugin by hand

The plugin refuses requests that don't look like they come from the Python server (see
Security in the README). To call it directly, send the unit header and no `Origin`
header. In PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/model/info -Headers @{ 'X-SketchUp-MCP-Unit' = 'm' }
```

or with curl:

```bash
curl -H "X-SketchUp-MCP-Unit: m" http://127.0.0.1:8080/model/info
```

## Testing

There is no automated test suite. Each tool was verified by hand in SketchUp Make 2017 on
Windows, against a copy of a real survey model:

- each tool called once from Claude, the result checked visually in SketchUp, and one
  Ctrl+Z confirmed to revert it;
- edits checked with a move followed by the reverse move, confirming the model returned to
  its baseline (face/edge counts, bounds, normals);
- `fill_opening` followed by `cut_opening` on an existing door nested two groups deep
  reproduced the original geometry and frame exactly;
- the guards (stranded vertices in `remap_planes`, partial face moves, double cuts)
  confirmed to refuse before changing anything.

Work on a copy of a model, never the original, and use `save_copy` before a batch of edits.
