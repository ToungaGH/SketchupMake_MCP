#!/usr/bin/env python3
"""
SketchUp MCP Server v2.0
Bridges any MCP client (Claude Desktop, Cursor, etc.) to a running SketchUp
instance via the HTTP server embedded in the SketchUp Ruby plugin.
"""

import asyncio
import json
import sys
import logging
from typing import Any
from pathlib import Path

import httpx
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp import types

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

import os
SKETCHUP_HOST = os.environ.get("SKETCHUP_MCP_HOST", "http://127.0.0.1:8080")

# Unit for every length the tools take and return. Sent to the plugin on each
# request, so this is the only place it needs to be set.
UNIT_NAMES = {"m": "metres", "cm": "centimetres", "mm": "millimetres", "inch": "inches"}
UNIT = os.environ.get("SKETCHUP_MCP_UNIT", "m").strip().lower()
if UNIT not in UNIT_NAMES:
    raise SystemExit(
        f"SKETCHUP_MCP_UNIT={UNIT!r} is not supported; use one of: {', '.join(UNIT_NAMES)}"
    )
UNIT_NAME = UNIT_NAMES[UNIT]
HTTP_TIMEOUT = 130.0  # slightly above the 120s Ruby-side timeout

logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
log = logging.getLogger("sketchup-mcp")

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

async def _request(method: str, path: str, body: dict | None = None,
                   params: dict | None = None, timeout: float | None = None) -> dict:
    """Send a request to the SketchUp Ruby server."""
    async with httpx.AsyncClient(timeout=timeout or HTTP_TIMEOUT) as client:
        try:
            headers = {"X-SketchUp-MCP-Unit": UNIT}
            if method == "GET":
                r = await client.get(f"{SKETCHUP_HOST}{path}", params=params or {},
                                     headers=headers)
            else:
                r = await client.post(
                    f"{SKETCHUP_HOST}{path}",
                    json=body or {},
                    headers={**headers, "Content-Type": "application/json"},
                )
            r.raise_for_status()
            # An older plugin ignores the unit header and works in metres.
            if UNIT != "m" and r.headers.get("X-SketchUp-MCP-Unit") != UNIT:
                raise RuntimeError(
                    f"The SketchUp plugin does not support SKETCHUP_MCP_UNIT={UNIT}. "
                    "Copy the current sketchup_mcp_server.rb into SketchUp's Plugins folder "
                    "and restart SketchUp."
                )
            data = r.json()
            if isinstance(data, dict) and "error" in data:
                raise RuntimeError(f"SketchUp error: {data['error']}")
            return data
        except httpx.ConnectError:
            raise RuntimeError(
                "Cannot connect to SketchUp. Make sure SketchUp is running "
                "and the MCP plugin is loaded (Plugins → MCP Server → Start Server)."
            )
        except httpx.TimeoutException:
            raise RuntimeError(
                f"Request to SketchUp timed out after {timeout or HTTP_TIMEOUT}s. "
                "The operation may be too complex or SketchUp may be frozen."
            )
        except httpx.HTTPStatusError as e:
            raise RuntimeError(
                f"SketchUp returned {e.response.status_code}: {e.response.text}"
            )
        except ValueError as e:
            raise RuntimeError(f"Invalid JSON from SketchUp: {e}")


async def su_get(path: str, params: dict | None = None, timeout: float | None = None) -> dict:
    return await _request("GET", path, params=params, timeout=timeout)


async def su_post(path: str, body: dict | None = None, timeout: float | None = None) -> dict:
    return await _request("POST", path, body=body, timeout=timeout)


def ok(data: Any) -> list[types.TextContent]:
    return [types.TextContent(type="text", text=json.dumps(data, indent=2))]


def err(message: str) -> list[types.TextContent]:
    return [types.TextContent(type="text", text=f"Error: {message}")]


def image_ok(data: dict) -> list[types.ImageContent | types.TextContent]:
    """screenshot returns {image_base64, format, ...metadata} as JSON;
    unpack it into an MCP image content block plus a text block with the rest."""
    content: list[types.ImageContent | types.TextContent] = [
        types.ImageContent(type="image", data=data["image_base64"], mimeType="image/png")
    ]
    meta = {k: v for k, v in data.items() if k != "image_base64"}
    if meta:
        content.append(types.TextContent(type="text", text=json.dumps(meta, indent=2)))
    return content


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------

app = Server("sketchup-mcp")
RESOURCES_DIR = Path(__file__).parent.parent.parent / "resources"

# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

@app.list_resources()
async def list_resources() -> list[types.Resource]:
    resources = []
    resource_files = {
        "construction://roof-trusses": ("Roof Truss Design Guide", "roof_trusses.md",
            "Comprehensive guide for roof truss design including types, dimensions, and code requirements"),
        "construction://framing": ("Framing Standards", "framing_standards.md",
            "Standard framing practices for walls, floors, headers, and openings"),
        "construction://stairs": ("Stair Design Standards", "stairs.md",
            "Building code requirements, design formulas, stair types, and calculation methods"),
    }
    for uri, (name, filename, desc) in resource_files.items():
        filepath = RESOURCES_DIR / filename
        if filepath.exists():
            resources.append(types.Resource(
                uri=uri, name=name, mimeType="text/markdown", description=desc
            ))
    return resources


@app.read_resource()
async def read_resource(uri: str) -> str:
    file_map = {
        "construction://roof-trusses": "roof_trusses.md",
        "construction://framing": "framing_standards.md",
        "construction://stairs": "stairs.md",
    }
    filename = file_map.get(uri)
    if not filename:
        raise ValueError(f"Unknown resource: {uri}")
    filepath = RESOURCES_DIR / filename
    if not filepath.exists():
        raise FileNotFoundError(f"Resource file not found: {filepath}")
    return filepath.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------

TOOL_DEFS: list[types.Tool] = [
    # ── Query ──────────────────────────────────────────────────────────────
    types.Tool(
        name="get_model_info",
        description=(
            "Get general information about the currently open SketchUp model: "
            "name, file path, unit system, entity/layer/material counts."
        ),
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
    types.Tool(
        name="list_layers",
        description="List all layers (tags) in the SketchUp model with their visibility.",
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
    types.Tool(
        name="list_materials",
        description="List all materials in the SketchUp model with their colors and textures.",
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
    types.Tool(
        name="list_entities",
        description=(
            "List entities (faces, edges, groups, component instances) in the model "
            "or inside a named group."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group_name": {
                    "type": "string",
                    "description": "If provided, list entities inside this group. "
                                   "Otherwise lists top-level model entities.",
                }
            },
            "required": [],
        },
    ),
    types.Tool(
        name="list_components",
        description="List all component definitions in the SketchUp model.",
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),

    # ── Selection & view ───────────────────────────────────────────────────
    types.Tool(
        name="get_selection",
        description=(
            "Get the current SketchUp selection: for each entity, its type, id, persistent_id, "
            "tag (layer), and world-space bounds; faces also get their normal and a point on "
            "their plane. Coordinates are in metres, in world coordinates (the active group/"
            "component's transform is applied)."
        ),
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
    types.Tool(
        name="select",
        description=(
            "Replace the SketchUp selection with the given entities, so the user can see what "
            "the assistant means before something changes. Identify entities by 'ids' "
            "(persistent_id values, stable across sessions — NOT the 'id'/entityID field, which "
            "changes every session) or by 'group_names'. Selection is limited to the currently "
            "active editing context (top level, or whatever group/component the user has open "
            "for edit): a target nested elsewhere is replaced by its top-level container within "
            "that context, and the reply's 'notes' explain the substitution."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "ids": {
                    "type": "array", "items": {"type": "integer"},
                    "description": "persistent_id values (from get_selection or list_entities)",
                },
                "group_names": {"type": "array", "items": {"type": "string"}},
            },
            "required": [],
        },
    ),
    types.Tool(
        name="zoom_to",
        description=(
            "Zoom/frame the SketchUp camera to fit the given entities (by 'ids' = persistent_id "
            "values, or 'group_names'). Does not modify the model."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "ids": {"type": "array", "items": {"type": "integer"}},
                "group_names": {"type": "array", "items": {"type": "string"}},
            },
            "required": [],
        },
    ),
    types.Tool(
        name="screenshot",
        description=(
            "Capture the SketchUp viewport as a PNG image. All temporary state changes made to "
            "take the shot (camera, hidden tags/entities, section plane, guide visibility) are "
            "rolled back afterwards, and the model's modified flag is left as it was found — "
            "this never creates an undo step."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "view": {
                    "description": (
                        "'current' (default, leaves the camera untouched), one of "
                        "'iso'/'top'/'front'/'back'/'left'/'right' (set to orthographic), or "
                        "{'eye': [x,y,z], 'target': [x,y,z]} in metres for a custom shot."
                    )
                },
                "width":  {"type": "integer", "description": "Image width in pixels (default 1280, capped at 1920)"},
                "height": {"type": "integer", "description": "Image height in pixels (default: derived from the viewport's aspect ratio)"},
                "hide_tags": {
                    "type": "array", "items": {"type": "string"},
                    "description": "Tag (layer) names to hide just for this shot",
                },
                "isolate": {
                    "type": "array", "items": {"type": "string"},
                    "description": "Only show these top-level group names; hide everything else at the top level",
                },
                "zoom_to": {
                    "type": "array", "items": {"type": "string"},
                    "description": "Top-level group names to zoom/frame before capturing",
                },
                "section": {
                    "type": "object",
                    "properties": {"z": {"type": "number", "description": "Cut height in metres"}},
                    "description": (
                        "Horizontal cut plane: hides everything above this Z, e.g. for a floor "
                        "plan seen from above (use with view:'top')."
                    ),
                },
                "hide_guides": {
                    "type": "boolean",
                    "description": "Hide construction lines/points before capturing (default true)",
                },
            },
            "required": [],
        },
    ),

    # ── Understanding ──────────────────────────────────────────────────────
    types.Tool(
        name="list_wall_planes",
        description=(
            "List vertical (wall-like) faces in a group, grouped by their plane coordinate "
            "along an axis (faces within 1.5mm of each other are clustered into one plane; "
            "each member's exact coordinate is still reported). Only faces aligned to the X or "
            "Y axis are considered (not diagonal walls). Replaces manually scripting this."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string", "description": "Group name to scan (required)"},
                "axis": {"type": "string", "enum": ["x", "y"], "description": "Restrict to planes constant on this axis; omit for both"},
                "min_height": {"type": "number", "description": "Skip faces shorter (in Z) than this, in metres — filters out sills/lintels (default 1 m)"},
                "recursive": {"type": "boolean", "description": "Also scan nested groups/components inside 'group' (default false)"},
            },
            "required": ["group"],
        },
    ),
    types.Tool(
        name="measure",
        description=(
            "Measure distances. Three modes (provide exactly one): "
            "(1) point_a + point_b: straight-line distance. "
            "(2) face_id_a + face_id_b (persistent_id values): perpendicular distance from "
            "face B's centroid to face A's plane, plus centroid-to-centroid distance. "
            "(3) axis + at (+ optional group): a probe line along 'axis' at the given fixed "
            "coordinates on the other two axes. Returns every face the line crosses, in order "
            "(coordinate, containing group, normal_sign, material), plus the gaps between "
            "consecutive crossings — which are room widths and wall thicknesses directly. "
            "With 'group', groups nested inside it are scanned too, and each crossing names "
            "the innermost group it belongs to, which may be one of those nested groups."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "point_a": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                "point_b": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                "face_id_a": {"type": "integer", "description": "persistent_id of the reference face"},
                "face_id_b": {"type": "integer", "description": "persistent_id of the other face"},
                "axis": {"type": "string", "enum": ["x", "y", "z"], "description": "Probe direction"},
                "at": {
                    "type": "object",
                    "description": "Fixed coordinates (metres) on the two axes other than 'axis', e.g. {\"y\": Y, \"z\": Z} for axis:\"x\"",
                    "properties": {"x": {"type": "number"}, "y": {"type": "number"}, "z": {"type": "number"}},
                },
                "group": {"type": "string", "description": "Probe mode only: restrict the scan to this group (recursively); omit to scan the whole model"},
            },
            "required": [],
        },
    ),
    types.Tool(
        name="audit_geometry",
        description=(
            "Check a group (or every top-level group, if 'group' is omitted) for geometry "
            "problems: stray edges (0 faces), open edges (1 face), non-manifold edges (>2 "
            "faces), duplicate edges (same endpoints, separate edge entities — the cause of "
            "'deleting a line deletes the wall'), near-coincident vertex pairs (<2mm, different "
            "vertex objects), tiny faces (<0.005 m², reported with the nested group they live in, "
            "counted per group in tiny_faces_by_group; faces inside closed solids such as "
            "frame end faces are skipped and only counted), non-planar faces, and mergeable "
            "coplanar seams (same material/orientation). Always recurses into nested groups. Each issue "
            "category is capped at 50 example items plus a total count. Without 'group', only the "
            "counts per group are returned (pass details:true for the example items too, which "
            "can be very long); audit one group to see where its issues are. Duplicate edges and near-coincident vertices carry a "
            "cross_group flag (the two sit in different groups: inherent and harmless) with "
            "separate counts."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string", "description": "Group name to audit; omit to audit every top-level group"},
                "details": {"type": "boolean", "description": "Whole-model audit only: include example items, not just counts (default false)"},
            },
            "required": [],
        },
    ),
    types.Tool(
        name="changes_since",
        description=(
            "Check whether the model has changed since a previous look. Pass the 'token' string "
            "you got back last time; omit it on the first call. Returns the current token, the "
            "model's modified flag, and whether it changed since the given token. The counter is "
            "scoped per file path, bumped by a model observer on every commit/undo/redo — "
            "read-only, does not itself count as a change. The token embeds a per-plugin-load "
            "session id, so a token from before SketchUp (or the plugin) restarted is always "
            "treated as changed rather than risking a false 'unchanged' against a fresh session."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "token": {"type": "string", "description": "The token string from a previous changes_since call"},
            },
            "required": [],
        },
    ),

    # ── Editing ────────────────────────────────────────────────────────────
    types.Tool(
        name="move_plane",
        description=(
            "Move every vertex lying on one axis-aligned plane of a group, by (to - from). "
            "This is the wall-move / room-resize operation. Takes exactly one undo step, aborts "
            "without changing anything if any face would end up non-planar, deletes edges the "
            "move stranded, and reports before/after counts (faces, edges, open edges, "
            "near-coincident vertices) so the result can be checked with audit_geometry. "
            "Refuses a move that would shift only some of a face's corners lying on that plane "
            "— which tilts the face without splitting it or making it non-planar — or that "
            "would change a face from vertical/horizontal. Reaches into nested groups inside "
            "the target group. Refuses by default if the vertices would span more than one "
            "collection — name them in 'include' or drop them with 'exclude'. "
            "Use dry_run:true to see what would change without changing it."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string", "description": "Group to edit"},
                "axis": {"type": "string", "enum": ["x", "y", "z"], "description": "Which plane orientation to move"},
                "from": {"type": "number", "description": "Current plane coordinate, in metres"},
                "to": {"type": "number", "description": "Target plane coordinate, in metres"},
                "x_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                            "description": "Only move vertices whose X is within [min, max]"},
                "y_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                            "description": "Only move vertices whose Y is within [min, max]"},
                "z_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                            "description": "Only move vertices whose Z is within [min, max]"},
                "tolerance": {"type": "number", "description": "How close a vertex must be to 'from' to count as on the plane (default 1.5 mm)"},
                "dry_run": {"type": "boolean", "description": "Report what would change, change nothing (default false)"},
                "allow_splits": {"type": "boolean", "description": "Permit the edit even if it splits faces. Off by default: a split means only part of a face moved and the geometry got folded."},
                "allow_distortion": {"type": "boolean", "description": "Permit the edit even if it tilts a face (only some of its on-plane corners move) or changes a face from vertical/horizontal. Off by default."},
                "include": {"type": "array", "items": {"type": "string"}, "description": "Only move vertices in these collections (a group name, or a full path like 'Basement/Garden door - frame'). Also how you acknowledge a deliberate move spanning more than one collection."},
                "exclude": {"type": "array", "items": {"type": "string"}, "description": "Skip vertices in these collections, e.g. a door frame that happens to sit in the wall plane."},
            },
            "required": ["group", "axis", "from", "to"],
        },
    ),
    types.Tool(
        name="remap_planes",
        description=(
            "Move several parallel planes of a group at once, in a single undo step. "
            "Aborts without changing anything if any vertex lies strictly between the mapped "
            "planes without a rule covering it — that vertex would stay put while its "
            "neighbours move, which is the silent-distortion failure mode. Use 'shift_beyond' "
            "to carry everything past a coordinate along by a fixed delta. Same post-check, "
            "tilt guard, collection guard and change report as move_plane. Reaches into nested "
            "groups inside the target group."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string"},
                "axis": {"type": "string", "enum": ["x", "y", "z"]},
                "map": {
                    "type": "array",
                    "description": "Plane moves, e.g. [{\"from\":11.6,\"to\":11.7},{\"from\":13.971,\"to\":14.0}]",
                    "items": {
                        "type": "object",
                        "properties": {"from": {"type": "number"}, "to": {"type": "number"}},
                        "required": ["from", "to"],
                    },
                    "minItems": 1,
                },
                "shift_beyond": {
                    "type": "object",
                    "description": "Shift every vertex beyond 'from' by 'delta' (metres)",
                    "properties": {"from": {"type": "number"}, "delta": {"type": "number"}},
                },
                "tolerance": {"type": "number", "description": "Plane match tolerance in metres (default 1.5 mm)"},
                "dry_run": {"type": "boolean"},
                "allow_splits": {"type": "boolean", "description": "Permit the edit even if it splits faces (off by default)."},
                "allow_distortion": {"type": "boolean", "description": "Permit the edit even if it tilts a face or changes its vertical/horizontal orientation (off by default)."},
                "include": {"type": "array", "items": {"type": "string"}, "description": "Only move vertices in these collections (a group name, or a full path like 'Basement/Garden door - frame'). Also how you acknowledge a deliberate move spanning more than one collection."},
                "exclude": {"type": "array", "items": {"type": "string"}, "description": "Skip vertices in these collections, e.g. a door frame that happens to sit in the wall plane."},
            },
            "required": ["group", "axis", "map"],
        },
    ),

    types.Tool(
        name="cut_opening",
        description=(
            "Cut a rectangular opening (door/window) through a wall: holes in both wall faces, "
            "plus the side and head reveal faces, each oriented to point into the opening. "
            "The host group is found at any nesting depth and its composed world transform is "
            "used, so a wall nested inside another group works. from_floor:true means the "
            "opening starts at the wall's bottom: the bottom face is split and the middle "
            "removed, and no sill face is made. Refuses if an opening already exists there, so "
            "it cannot double-cut. New points snap onto existing vertices within ~3.5mm. "
            "Self-checks with classify_point (open at the centre of both faces, still covered "
            "just outside each edge and above the head) and reports the result. One undo step. "
            "Optionally builds the frame as a single U-shaped prism in one go."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string", "description": "Wall group name, at any nesting depth"},
                "axis": {"type": "string", "enum": ["x", "y"], "description": "Which axis the wall faces are constant on"},
                "wall_faces": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                               "description": "The two wall face coordinates, [outer, inner], in metres"},
                "x_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                            "description": "Opening extent along X (use when axis is 'y')"},
                "y_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                            "description": "Opening extent along Y (use when axis is 'x')"},
                "z_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                            "description": "Opening extent in Z, in metres"},
                "from_floor": {"type": "boolean", "description": "Opening starts at the wall bottom: split the bottom face, no sill"},
                "frame": {
                    "type": "object",
                    "description": "Optionally build a frame group around the opening",
                    "properties": {
                        "name": {"type": "string"},
                        "parent": {"type": "string", "description": "Group to build the frame in (default: the wall's own container)"},
                        "tag": {"type": "string"},
                        "depth_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                                        "description": "Frame extent along the wall axis, in metres"},
                        "side_low": {"type": "number", "description": "Thickness of the low-side member"},
                        "side_high": {"type": "number", "description": "Thickness of the high-side member"},
                        "head": {"type": "number", "description": "Thickness of the head member (no bottom member is made)"},
                    },
                    "required": ["depth_range", "side_low", "side_high", "head"],
                },
                "dry_run": {"type": "boolean"},
            },
            "required": ["group", "axis", "wall_faces", "z_range"],
        },
    ),
    types.Tool(
        name="fill_opening",
        description=(
            "Fill a rectangular opening back in: removes the reveal faces, refills both wall "
            "faces copying material and orientation from the coplanar neighbour, closes the "
            "bottom again for a from_floor opening, and erases the seams so each wall side is "
            "a single face. Takes the same rectangle arguments as cut_opening. Refuses if both "
            "wall faces are already solid there. One undo step."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string"},
                "axis": {"type": "string", "enum": ["x", "y"]},
                "wall_faces": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
                "x_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
                "y_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
                "z_range": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
                "from_floor": {"type": "boolean"},
                "dry_run": {"type": "boolean"},
            },
            "required": ["group", "axis", "wall_faces", "z_range"],
        },
    ),
    types.Tool(
        name="merge_coplanar",
        description=(
            "Erase the seam edges between coplanar faces in a group that share the same "
            "orientation and the same front/back materials, merging them back into single "
            "faces. One undo step, same post-check and change report as move_plane. "
            "Use audit_geometry's mergeable_coplanar_seams to see what it would touch, or "
            "dry_run:true here."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string"},
                "dry_run": {"type": "boolean"},
                "ignore_back_material": {"type": "boolean", "description": "Merge even when the two faces carry different back materials (one is discarded). Off by default."},
            },
            "required": ["group"],
        },
    ),
    types.Tool(
        name="weld_vertices",
        description=(
            "Merge near-coincident vertex pairs in a group by moving one onto the other, "
            "which is what fixes the 'deleting a line deletes the wall' problem. Only welds "
            "vertices within the same entities collection — two vertices in different groups "
            "are genuinely separate points. With cross_group:true it instead snaps near-"
            "coincident vertices that sit in different groups/components (e.g. a wall group "
            "and its parent) exactly onto each other, moving the one in the nested group "
            "(keep:'outer', default) or the outer one (keep:'inner'); the vertices stay "
            "separate points, but the sub-millimetre gap disappears. One undo step; aborts if "
            "the weld would split or fold a face. Check the near_coincident_vertices delta in "
            "the report."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "group": {"type": "string"},
                "tolerance": {"type": "number", "description": "Maximum gap to weld, in metres (default 2 mm)"},
                "dry_run": {"type": "boolean"},
                "allow_splits": {"type": "boolean"},
                "cross_group": {"type": "boolean", "description": "Snap near-coincident vertices across different groups/components instead of welding within one collection (default false)"},
                "keep": {"type": "string", "enum": ["outer", "inner"], "description": "With cross_group: which vertex stays put. 'outer' (default) keeps the one in the shallower group and moves the nested one."},
            },
            "required": ["group"],
        },
    ),
    types.Tool(
        name="add_dimension",
        description=(
            "Add a real linear dimension entity between two points (not a text label). "
            "Placed on the given tag, default 'Dimensions'. One undo step."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "point_a": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                "point_b": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                "offset": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3,
                           "description": "Vector offsetting the dimension line from the measured points"},
                "tag": {"type": "string", "description": "Tag/layer for the dimension (default 'Dimensions')"},
            },
            "required": ["point_a", "point_b"],
        },
    ),
    types.Tool(
        name="save",
        description="Save the current SketchUp model in place. Fails if the model has never been saved.",
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
    types.Tool(
        name="save_copy",
        description=(
            "Save a copy of the model alongside the original as '<name>_<suffix>.skp', leaving "
            "the open file untouched. Defaults the suffix to a timestamp. Use this to take a "
            "backup before a risky batch of edits."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "suffix": {"type": "string", "description": "Filename suffix (default: current timestamp)"},
            },
            "required": [],
        },
    ),

    # ── Create geometry ────────────────────────────────────────────────────
    types.Tool(
        name="create_face",
        description=(
            "Create a flat face (polygon) in SketchUp from an ordered list of 3D points. "
            "All coordinates are in METRES (the plugin converts to SketchUp's internal inches)."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "points": {
                    "type": "array",
                    "description": "Ordered list of [x, y, z] vertices. Minimum 3.",
                    "items": {
                        "type": "array",
                        "items": {"type": "number"},
                        "minItems": 3, "maxItems": 3,
                    },
                    "minItems": 3,
                },
                "layer": {"type": "string", "description": "Layer name to assign (created if missing)."},
                "material": {"type": "string", "description": "Material name to assign (created if missing)."},
            },
            "required": ["points"],
        },
    ),
    types.Tool(
        name="create_edge",
        description="Create a line segment (edge) between two 3D points.",
        inputSchema={
            "type": "object",
            "properties": {
                "start": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] start point",
                },
                "end": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] end point",
                },
                "layer": {"type": "string"},
            },
            "required": ["start", "end"],
        },
    ),
    types.Tool(
        name="create_group",
        description="Create an empty named group in SketchUp, optionally on a layer.",
        inputSchema={
            "type": "object",
            "properties": {
                "name":  {"type": "string", "description": "Name for the new group"},
                "layer": {"type": "string", "description": "Layer to place the group on"},
            },
            "required": [],
        },
    ),
    types.Tool(
        name="create_box",
        description=(
            "Create a 3-D box (rectangular prism) as a named group, by specifying width, depth, height in metres. "
            "Optionally provide an origin [x, y, z] for the base corner."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "width":  {"type": "number", "description": "Size along X axis, in metres"},
                "depth":  {"type": "number", "description": "Size along Y axis, in metres"},
                "height": {"type": "number", "description": "Size along Z axis, in metres"},
                "origin": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] base corner in metres (default [0,0,0])",
                },
                "layer":    {"type": "string"},
                "material": {"type": "string"},
            },
            "required": ["width", "depth", "height"],
        },
    ),

    # ── Advanced geometry ──────────────────────────────────────────────────
    types.Tool(
        name="create_circle",
        description=(
            "Create a circle in SketchUp from a center point, normal vector, and radius. "
            "Returns edges forming the circle."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "center": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] center point (default [0,0,0])",
                },
                "normal": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] normal vector (default [0,0,1] for Z-axis)",
                },
                "radius":   {"type": "number", "description": "Circle radius in metres (must be positive)"},
                "segments": {"type": "integer", "description": "Number of segments (default 24, min 3)"},
                "layer":    {"type": "string"},
                "material": {"type": "string"},
            },
            "required": ["radius"],
        },
    ),
    types.Tool(
        name="create_arc",
        description="Create an arc in SketchUp. Specify center, radius, start/end angles in degrees.",
        inputSchema={
            "type": "object",
            "properties": {
                "center": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] center point",
                },
                "xaxis": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] X-axis vector (default [1,0,0])",
                },
                "normal": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] normal vector",
                },
                "radius":      {"type": "number", "description": "Arc radius in metres"},
                "start_angle": {"type": "number", "description": "Start angle in degrees (default 0)"},
                "end_angle":   {"type": "number", "description": "End angle in degrees (default 180)"},
                "segments":    {"type": "integer", "description": "Number of segments (default 12)"},
                "layer":       {"type": "string"},
                "material":    {"type": "string"},
            },
            "required": ["radius"],
        },
    ),
    types.Tool(
        name="create_polygon",
        description="Create a regular polygon (triangle, pentagon, hexagon, etc.) with n sides.",
        inputSchema={
            "type": "object",
            "properties": {
                "center": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] center point",
                },
                "normal": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] normal vector",
                },
                "radius":    {"type": "number", "description": "Radius from center to vertices, in metres"},
                "num_sides": {"type": "integer", "description": "Number of sides (min 3)"},
                "inscribed": {"type": "boolean", "description": "True if inscribed (default), false if circumscribed"},
                "layer":     {"type": "string"},
                "material":  {"type": "string"},
            },
            "required": ["radius", "num_sides"],
        },
    ),
    types.Tool(
        name="push_pull",
        description=(
            "Push/pull a face by a specified distance. Positive distance extrudes outward, "
            "negative pulls inward."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "entity_id": {"type": "integer", "description": "ID of the face to push/pull"},
                "distance":  {"type": "number", "description": "Distance in metres to push (positive) or pull (negative)"},
            },
            "required": ["entity_id", "distance"],
        },
    ),
    types.Tool(
        name="follow_me",
        description="Extrude a face along a path (array of edge IDs). This is SketchUp's Follow Me tool.",
        inputSchema={
            "type": "object",
            "properties": {
                "face_id":  {"type": "integer", "description": "ID of the face to extrude"},
                "path_ids": {
                    "type": "array", "items": {"type": "integer"},
                    "description": "Array of edge IDs forming the path",
                },
            },
            "required": ["face_id", "path_ids"],
        },
    ),

    # ── Transformations ────────────────────────────────────────────────────
    types.Tool(
        name="move_entity",
        description="Move (translate) an entity by a vector [x, y, z].",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_id": {"type": "integer", "description": "ID of the entity to move"},
                "vector": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] translation vector in metres",
                },
            },
            "required": ["entity_id", "vector"],
        },
    ),
    types.Tool(
        name="rotate_entity",
        description="Rotate an entity around an axis by a given angle in degrees.",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_id": {"type": "integer", "description": "ID of the entity to rotate"},
                "axis_point": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] point on the rotation axis",
                },
                "axis_vector": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] direction vector of rotation axis",
                },
                "angle": {"type": "number", "description": "Rotation angle in degrees"},
            },
            "required": ["entity_id", "axis_point", "axis_vector", "angle"],
        },
    ),
    types.Tool(
        name="scale_entity",
        description=(
            "Scale an entity. Provide a single number for uniform scaling, "
            "or [x, y, z] array for non-uniform scaling."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "entity_id": {"type": "integer", "description": "ID of the entity to scale"},
                "scale": {"description": "Scale factor (number) or [x, y, z] scale factors (array)"},
                "origin": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "[x, y, z] origin point for scaling (default [0,0,0])",
                },
            },
            "required": ["entity_id", "scale"],
        },
    ),

    # ── Components ─────────────────────────────────────────────────────────
    types.Tool(
        name="create_component",
        description=(
            "Create a new (empty) component definition and place one instance in the model. "
            "Returns the definition name and instance ID."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "name":        {"type": "string", "description": "Component definition name"},
                "description": {"type": "string"},
                "origin": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                    "description": "Where to place the instance",
                },
            },
            "required": ["name"],
        },
    ),
    types.Tool(
        name="place_component",
        description="Place an instance of an existing component definition into the model at a given origin.",
        inputSchema={
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Exact name of the component definition"},
                "origin": {
                    "type": "array", "items": {"type": "number"},
                    "minItems": 3, "maxItems": 3,
                },
            },
            "required": ["name"],
        },
    ),

    # ── Construction ───────────────────────────────────────────────────────
    types.Tool(
        name="create_roof_truss",
        description=(
            "Create engineered roof trusses with accurate geometry based on professional truss analysis. "
            "Supports king post (simple, up to 26') and fink/W-truss (most common, 20-60'). "
            "NOTE: unlike every other tool, this one uses US units (span in feet, other lengths in inches). "
            "Trusses include proper web patterns, angled members, and realistic connections. "
            "Use construction://roof-trusses resource for detailed guidance."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "span":     {"type": "number", "description": "Clear span in feet (wall-to-wall distance, excluding overhang)"},
                "pitch":    {"type": "string", "description": "Roof pitch as 'rise:run' (e.g., '6:12', '8:12'). Common: 6:12", "default": "6:12"},
                "type":     {"type": "string", "enum": ["king", "fink"], "description": "Truss type: king (simple with center post) or fink (W-pattern, most common)", "default": "fink"},
                "count":    {"type": "integer", "description": "Number of trusses to create", "default": 1},
                "spacing":  {"type": "number", "description": "Spacing between trusses in inches (typically 24 OC)", "default": 24},
                "overhang": {"type": "number", "description": "Overhang beyond walls in inches (each side). Standard: 12-24 inches", "default": 12},
                "lumber_size": {"type": "string", "enum": ["2x4", "2x6", "2x8"], "description": "Lumber size for members (actual dimensions: 2x4=1.5×3.5, 2x6=1.5×5.5)", "default": "2x4"},
                "origin":   {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "Left wall bottom position [x, y, z] in inches"},
                "layer":    {"type": "string", "description": "Layer name for trusses"},
            },
            "required": ["span"],
        },
    ),

    # ── Execute Ruby ───────────────────────────────────────────────────────
    types.Tool(
        name="execute_ruby",
        description=(
            "Execute arbitrary Ruby code inside SketchUp. "
            "The code runs at the top level (not inside the plugin's SU_MCP module; call its "
            "helpers as SU_MCP.name) and has full access to the SketchUp Ruby API "
            "(Sketchup, Geom, UI, etc.). "
            "Returns the result of the last expression and any puts/print output. "
            "SketchUp Make 2017 (Ruby 2.2): do NOT use Ruby 2.3+ syntax such as `&.` or `<<~`. "
            "The raw API works in inches: write lengths with SketchUp's unit helpers, e.g. 3.5.m or 20.cm. "
            "Solid-tool methods (union, subtract, intersect, trim, split, outer_shell) are SketchUp Pro only and fail in Make. "
            "Wrap edits in model.start_operation('Name', true) / model.commit_operation for a single undo step. "
            "Use with care — this can modify or delete model data."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "Ruby source code to execute"},
            },
            "required": ["code"],
        },
    ),
]

# Make 2017 patch: state the unit on every geometry/transform tool
_METRIC_TOOLS = {
    "create_face", "create_edge", "create_box", "create_circle", "create_arc",
    "create_polygon", "push_pull", "move_entity", "rotate_entity", "scale_entity",
    "create_component", "place_component", "list_entities", "get_selection", "screenshot",
    "list_wall_planes", "measure", "audit_geometry", "move_plane", "remap_planes",
    "weld_vertices", "add_dimension", "cut_opening", "fill_opening",
}
for _t in TOOL_DEFS:
    if _t.name in _METRIC_TOOLS:
        _t.description = _t.description.rstrip() + " All lengths and coordinates are in metres."

# The analysis and editing tools find their group at any nesting depth.
_DEEP_GROUP_TOOLS = {
    "list_wall_planes", "measure", "audit_geometry", "move_plane", "remap_planes",
    "merge_coplanar", "weld_vertices",
}
_DEEP_GROUP_NOTE = (
    "Found at any nesting depth: a top-level group with this name wins, otherwise the "
    "name must be unique in the model (an ambiguous name is refused, listing the matches)."
)
for _t in TOOL_DEFS:
    if _t.name in _DEEP_GROUP_TOOLS:
        _g = _t.inputSchema["properties"]["group"]
        _desc = _g.get("description", "Group name").rstrip(". ")
        _g["description"] = f"{_desc}. {_DEEP_GROUP_NOTE}"


def _use_unit(node):
    """Rewrite 'metres' in descriptions to the configured unit. Fixed sizes such
    as tolerances are written as real-world sizes ('1.5 mm') and stay as they are."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "description" and isinstance(v, str):
                node[k] = v.replace("metres", UNIT_NAME).replace("METRES", UNIT_NAME.upper())
            else:
                _use_unit(v)
    elif isinstance(node, list):
        for v in node:
            _use_unit(v)


if UNIT != "m":
    for _t in TOOL_DEFS:
        _t.description = _t.description.replace("metres", UNIT_NAME).replace("METRES", UNIT_NAME.upper())
        _use_unit(_t.inputSchema)

# Per-tool HTTP timeout override (seconds), for tools that legitimately take
# longer than the rest. Falls back to HTTP_TIMEOUT when not listed.
TOOL_TIMEOUTS: dict[str, float] = {
    "screenshot": 180.0,  # camera/render/file-IO/base64 round trip on a large model
}

# Route map: tool_name -> (http_method, path)
TOOL_ROUTES: dict[str, tuple[str, str]] = {
    # Query
    "get_model_info":      ("GET",  "/model/info"),
    "list_layers":         ("GET",  "/model/layers"),
    "list_materials":      ("GET",  "/model/materials"),
    "list_entities":       ("GET",  "/model/entities"),
    "list_components":     ("GET",  "/model/components"),
    # Selection & view
    "get_selection":       ("GET",  "/selection"),
    "select":               ("POST", "/selection/select"),
    "zoom_to":              ("POST", "/view/zoom_to"),
    "screenshot":           ("POST", "/view/screenshot"),  # long timeout, image response
    # Understanding
    "list_wall_planes":    ("POST", "/wall_planes"),
    "measure":             ("POST", "/measure"),
    "audit_geometry":      ("GET",  "/audit_geometry"),
    "changes_since":       ("GET",  "/changes_since"),
    # Editing
    "move_plane":          ("POST", "/edit/move_plane"),
    "remap_planes":        ("POST", "/edit/remap_planes"),
    "cut_opening":         ("POST", "/edit/cut_opening"),
    "fill_opening":        ("POST", "/edit/fill_opening"),
    "merge_coplanar":      ("POST", "/edit/merge_coplanar"),
    "weld_vertices":       ("POST", "/edit/weld_vertices"),
    "add_dimension":       ("POST", "/edit/add_dimension"),
    "save":                ("POST", "/edit/save"),
    "save_copy":           ("POST", "/edit/save_copy"),

    # Create geometry
    "create_face":         ("POST", "/geometry/face"),
    "create_edge":         ("POST", "/geometry/edge"),
    "create_group":        ("POST", "/geometry/group"),
    "create_box":          ("POST", "/geometry/box"),
    # Advanced geometry
    "create_circle":       ("POST", "/geometry/circle"),
    "create_arc":          ("POST", "/geometry/arc"),
    "create_polygon":      ("POST", "/geometry/polygon"),
    "push_pull":           ("POST", "/geometry/pushpull"),
    "follow_me":           ("POST", "/geometry/followme"),
    # Transformations
    "move_entity":         ("POST", "/transform/move"),
    "rotate_entity":       ("POST", "/transform/rotate"),
    "scale_entity":        ("POST", "/transform/scale"),
    # Components
    "create_component":    ("POST", "/components/create"),
    "place_component":     ("POST", "/components/place"),
    # Construction
    "create_roof_truss":   ("POST", "/construction/roof_truss"),
    # Ruby
    "execute_ruby":        ("POST", "/ruby/execute"),
}


@app.list_tools()
async def list_tools() -> list[types.Tool]:
    return TOOL_DEFS


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent | types.ImageContent]:
    try:
        route = TOOL_ROUTES.get(name)
        if not route:
            return err(f"Unknown tool: {name}")

        method, path = route
        timeout = TOOL_TIMEOUTS.get(name)

        if method == "GET":
            # For GET, pass arguments as query params
            params = {}
            for k, v in arguments.items():
                params[k] = v
            data = await su_get(path, params if params else None, timeout=timeout)
        else:
            data = await su_post(path, arguments if arguments else None, timeout=timeout)

        # Special error handling for execute_ruby
        if name == "execute_ruby" and isinstance(data, dict) and "error" in data:
            bt = "\n".join(data.get("backtrace", []))
            return err(f"Ruby error: {data['error']}\n{bt}")

        if name == "screenshot":
            if not isinstance(data, dict) or "image_base64" not in data:
                return err("SketchUp did not return image data")
            return image_ok(data)

        return ok(data)

    except RuntimeError as exc:
        return err(str(exc))
    except Exception as exc:
        log.exception("Unexpected error in tool %s", name)
        return err(f"Unexpected error: {exc}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(
            read_stream,
            write_stream,
            app.create_initialization_options(),
        )


if __name__ == "__main__":
    asyncio.run(main())
