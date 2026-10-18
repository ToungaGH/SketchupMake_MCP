# sketchup_mcp_server.rb
# SketchUp MCP Bridge Plugin - v2.0-make2017
#
# Patched for SketchUp Make 2017 (Ruby 2.2) from Tarkiin/sketchup-mcp
# commit a47ca45 (MIT licence). Changes from the original:
#   1. Removed Ruby 2.3+ syntax (safe navigation operator) that stops the
#      file from loading at all on Ruby 2.2.
#   2. Replaced the background-thread TCP server with a UI.start_timer poll
#      on SketchUp's main thread. Ruby threads are starved inside SketchUp
#      when it is idle, which makes the threaded version hang or time out.
#   3. Added units: every length sent to or returned by the tools is in
#      metres by default (SketchUp itself always works in inches internally).
#      The Python server can ask for cm/mm/inch per request.
#      The roof-truss tool keeps its original feet/inches parameters.
#
# Embeds a lightweight TCP/HTTP server inside SketchUp so that
# an external MCP server (Python) can drive SketchUp programmatically.
#
# Installation: Copy ONLY this single file into your SketchUp Plugins directory.
#   Windows: %APPDATA%\SketchUp\SketchUp <version>\SketchUp\Plugins\
#   macOS:   ~/Library/Application Support/SketchUp <version>/SketchUp/Plugins/
#
# After copying, restart SketchUp. The server auto-starts on port 8080.

require 'socket'
require 'json'
require 'sketchup'
require 'uri'
require 'stringio'

module SU_MCP
  PORT = 8080

  # Unit for all lengths passed to / returned from the tools. The Python
  # server sends its unit (SKETCHUP_MCP_UNIT) on every request in the
  # X-SketchUp-MCP-Unit header, which is required (see refuse_reason).
  DEFAULT_UNIT = 'm'
  INCHES_PER = {
    'm'    => 39.37007874015748,
    'cm'   => 0.3937007874015748,
    'mm'   => 0.03937007874015748,
    'inch' => 1.0
  }.freeze
  INCHES_PER_METRE = INCHES_PER['m']
  @unit            = DEFAULT_UNIT
  @inches_per_unit = INCHES_PER[DEFAULT_UNIT]

  # Constants
  ORIGIN = Geom::Point3d.new(0, 0, 0)
  X_AXIS = Geom::Vector3d.new(1, 0, 0)
  Y_AXIS = Geom::Vector3d.new(0, 1, 0)
  Z_AXIS = Geom::Vector3d.new(0, 0, 1)

  @timer_id = nil
  @server = nil
  @running = false

  # changes_since state: per-file-path change counters, bumped by a
  # ModelObserver attached to whichever model is currently active.
  @change_counters = {}
  @model_observer   = nil
  @observed_model   = nil
  @app_observer     = nil
  # Unique per plugin load (real SketchUp restart, or a dev hot-reload via
  # `load`) — folded into every changes_since token so a token saved before
  # a reload can never coincidentally match the counter after one and be
  # misread as "unchanged" against a completely different session's state.
  @session_id = nil
  # World transforms of the groups resolve_group found for the current
  # request (entityID => Transformation); cleared before each request.
  @world_t = {}
  # Set while the plugin runs an operation it will roll back itself (a
  # screenshot's temp state, or a dry_run edit). Without it those
  # start/abort pairs fire the model observer and inflate the change
  # counter, so a tool that changed nothing would still report "changed".
  @suppress_change_count = false

  # Log file in temp directory (cross-platform)
  LOG_DIR = File.join(ENV['TEMP'] || ENV['TMPDIR'] || '/tmp')
  LOG_FILE = File.join(LOG_DIR, 'sketchup_mcp_debug.log')

  def self.log(msg)
    ts = Time.now.strftime("%H:%M:%S.%L")
    line = "[MCP #{ts}] #{msg}"
    puts line
    begin
      File.open(LOG_FILE, 'a') { |f| f.puts(line); f.flush }
    rescue
      # silently ignore log write failures
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def self.model
    Sketchup.active_model
  end

  def self.entities
    model.active_entities
  end

  # Tool units -> SketchUp internal inches
  def self.len(v)
    v.to_f * @inches_per_unit
  end

  # A fixed real-world size in metres -> inches, whatever the tool unit.
  # For internal tolerances and defaults, which must not change size when
  # the caller works in cm or mm.
  def self.metres(v)
    v.to_f * INCHES_PER_METRE
  end

  # SketchUp internal inches -> tool units
  def self.out_len(v)
    (v.to_f / @inches_per_unit).round(4)
  end

  def self.out_area(v)
    (v.to_f / (@inches_per_unit * @inches_per_unit)).round(4)
  end

  def self.out_point(pt)
    [out_len(pt.x), out_len(pt.y), out_len(pt.z)]
  end

  def self.parse_point(arr)
    Geom::Point3d.new(len(arr[0]), len(arr[1]), len(arr[2]))
  end

  # Imperial point (inches), used only by the roof-truss tool
  def self.parse_point_in(arr)
    Geom::Point3d.new(arr[0].to_f, arr[1].to_f, arr[2].to_f)
  end

  def self.parse_points(arr)
    arr.map { |p| parse_point(p) }
  end

  def self.vec3(v)
    [v.x.to_f, v.y.to_f, v.z.to_f]
  end

  # A top-level group by name. The view tools (isolate, zoom_to, selecting by
  # name) work on top-level entities, so they only look there. A name shared
  # by several top-level groups is refused rather than resolved to the first.
  def self.find_group(name)
    found = model.entities.grep(Sketchup::Group).select { |g| g.name == name }
    if found.length > 1
      raise "#{found.length} top-level groups are named '#{name}'; rename them so the one you mean is unique"
    end
    found.first
  end

  # Every group named `name` at any depth (with components: also component
  # instances whose definition has that name), as [entity, world transform,
  # path of names from the top].
  def self.groups_named(name, components = false, ents = nil, t = nil, path = '', out = [])
    ents ||= model.entities
    t ||= Geom::Transformation.new
    ents.each do |e|
      if e.is_a?(Sketchup::Group)
        label = e.name.to_s.empty? ? 'unnamed group' : e.name
        named = e.name == name
        inner = e.entities
      elsif e.is_a?(Sketchup::ComponentInstance)
        label = e.definition.name
        named = components && e.definition.name == name
        inner = e.definition.entities
      else
        next
      end
      ct = t * e.transformation
      full = path.empty? ? label : "#{path}/#{label}"
      out << [e, ct, full] if named
      groups_named(name, components, inner, ct, full, out)
    end
    out
  end

  # A group by name at any depth, for the analysis and editing tools. A
  # top-level group of that name wins, so names that worked before still do;
  # otherwise the name must be unique in the model. Returns
  # [group, world transform, path] and remembers the transform for
  # world_transform, or nil when nothing has that name.
  def self.resolve_group(name, components = false)
    matches = groups_named(name, components)
    return nil if matches.empty?
    top = matches.select { |e, _t, _path| e.parent.is_a?(Sketchup::Model) }
    chosen =
      if top.length == 1
        top.first
      elsif top.empty? && matches.length == 1
        matches.first
      else
        paths = (top.empty? ? matches : top).map { |_e, _t, path| path }
        raise "'#{name}' is ambiguous: #{paths.length} groups have that name " \
              "(#{paths.first(10).join('; ')}). Rename them so the one you mean is unique."
      end
    @world_t[chosen[0].entityID] = chosen[1]
    chosen
  end

  # Where a group found by resolve_group sits in the world. Its own
  # transformation is only relative to its parent, which is the same thing
  # for a top-level group but not for a nested one.
  def self.world_transform(grp)
    @world_t[grp.entityID] || grp.transformation
  end

  def self.find_entity_by_id(id_val)
    id = id_val.to_i
    # Search everywhere: top-level entities, inside groups, inside components
    search_entities(model.entities, id)
  end

  def self.search_entities(ents, id)
    ents.each do |e|
      return e if e.entityID == id
      if e.is_a?(Sketchup::Group)
        found = search_entities(e.entities, id)
        return found if found
      elsif e.is_a?(Sketchup::ComponentInstance)
        found = search_entities(e.definition.entities, id)
        return found if found
      end
    end
    nil
  end

  def self.apply_layer(entity, name)
    return unless name && !name.empty?
    layer = model.layers[name] || model.layers.add(name)
    entity.layer = layer
  end

  def self.apply_material(entity, name)
    return unless name && !name.empty?
    mat = model.materials[name] || model.materials.add(name)
    entity.material = mat if entity.respond_to?(:material=)
  end

  # persistent_id is stable across sessions (entityID is not), so Batch-1
  # tools resolve entities by it. There's no find_entity_by_persistent_id
  # built-in on SU 2017, so walk the tree ourselves.
  def self.find_entity_by_persistent_id(pid_val)
    pid = pid_val.to_i
    search_by_persistent_id(model.entities, pid)
  end

  def self.search_by_persistent_id(ents, pid)
    ents.each do |e|
      return e if e.respond_to?(:persistent_id) && e.persistent_id == pid
      if e.is_a?(Sketchup::Group)
        found = search_by_persistent_id(e.entities, pid)
        return found if found
      elsif e.is_a?(Sketchup::ComponentInstance)
        found = search_by_persistent_id(e.definition.entities, pid)
        return found if found
      end
    end
    nil
  end

  # Resolve a {ids: [persistent_id,...]} or {group_names: [...]} param into entities.
  def self.resolve_entities(p)
    if p['ids'] && !p['ids'].empty?
      p['ids'].map do |pid|
        e = find_entity_by_persistent_id(pid)
        raise "Entity with persistent_id #{pid} not found" unless e
        e
      end
    elsif p['group_names'] && !p['group_names'].empty?
      p['group_names'].map do |name|
        g = find_group(name)
        raise "Group '#{name}' not found" unless g
        g
      end
    else
      raise "Provide 'ids' (persistent_id) or 'group_names'"
    end
  end

  def self.describe_entity(e)
    nm = (e.respond_to?(:name) && e.name && !e.name.empty?) ? " '#{e.name}'" : ''
    "#{e.class.name.split('::').last}##{e.entityID}#{nm}"
  end

  # World-space bounding box of an entity in the currently active editing
  # context. entity.bounds is in that context's own local coordinates, so
  # each corner is run through model.edit_transform to land in world space
  # (and re-min/maxed, since a rotated transform makes the local box's
  # corners no longer axis-aligned).
  def self.world_bounds(entity, edit_t)
    bb = entity.bounds
    corners = (0..7).map { |i| bb.corner(i).transform(edit_t) }
    xs = corners.map(&:x)
    ys = corners.map(&:y)
    zs = corners.map(&:z)
    {
      min: [out_len(xs.min), out_len(ys.min), out_len(zs.min)],
      max: [out_len(xs.max), out_len(ys.max), out_len(zs.max)]
    }
  end

  def self.apply_view(view_param)
    return if view_param.nil? || view_param == 'current'
    v = model.active_view

    if view_param.is_a?(Hash)
      eye    = parse_point(view_param['eye'])
      target = parse_point(view_param['target'])
      direction = target - eye
      direction.normalize!
      # Camera.new raises "Up vector cannot be parallel to view direction"
      # for a straight-down/up shot if up is Z — fall back to Y in that case.
      up = direction.dot(Z_AXIS).abs > 0.999 ? Y_AXIS : Z_AXIS
      cam = Sketchup::Camera.new(eye, target, up)
      cam.perspective = false
      v.camera = cam
      v.zoom_extents
      return
    end

    # Built directly with Sketchup::Camera rather than Sketchup.send_action:
    # send_action simulates a UI menu command, and reliably no-ops when
    # called from this background/timer-driven context instead of a real
    # user gesture — the camera silently stays wherever it was.
    eye_dirs = {
      'top'   => Geom::Vector3d.new(0, 0, 1),
      'front' => Geom::Vector3d.new(0, -1, 0),
      'back'  => Geom::Vector3d.new(0, 1, 0),
      'left'  => Geom::Vector3d.new(-1, 0, 0),
      'right' => Geom::Vector3d.new(1, 0, 0),
      'iso'   => Geom::Vector3d.new(1, -1, 1)
    }
    up_dirs = {
      'top' => Y_AXIS, 'front' => Z_AXIS, 'back' => Z_AXIS,
      'left' => Z_AXIS, 'right' => Z_AXIS, 'iso' => Z_AXIS
    }
    ed = eye_dirs[view_param]
    raise "Unknown view '#{view_param}'" unless ed
    ed = ed.clone
    ed.normalize!
    up = up_dirs[view_param]

    bb = model.bounds
    if bb.diagonal > 0
      center = bb.center
      radius = bb.diagonal
    else
      center = ORIGIN
      radius = metres(10.0)
    end

    eye = center.offset(ed, radius * 2)
    cam = Sketchup::Camera.new(eye, center, up)
    cam.perspective = false
    v.camera = cam
    v.zoom_extents
  end

  # persistent_id search that also returns the accumulated world transform,
  # for tools (measure, audit_geometry) that need to place an arbitrarily
  # nested entity in world space.
  def self.find_with_transform_by_persistent_id(pid_val)
    pid = pid_val.to_i
    search_with_transform_by_persistent_id(model.entities, Geom::Transformation.new, pid)
  end

  def self.search_with_transform_by_persistent_id(ents, t, pid)
    ents.each do |e|
      return [e, t] if e.respond_to?(:persistent_id) && e.persistent_id == pid
      if e.is_a?(Sketchup::Group)
        found = search_with_transform_by_persistent_id(e.entities, t * e.transformation, pid)
        return found if found
      elsif e.is_a?(Sketchup::ComponentInstance)
        found = search_with_transform_by_persistent_id(e.definition.entities, t * e.transformation, pid)
        return found if found
      end
    end
    nil
  end

  # --- changes_since: observer plumbing ---
  #
  # Kept deliberately minimal, and every callback is wrapped so a bug here
  # can never propagate into SketchUp's event dispatch and take the app down.

  class ChangeModelObserver < Sketchup::ModelObserver
    def onTransactionCommit(model)
      SU_MCP.bump_change_counter(model)
    rescue
      nil
    end

    def onTransactionUndo(model)
      SU_MCP.bump_change_counter(model)
    rescue
      nil
    end

    def onTransactionRedo(model)
      SU_MCP.bump_change_counter(model)
    rescue
      nil
    end
  end

  class ChangeAppObserver < Sketchup::AppObserver
    def onNewModel(model)
      SU_MCP.attach_change_observer(model)
    rescue
      nil
    end

    def onOpenModel(model)
      SU_MCP.attach_change_observer(model)
    rescue
      nil
    end

    def onActivateModel(model)
      SU_MCP.attach_change_observer(model)
    rescue
      nil
    end
  end

  # Key change counters by file path so switching files doesn't mix up
  # their counts; an unsaved model is keyed by title so it still gets its
  # own counter.
  def self.change_key(m)
    path = m.path
    (path.nil? || path.empty?) ? "untitled:#{m.title}" : path
  end

  def self.bump_change_counter(m)
    return if @suppress_change_count
    key = change_key(m)
    @change_counters[key] ||= 0
    @change_counters[key] += 1
  rescue
    nil
  end

  def self.attach_change_observer(m)
    return unless m
    key = change_key(m)
    @change_counters[key] ||= 0
    begin
      m.remove_observer(@model_observer) if @model_observer
    rescue
      nil
    end
    @model_observer = ChangeModelObserver.new
    m.add_observer(@model_observer)
    @observed_model = m
  rescue
    nil
  end

  # ---------------------------------------------------------------------------
  # Handlers — each returns a Ruby hash (will be JSON-encoded)
  # ---------------------------------------------------------------------------

  # --- Query ---

  def self.handle_get_model_info(_p)
    m = model
    {
      name:           m.title,
      description:    m.description,
      path:           m.path,
      modified:       m.modified?,
      unit:           m.options['UnitsOptions']['LengthUnit'],
      tool_unit:      @unit,
      entity_count:   m.entities.count,
      layer_count:    m.layers.count,
      material_count: m.materials.count
    }
  end

  def self.handle_list_layers(_p)
    model.layers.map { |l| { name: l.name, visible: l.visible? } }
  end

  def self.handle_list_materials(_p)
    model.materials.map do |mat|
      c = mat.color
      {
        name:    mat.name,
        color:   { r: c.red, g: c.green, b: c.blue, a: c.alpha },
        texture: mat.texture ? mat.texture.filename : nil
      }
    end
  end

  def self.handle_list_entities(p)
    ents = if p['group_name']
             g = find_group(p['group_name'])
             raise "Group '#{p['group_name']}' not found" unless g
             g.entities
           else
             model.entities
           end

    ents.map do |e|
      base = { id: e.entityID, type: e.class.name.split('::').last }
      case e
      when Sketchup::Group
        base[:name]  = e.name
        base[:layer] = e.layer.name
        base[:bounds_min] = out_point(e.bounds.min)
        base[:bounds_max] = out_point(e.bounds.max)
      when Sketchup::ComponentInstance
        base[:name]  = e.definition.name
        base[:layer] = e.layer.name
        base[:bounds_min] = out_point(e.bounds.min)
        base[:bounds_max] = out_point(e.bounds.max)
      when Sketchup::Face
        base[:area]   = out_area(e.area)
        base[:layer]  = e.layer.name
        base[:normal] = vec3(e.normal)
      when Sketchup::Edge
        base[:length] = out_len(e.length)
        base[:layer]  = e.layer.name
      end
      base
    end
  end

  def self.handle_list_components(_p)
    model.definitions.reject(&:image?).map do |d|
      {
        name:           d.name,
        description:    d.description,
        instances:      d.instances.count,
        entity_count:   d.entities.count
      }
    end
  end

  # --- Selection & view ---

  def self.handle_get_selection(_p)
    t = model.edit_transform
    model.selection.map do |e|
      base = {
        id:            e.entityID,
        persistent_id: e.respond_to?(:persistent_id) ? e.persistent_id : nil,
        type:          e.class.name.split('::').last,
        layer:         e.layer.name
      }
      wb = world_bounds(e, t)
      base[:bounds_min] = wb[:min]
      base[:bounds_max] = wb[:max]
      if e.is_a?(Sketchup::Face)
        n = e.normal.transform(t)
        n.normalize!
        base[:normal] = vec3(n)
        base[:plane_point] = out_point(e.vertices.first.position.transform(t))
      end
      if e.respond_to?(:name) && e.name && !e.name.empty?
        base[:name] = e.name
      end
      base
    end
  end

  # Does any entity in `ents` (recursively) contain target_id? Returns the
  # direct child of `ents` that contains it, or nil.
  def self.find_top_level_container(ents, target_id)
    ents.each do |e|
      return e if e.entityID == target_id
      if e.is_a?(Sketchup::Group)
        return e if entity_contains_id?(e.entities, target_id)
      elsif e.is_a?(Sketchup::ComponentInstance)
        return e if entity_contains_id?(e.definition.entities, target_id)
      end
    end
    nil
  end

  def self.entity_contains_id?(ents, target_id)
    ents.each do |e|
      return true if e.entityID == target_id
      if e.is_a?(Sketchup::Group)
        return true if entity_contains_id?(e.entities, target_id)
      elsif e.is_a?(Sketchup::ComponentInstance)
        return true if entity_contains_id?(e.definition.entities, target_id)
      end
    end
    false
  end

  def self.handle_select(p)
    targets = resolve_entities(p)
    active  = model.active_entities
    active_ids = {}
    active.each { |e| active_ids[e.entityID] = true }

    final = []
    final_ids = {}
    notes = []

    targets.each do |e|
      if active_ids[e.entityID]
        unless final_ids[e.entityID]
          final << e
          final_ids[e.entityID] = true
        end
        next
      end

      container = find_top_level_container(active, e.entityID)
      if container
        unless final_ids[container.entityID]
          final << container
          final_ids[container.entityID] = true
        end
        notes << "#{describe_entity(e)} is nested outside the active editing context; " \
                 "selected its container #{describe_entity(container)} instead"
      else
        notes << "#{describe_entity(e)} is not reachable from the active editing context; skipped"
      end
    end

    model.selection.clear
    model.selection.add(final) unless final.empty?

    {
      status: 'ok',
      selected: final.map { |e|
        { id: e.entityID, persistent_id: e.respond_to?(:persistent_id) ? e.persistent_id : nil,
          type: e.class.name.split('::').last }
      },
      notes: notes
    }
  end

  def self.handle_zoom_to(p)
    targets = resolve_entities(p)
    model.active_view.zoom(targets)
    {
      status: 'ok',
      zoomed_to: targets.map { |e|
        { id: e.entityID, persistent_id: e.respond_to?(:persistent_id) ? e.persistent_id : nil,
          type: e.class.name.split('::').last }
      }
    }
  end

  def self.handle_screenshot(p)
    view = model.active_view
    was_modified = model.modified?

    # view.camera is a LIVE wrapper on SU 2017 — it tracks whatever camera
    # the view currently has, so holding onto the Camera object itself and
    # reassigning it back later is a no-op (it "restores" the already-changed
    # state). Point3d/Vector3d values read off it, by contrast, are true
    # snapshots — so capture eye/target/up/perspective/fov/height as plain
    # values and rebuild a fresh Camera from them to restore.
    cam0 = view.camera
    saved_eye         = cam0.eye
    saved_target      = cam0.target
    saved_up          = cam0.up
    saved_perspective = cam0.perspective?
    saved_fov         = saved_perspective ? cam0.fov : nil
    saved_height      = saved_perspective ? nil : cam0.height

    saved_active_section   = model.entities.active_section_plane
    saved_display_sections = model.rendering_options['DisplaySectionPlanes']
    saved_display_axes     = model.rendering_options['DisplaySketchAxes']
    saved_hide_construction = model.rendering_options['HideConstructionGeometry']
    saved_draw_hidden       = model.rendering_options['DrawHidden']

    width = (p['width'] || 1280).to_i
    width = 1920 if width > 1920
    width = 1    if width < 1
    height = p['height'] ? p['height'].to_i : nil

    hide_tags   = p['hide_tags']  || []
    isolate     = p['isolate']    || []
    zoom_names  = p['zoom_to']    || []
    section     = p['section']
    hide_guides = p.key?('hide_guides') ? !!p['hide_guides'] : true

    tmp_path = nil

    begin
      # This whole operation is rolled back, so it must not count as a change.
      @suppress_change_count = true
      model.start_operation('MCP: Screenshot (temp)', true)

      hide_tags.each do |name|
        layer = model.layers[name]
        layer.visible = false if layer
      end

      unless isolate.empty?
        keep_ids = {}
        isolate.each do |name|
          g = find_group(name)
          keep_ids[g.entityID] = true if g
        end
        model.entities.each do |e|
          next unless e.respond_to?(:hidden=)
          e.hidden = !keep_ids[e.entityID]
        end
      end

      if section
        z = len(section['z'].to_f)
        pt = Geom::Point3d.new(0, 0, z)
        normal = Geom::Vector3d.new(0, 0, 1) # normal points toward the hidden side
        plane = model.entities.add_section_plane(pt, normal)
        model.entities.active_section_plane = plane
      end

      model.rendering_options['DisplaySectionPlanes'] = false
      model.rendering_options['DisplaySketchAxes'] = false
      # HideConstructionGeometry covers guides at every nesting level in one
      # flag — setting entity.hidden on each one is both redundant and
      # ineffective here, because DrawHidden ("View > Hidden Geometry") makes
      # SketchUp draw hidden entities as dotted lines anyway. DrawHidden is
      # forced off regardless, so hide_tags/isolate actually hide rather than
      # ghost-render.
      model.rendering_options['HideConstructionGeometry'] = true if hide_guides
      model.rendering_options['DrawHidden'] = false

      apply_view(p['view'])

      unless zoom_names.empty?
        zoom_targets = zoom_names.map { |n| find_group(n) }.compact
        view.zoom(zoom_targets) unless zoom_targets.empty?
      end

      height ||= (width.to_f * view.vpheight / view.vpwidth).round
      height = 1 if height < 1

      view.refresh

      tmp_path = File.join(LOG_DIR, "mcp_screenshot_#{Time.now.to_f.to_s.gsub('.', '')}_#{rand(100_000)}.png")
      view.write_image(tmp_path, width, height, true, 1.0)

      # Discard every temporary change made above (tags, hidden flags,
      # the section plane entity) in one shot, leaving no undo step.
      model.abort_operation
    rescue => e
      model.abort_operation rescue nil
      raise e
    ensure
      # Not entity/undo state, so abort_operation doesn't touch these —
      # restore them by hand regardless of which path got us here.
      restored_camera = Sketchup::Camera.new(saved_eye, saved_target, saved_up)
      restored_camera.perspective = saved_perspective
      if saved_perspective
        restored_camera.fov = saved_fov if saved_fov
      else
        restored_camera.height = saved_height if saved_height
      end
      view.camera = restored_camera
      model.entities.active_section_plane = saved_active_section
      model.rendering_options['DisplaySectionPlanes'] = saved_display_sections
      model.rendering_options['DisplaySketchAxes'] = saved_display_axes
      model.rendering_options['HideConstructionGeometry'] = saved_hide_construction
      model.rendering_options['DrawHidden'] = saved_draw_hidden
      @suppress_change_count = false
      # No view.refresh here: a second GL redraw immediately after
      # write_image's offscreen render is what crashed SU Make 2017 on this
      # machine. SketchUp repaints on its own at the next UI event anyway.
    end

    raise 'Screenshot failed: no image written' unless tmp_path && File.exist?(tmp_path)

    raw = File.open(tmp_path, 'rb') { |f| f.read }
    encoded = [raw].pack('m0') # base64, no line wrapping
    File.delete(tmp_path) rescue nil

    is_modified = model.modified?

    {
      image_base64:     encoded,
      format:            'png',
      width:             width,
      height:            height,
      modified_before:   was_modified,
      modified_after:    is_modified,
      modified_changed:  was_modified != is_modified
    }
  end

  # --- Understanding ---

  def self.handle_list_wall_planes(p)
    group_name = p['group']
    raise "'group' is required" unless group_name && !group_name.to_s.empty?
    grp, = resolve_group(group_name)
    raise "Group '#{group_name}' not found" unless grp

    axis_filter = p['axis'] # 'x', 'y', or nil for both
    recursive   = !!p['recursive']
    min_height  = p.key?('min_height') ? len(p['min_height'].to_f) : metres(1.0)

    raw = []

    walk = lambda do |ents, t|
      ents.each do |e|
        if e.is_a?(Sketchup::Face)
          n = e.normal.transform(t)
          n.normalize!
          next if n.z.abs > 0.02 # not (close enough to) vertical

          axis =
            if n.x.abs > 0.999 then 'x'
            elsif n.y.abs > 0.999 then 'y'
            end
          next unless axis
          next if axis_filter && axis_filter != axis

          pts = e.vertices.map { |v| v.position.transform(t) }
          if axis == 'x'
            at_vals   = pts.map(&:x)
            span_vals = pts.map(&:y)
          else
            at_vals   = pts.map(&:y)
            span_vals = pts.map(&:x)
          end
          z_vals = pts.map(&:z)
          z0 = z_vals.min
          z1 = z_vals.max
          next if (z1 - z0) < min_height

          at = at_vals.inject(0.0) { |s, v| s + v } / at_vals.length.to_f

          raw << {
            axis: axis, at: at,
            span_lo: span_vals.min, span_hi: span_vals.max,
            z0: z0, z1: z1,
            area: e.area,
            normal_sign: (axis == 'x' ? (n.x >= 0 ? 1 : -1) : (n.y >= 0 ? 1 : -1)),
            material: e.material ? e.material.name : nil
          }
        elsif recursive && e.is_a?(Sketchup::Group)
          walk.call(e.entities, t * e.transformation)
        elsif recursive && e.is_a?(Sketchup::ComponentInstance)
          walk.call(e.definition.entities, t * e.transformation)
        end
      end
    end
    walk.call(grp.entities, world_transform(grp))

    tol = metres(0.0015) # 1.5 mm

    result = []
    ['x', 'y'].each do |axis|
      next if axis_filter && axis_filter != axis
      members = raw.select { |r| r[:axis] == axis }.sort_by { |r| r[:at] }

      cluster = []
      flush = lambda do
        next if cluster.empty?
        avg_at = cluster.inject(0.0) { |s, m| s + m[:at] } / cluster.length.to_f
        lo_key, hi_key = axis == 'x' ? [:y0, :y1] : [:x0, :x1]
        spans = cluster.sort_by { |m| m[:z0] }.map { |m|
          {
            lo_key => out_len(m[:span_lo]),
            hi_key => out_len(m[:span_hi]),
            z0: out_len(m[:z0]),
            z1: out_len(m[:z1]),
            at: out_len(m[:at]),
            area: out_area(m[:area]),
            normal_sign: m[:normal_sign],
            material: m[:material]
          }
        }
        result << { axis: axis, at: out_len(avg_at), spans: spans }
        cluster = []
      end

      members.each do |m|
        if cluster.empty? || (m[:at] - cluster.last[:at]).abs <= tol
          cluster << m
        else
          flush.call
          cluster << m
        end
      end
      flush.call
    end

    result
  end

  def self.face_centroid(face, t)
    pts = face.vertices.map { |v| v.position.transform(t) }
    cx = pts.map(&:x).inject(0.0) { |s, v| s + v } / pts.length.to_f
    cy = pts.map(&:y).inject(0.0) { |s, v| s + v } / pts.length.to_f
    cz = pts.map(&:z).inject(0.0) { |s, v| s + v } / pts.length.to_f
    Geom::Point3d.new(cx, cy, cz)
  end

  def self.handle_measure(p)
    if p['point_a'] && p['point_b']
      a = parse_point(p['point_a'])
      b = parse_point(p['point_b'])
      return { mode: 'points', distance: out_len(a.distance(b)) }
    end

    if p['face_id_a'] && p['face_id_b']
      res_a = find_with_transform_by_persistent_id(p['face_id_a'])
      res_b = find_with_transform_by_persistent_id(p['face_id_b'])
      raise "face_id_a (#{p['face_id_a']}) not found" unless res_a
      raise "face_id_b (#{p['face_id_b']}) not found" unless res_b
      face_a, ta = res_a
      face_b, tb = res_b
      raise "face_id_a is not a Face" unless face_a.is_a?(Sketchup::Face)
      raise "face_id_b is not a Face" unless face_b.is_a?(Sketchup::Face)

      normal_a = face_a.normal.transform(ta)
      normal_a.normalize!
      pt_a = face_a.vertices.first.position.transform(ta)
      centroid_a = face_centroid(face_a, ta)
      centroid_b = face_centroid(face_b, tb)

      perp_dist = (centroid_b - pt_a).dot(normal_a).abs
      return {
        mode: 'faces',
        perpendicular_distance: out_len(perp_dist),
        centroid_distance: out_len(centroid_a.distance(centroid_b))
      }
    end

    if p['axis'] && p['at']
      axis = p['axis']
      raise "axis must be 'x', 'y', or 'z'" unless %w[x y z].include?(axis)
      at = p['at']

      if p['group']
        g, scope_t = resolve_group(p['group'])
        raise "Group '#{p['group']}' not found" unless g
        scope_entities = g.entities
      else
        scope_entities = model.entities
        scope_t = Geom::Transformation.new
      end

      case axis
      when 'x'
        base = Geom::Point3d.new(0, len(at['y'].to_f), len(at['z'].to_f))
        dir  = X_AXIS
      when 'y'
        base = Geom::Point3d.new(len(at['x'].to_f), 0, len(at['z'].to_f))
        dir  = Y_AXIS
      when 'z'
        base = Geom::Point3d.new(len(at['x'].to_f), len(at['y'].to_f), 0)
        dir  = Z_AXIS
      end

      hits = []
      walk = lambda do |ents, t, group_name|
        ents.each do |e|
          if e.is_a?(Sketchup::Face)
            plane_pt = e.vertices.first.position.transform(t)
            n = e.normal.transform(t)
            n.normalize!
            denom = dir.dot(n)
            next if denom.abs < 1e-9 # probe line parallel to this face's plane

            tparam = (plane_pt - base).dot(n) / denom
            ipoint = base.offset(dir, tparam)

            local_pt = ipoint.transform(t.inverse)
            classification = e.classify_point(local_pt)
            inside_mask = Sketchup::Face::PointInside | Sketchup::Face::PointOnVertex | Sketchup::Face::PointOnEdge
            next if (classification & inside_mask) == 0

            hits << {
              point: ipoint,
              group: group_name,
              normal_sign: (denom >= 0 ? 1 : -1),
              material: e.material ? e.material.name : nil
            }
          elsif e.is_a?(Sketchup::Group)
            walk.call(e.entities, t * e.transformation, e.name.to_s.empty? ? group_name : e.name)
          elsif e.is_a?(Sketchup::ComponentInstance)
            walk.call(e.definition.entities, t * e.transformation, e.definition.name)
          end
        end
      end
      walk.call(scope_entities, scope_t, (p['group'] || nil))

      coord_of = lambda { |pt| axis == 'x' ? pt.x : (axis == 'y' ? pt.y : pt.z) }
      hits_sorted = hits.sort_by { |h| coord_of.call(h[:point]) }

      crossings = hits_sorted.map { |h|
        { coord: out_len(coord_of.call(h[:point])), group: h[:group],
          normal_sign: h[:normal_sign], material: h[:material] }
      }

      gaps = []
      (1...hits_sorted.length).each do |i|
        d = (coord_of.call(hits_sorted[i][:point]) - coord_of.call(hits_sorted[i - 1][:point])).abs
        gaps << out_len(d)
      end

      return { mode: 'probe', axis: axis, crossings: crossings, gaps: gaps }
    end

    raise "Provide point_a+point_b, or face_id_a+face_id_b, or axis+at (probe mode)"
  end

  # Recursively collect faces, edges, and (deduplicated, world-space) vertex
  # positions under a group, carrying the accumulated transform.
  # Vertices are keyed by vertex and placement: a component placed several
  # times shares its Vertex objects between copies, and keying by vertex
  # alone checked only the first copy. Each placement gets its own transform
  # object during the walk, so its object_id tells the copies apart.
  def self.audit_collect(grp, base_t = nil)
    faces = []
    edges = []
    vertex_world = {} # "vertex.entityID:placement" => world Geom::Point3d

    # Each face record also carries :path (names of the nested groups /
    # components it lives in, relative to grp, '' for grp's own faces) and
    # :in_solid (true when its innermost container is a closed solid).
    walk = lambda do |ents, t, path, solid|
      ents.each do |e|
        case e
        when Sketchup::Face
          faces << { face: e, t: t, path: path, in_solid: solid }
        when Sketchup::Edge
          edges << { edge: e, t: t, path: path }
          [e.start, e.end].each do |v|
            key = "#{v.entityID}:#{t.object_id}"
            vertex_world[key] ||= v.position.transform(t)
          end
        when Sketchup::Group
          walk.call(e.entities, t * e.transformation, audit_join_path(path, e.name), audit_closed_solid?(e))
        when Sketchup::ComponentInstance
          label = e.name.to_s.empty? ? e.definition.name : e.name
          walk.call(e.definition.entities, t * e.transformation, audit_join_path(path, label), audit_closed_solid?(e))
        end
      end
    end
    walk.call(grp.entities, base_t || world_transform(grp), '', false)
    [faces, edges, vertex_world]
  end

  def self.audit_join_path(path, name)
    n = name.to_s
    path.empty? ? n : "#{path}/#{n}"
  end

  # True when a group/component instance is a closed solid (every edge shared
  # by exactly two faces). Its end faces etc. are legitimate, not defects.
  def self.audit_closed_solid?(inst)
    inst.respond_to?(:manifold?) && inst.manifold? ? true : false
  rescue StandardError
    false
  end

  # Yields (i, j, distance) for every pair of points in pts (Point3d, inches)
  # at most tol apart, with i < j. Points are bucketed into a grid of cells
  # tol wide, so only neighbouring cells are compared: roughly linear time,
  # where comparing every pair froze SketchUp on large groups.
  def self.each_close_pair(pts, tol)
    cell = tol > 0 ? tol.to_f : 1e-6
    grid = {}
    pts.each_with_index do |pt, i|
      key = [(pt.x / cell).floor, (pt.y / cell).floor, (pt.z / cell).floor]
      (grid[key] ||= []) << i
    end
    grid.each do |(cx, cy, cz), members|
      (-1..1).each do |dx|
        (-1..1).each do |dy|
          (-1..1).each do |dz|
            others = grid[[cx + dx, cy + dy, cz + dz]]
            next unless others
            members.each do |i|
              others.each do |j|
                next unless i < j
                d = pts[i].distance(pts[j])
                yield i, j, d if d <= tol
              end
            end
          end
        end
      end
    end
  end

  def self.cap_list(list)
    { items: list.first(50), total: list.length }
  end

  def self.audit_one_group(grp)
    faces, edges, vertex_world = audit_collect(grp)

    tol_coincident = metres(0.002)  # 2 mm
    tol_planar     = metres(0.0005) # 0.5 mm
    tiny_area_m2   = 0.005

    stray = []
    open_e = []
    nonmanifold = []
    edges.each do |rec|
      e = rec[:edge]
      t = rec[:t]
      fc = e.faces.length
      item = { start: out_point(e.start.position.transform(t)), end: out_point(e.end.position.transform(t)) }
      if fc == 0
        stray << item
      elsif fc == 1
        open_e << item
      elsif fc > 2
        nonmanifold << item.merge(face_count: fc)
      end
    end

    # Duplicate edges: same endpoints (in either order) within tolerance,
    # but different Edge entities. This is what causes "deleting a line
    # deletes the wall" — two coincident edges look like one.
    # Candidate pairs come from endpoints that lie close together: endpoint k
    # belongs to edge k / 2 (even k = start, odd k = end).
    ends = []
    edges.each do |rec|
      ends << rec[:edge].start.position.transform(rec[:t])
      ends << rec[:edge].end.position.transform(rec[:t])
    end
    duplicate = []
    checked = {}
    each_close_pair(ends, tol_coincident) do |k1, k2, _d|
      i = k1 / 2
      j = k2 / 2
      next if i == j || checked[[i, j]]
      checked[[i, j]] = true
      si, pi = ends[2 * i], ends[2 * i + 1]
      sj, pj = ends[2 * j], ends[2 * j + 1]
      same_dir = si.distance(sj) <= tol_coincident && pi.distance(pj) <= tol_coincident
      flip_dir = si.distance(pj) <= tol_coincident && pi.distance(sj) <= tol_coincident
      next unless same_dir || flip_dir
      # cross_group: the two edges live in different groups/components
      # (e.g. a wall group sharing an edge with its parent). That is
      # inherent to separate groups and harmless; only same-collection
      # duplicates cause 'deleting a line deletes the wall'.
      duplicate << {
        a_start: out_point(si), a_end: out_point(pi),
        b_start: out_point(sj), b_end: out_point(pj),
        cross_group: !edges[i][:t].equal?(edges[j][:t])
      }
    end

    # Near-coincident vertex pairs: different Vertex objects, very close.
    near_vertices = []
    ids = vertex_world.keys
    each_close_pair(ids.map { |id| vertex_world[id] }, tol_coincident) do |i, j, d|
      next unless d > 0.0
      near_vertices << { a: out_point(vertex_world[ids[i]]), b: out_point(vertex_world[ids[j]]),
                         distance: out_len(d),
                         cross_group: ids[i].split(':').last != ids[j].split(':').last }
    end

    tiny = []
    tiny_by_group = Hash.new(0)
    tiny_skipped_in_solids = 0
    nonplanar = []
    faces.each do |rec|
      f = rec[:face]
      t = rec[:t]
      area_m2 = f.area / (INCHES_PER_METRE * INCHES_PER_METRE)
      center = face_centroid(f, t)

      if area_m2 < tiny_area_m2
        if rec[:in_solid]
          tiny_skipped_in_solids += 1
        else
          label = rec[:path].empty? ? '(top level)' : rec[:path]
          tiny << { center: out_point(center), area: out_area(f.area), group_path: label }
          tiny_by_group[label] += 1
        end
      end

      pl = f.plane
      a, b, c, d = pl
      max_dev = f.vertices.map { |v|
        p = v.position
        (a * p.x + b * p.y + c * p.z + d).abs
      }.max
      nonplanar << { center: out_point(center), max_deviation: out_len(max_dev) } if max_dev > tol_planar
    end

    mergeable = []
    edges.each do |rec|
      e = rec[:edge]
      t = rec[:t]
      next unless e.faces.length == 2
      f1, f2 = e.faces
      n1 = f1.normal.transform(t)
      n1.normalize!
      n2 = f2.normal.transform(t)
      n2.normalize!
      next unless n1.dot(n2) > 0.9999 # same plane, same orientation (not opposite sides of a shell)

      mat1 = f1.material ? f1.material.name : nil
      mat2 = f2.material ? f2.material.name : nil
      next unless mat1 == mat2

      pl = f1.plane
      a, b, c, d = pl
      sample = f2.vertices.first.position
      dev = (a * sample.x + b * sample.y + c * sample.z + d).abs
      next if dev > tol_planar

      bk1 = f1.back_material ? f1.back_material.name : nil
      bk2 = f2.back_material ? f2.back_material.name : nil

      mergeable << {
        edge: { start: out_point(e.start.position.transform(t)), end: out_point(e.end.position.transform(t)) },
        material: mat1,
        # merge_coplanar skips these by default, since merging would discard
        # one of the two back materials.
        back_materials_differ: bk1 != bk2
      }
    end

    {
      face_count: faces.length,
      edge_count: edges.length,
      stray_edges:              cap_list(stray),
      open_edges:                cap_list(open_e),
      nonmanifold_edges:         cap_list(nonmanifold),
      duplicate_edges:           cap_list(duplicate),
      duplicate_edges_cross_group: duplicate.count { |x| x[:cross_group] },
      near_coincident_vertices:  cap_list(near_vertices),
      near_coincident_vertices_cross_group: near_vertices.count { |x| x[:cross_group] },
      tiny_faces:                cap_list(tiny),
      tiny_faces_by_group:       tiny_by_group,
      tiny_faces_skipped_in_closed_solids: tiny_skipped_in_solids,
      nonplanar_faces:           cap_list(nonplanar),
      mergeable_coplanar_seams:  cap_list(mergeable)
    }
  end

  def self.handle_audit_geometry(p)
    if p['group']
      grp, = resolve_group(p['group'])
      raise "Group '#{p['group']}' not found" unless grp
      { group: grp.name }.merge(audit_one_group(grp))
    else
      # Example lists for every group overflow the caller's context on a real
      # model, so the whole-model audit returns counts unless asked for more.
      details = p['details'] == true || p['details'].to_s == 'true'
      model.entities.grep(Sketchup::Group).map do |grp|
        result = { group: grp.name }.merge(audit_one_group(grp))
        details ? result : audit_counts_only(result)
      end
    end
  end

  # Replaces each { items:, total: } category with its total.
  def self.audit_counts_only(result)
    out = {}
    result.each { |k, v| out[k] = v.is_a?(Hash) && v.key?(:items) ? v[:total] : v }
    out
  end

  def self.handle_changes_since(p)
    m = model
    attach_change_observer(m) if @observed_model.nil? || !@observed_model.equal?(m)
    key = change_key(m)
    current = @change_counters[key] || 0
    current_token = "#{@session_id}:#{current}"

    token_in = p['token'].to_s
    changed =
      if token_in.empty?
        true
      else
        in_session, in_counter = token_in.split(':', 2)
        in_session != @session_id || in_counter.to_i != current
      end

    { token: current_token, modified: m.modified?, changed: changed }
  end

  # --- Editing (Batch 3) ---
  #
  # Every tool below goes through with_edit, which gives it exactly one undo
  # step, runs the brief's §5 post-check (abort on a non-planar face, delete
  # edges this edit stranded), and reports before/after health numbers so the
  # caller can verify the result with changes_since / audit_geometry.

  EDIT_PLANAR_TOL_M     = 0.0005 # a vertex this far off its face's plane fails the post-check
  EDIT_COINCIDENT_TOL_M = 0.002  # "near-coincident" vertex pair distance
  EDIT_PLANE_TOL_M      = 0.0015 # default tolerance for "lies on this plane"
  EDIT_SNAP_TOL_M       = 0.0035 # snap new points onto existing vertices within this

  # Collection labels look like "Basement/Garden door – frame".
  # A caller may name either the whole path or just the last segment.
  def self.collection_matches?(label, name)
    return true if label == name
    label.split('/').last == name
  end

  # include/exclude filtering plus the multi-collection guard. A plane move
  # takes everything on that plane, including geometry that only
  # coincidentally shares it, so spanning more than one collection has to be
  # asked for rather than discovered afterwards.
  def self.filter_collections(per_collection, p)
    includes = p['include']
    excludes = p['exclude'] || []
    raise "'include' must be an array of group names" if includes && !includes.is_a?(Array)
    raise "'exclude' must be an array of group names" unless excludes.is_a?(Array)

    kept = per_collection.keys.reject { |label| excludes.any? { |n| collection_matches?(label, n) } }
    if includes
      kept = kept.select { |label| includes.any? { |n| collection_matches?(label, n) } }
      if kept.empty?
        raise "None of the collections named in 'include' hold any of the vertices to move. " \
              "Available: #{per_collection.keys.inspect}"
      end
    elsif kept.length > 1
      raise "Aborted, nothing changed: the vertices to move span #{kept.length} separate collections — " \
            "#{per_collection.select { |k, _| kept.include?(k) }.inspect}. A plane move takes everything on " \
            "that plane, including geometry that only happens to share it (a door frame sitting in the wall " \
            "plane, say). List the ones you mean in 'include', or drop the others with 'exclude'."
    end

    raise 'Nothing left to move after include/exclude filtering' if kept.empty?
    kept
  end

  def self.require_group(name)
    raise "'group' is required" if name.nil? || name.to_s.empty?
    g, = resolve_group(name)
    raise "Group '#{name}' not found" unless g
    g
  end

  def self.axis_index(axis)
    raise "axis must be 'x', 'y' or 'z'" unless %w[x y z].include?(axis.to_s)
    axis.to_s
  end

  def self.coord_on(pt, axis)
    axis == 'x' ? pt.x : (axis == 'y' ? pt.y : pt.z)
  end

  def self.axis_vector(axis, amount)
    case axis
    when 'x' then Geom::Vector3d.new(amount, 0, 0)
    when 'y' then Geom::Vector3d.new(0, amount, 0)
    else          Geom::Vector3d.new(0, 0, amount)
    end
  end

  # Health metrics compared before and after every edit (brief §5).
  def self.health_snapshot(grp, base_t = nil)
    faces, edges, vertex_world = audit_collect(grp, base_t)
    tol = metres(EDIT_COINCIDENT_TOL_M)

    open_edges = 0
    stray_ids = {}
    edges.each do |rec|
      fc = rec[:edge].faces.length
      open_edges += 1 if fc == 1
      stray_ids[rec[:edge].entityID] = true if fc == 0
    end

    near = 0
    each_close_pair(vertex_world.values, tol) { |_i, _j, d| near += 1 if d > 0.0 }

    { faces: faces.length, edges: edges.length, open_edges: open_edges,
      stray_ids: stray_ids, near_coincident: near }
  end

  def self.nonplanar_faces(grp, base_t = nil)
    faces, = audit_collect(grp, base_t)
    tol = metres(EDIT_PLANAR_TOL_M)
    bad = []
    faces.each do |rec|
      f = rec[:face]
      next unless f.valid?
      a, b, c, d = f.plane
      dev = f.vertices.map { |v|
        pt = v.position
        (a * pt.x + b * pt.y + c * pt.z + d).abs
      }.max
      bad << { center: out_point(face_centroid(f, rec[:t])), deviation: out_len(dev) } if dev > tol
    end
    bad
  end

  # One undo step, post-check, and a change report. The block performs the
  # edit and returns a hash describing what it did. dry_run rolls the whole
  # thing back after measuring, so the report says what *would* have changed.
  def self.with_edit(grp, op_name, dry_run, allow_splits = false, base_t = nil)
    before = health_snapshot(grp, base_t)
    # A dry run rolls itself back, so it must not register as a change.
    @suppress_change_count = true if dry_run
    model.start_operation(op_name, true)
    aborted = false

    begin
      detail = yield

      bad = nonplanar_faces(grp, base_t)
      unless bad.empty?
        model.abort_operation
        aborted = true
        worst = bad.map { |b| b[:deviation] }.max
        raise "Aborted, nothing changed: #{bad.length} face(s) would be left non-planar " \
              "(worst #{worst} #{@unit} off plane, limit 0.5 mm). First: #{bad.first(3).inspect}"
      end

      # Delete edges this edit stranded, but leave pre-existing strays alone.
      removed_stray = 0
      _f, edges_after = audit_collect(grp, base_t)
      edges_after.each do |rec|
        e = rec[:edge]
        next unless e.valid?
        next unless e.faces.length == 0
        next if before[:stray_ids][e.entityID]
        e.erase!
        removed_stray += 1
      end

      after = health_snapshot(grp, base_t)

      # A pure vertex move must not change the face/edge count. If it did,
      # SketchUp split a face to keep it planar — which means only part of
      # something moved and the geometry got folded. That is the quiet
      # failure mode (a vertex left behind in an unmapped range), and it
      # shows up here rather than as a non-planar face.
      if !allow_splits && (after[:faces] > before[:faces] || after[:edges] > before[:edges])
        model.abort_operation
        aborted = true
        raise "Aborted, nothing changed: the move split geometry " \
              "(faces #{before[:faces]}->#{after[:faces]}, edges #{before[:edges]}->#{after[:edges]}). " \
              "SketchUp splits a face rather than leave it bent, so this means only part of a face moved " \
              "and the result would be folded. Widen the selection (or the mapped range) so whole faces " \
              "move together, or pass allow_splits:true if the split is intended."
      end

      if dry_run
        model.abort_operation
        aborted = true
      else
        model.commit_operation
      end

      delta = lambda { |k| { before: before[k], after: after[k], delta: after[k] - before[k] } }

      {
        applied: !dry_run,
        dry_run: dry_run,
        operation: op_name,
        detail: detail,
        post_check: {
          nonplanar_faces: 0,
          stray_edges_removed: removed_stray,
          faces: delta.call(:faces),
          edges: delta.call(:edges),
          open_edges: delta.call(:open_edges),
          near_coincident_vertices: delta.call(:near_coincident)
        }
      }
    rescue => e
      unless aborted
        begin
          model.abort_operation
        rescue
          nil
        end
      end
      raise e
    ensure
      @suppress_change_count = false
    end
  end

  def self.orientation_kind(n)
    if n.z.abs < 0.01
      :vertical
    elsif n.z.abs > 0.999
      :horizontal
    else
      :other
    end
  end

  # Newell's method: a polygon normal that tolerates slight non-planarity,
  # used to predict a face's orientation after a move without touching it.
  def self.newell_normal(points)
    return nil if points.length < 3
    nx = 0.0
    ny = 0.0
    nz = 0.0
    points.each_with_index do |p1, i|
      p2 = points[(i + 1) % points.length]
      nx += (p1.y - p2.y) * (p1.z + p2.z)
      ny += (p1.z - p2.z) * (p1.x + p2.x)
      nz += (p1.x - p2.x) * (p1.y + p2.y)
    end
    v = Geom::Vector3d.new(nx, ny, nz)
    return nil if v.length == 0
    v.normalize!
    v
  end

  # Pre-flight guards for a vertex move. Both are predictive, so an unsafe
  # move is refused without ever opening an operation.
  #
  # 1. Within one face, the vertices lying on a source plane must either all
  #    move or all stay. Moving only some of them tilts the face: it stays
  #    perfectly planar and nothing gets split, so the non-planar and split
  #    guards both report "fine" while the wall is now skewed. This is the
  #    silent distortion these tools exist to prevent. A face merely *touching*
  #    the plane (a perpendicular wall with two corners on it) is unaffected —
  #    all of its on-plane corners move together and it simply stretches.
  # 2. A face that is vertical or horizontal must stay vertical or horizontal.
  #
  # deltas_by_vertex_id maps vertex entityID -> world-space Vector3d.
  def self.check_move_safety(grp, axis, plane_coords, tol, deltas_by_vertex_id)
    faces, = audit_collect(grp)
    partial = []
    reoriented = []

    faces.each do |rec|
      f = rec[:face]
      next unless f.valid?
      t = rec[:t]

      verts = f.vertices
      world = verts.map { |v| v.position.transform(t) }

      plane_coords.each do |pc|
        on_plane = 0
        moving = 0
        verts.each_with_index do |v, i|
          next unless (coord_on(world[i], axis) - pc).abs <= tol
          on_plane += 1
          moving += 1 if deltas_by_vertex_id[v.entityID]
        end
        next unless on_plane > 0 && moving > 0 && moving < on_plane
        if partial.length < 25
          partial << { center: out_point(face_centroid(f, t)), plane: out_len(pc),
                       corners_on_plane: on_plane, corners_moving: moving }
        end
      end

      n_before = f.normal.transform(t)
      n_before.normalize!
      before_kind = orientation_kind(n_before)
      next if before_kind == :other

      outer = f.outer_loop.vertices
      predicted = outer.map do |v|
        wp = v.position.transform(t)
        d = deltas_by_vertex_id[v.entityID]
        d ? wp.offset(d) : wp
      end
      n_after = newell_normal(predicted)
      next unless n_after
      after_kind = orientation_kind(n_after)
      next if after_kind == before_kind

      if reoriented.length < 25
        reoriented << { center: out_point(face_centroid(f, t)),
                        was: before_kind.to_s, would_become: after_kind.to_s }
      end
    end

    [partial, reoriented]
  end

  def self.raise_if_unsafe_move(grp, axis, plane_coords, tol, deltas, allow_distortion)
    return if allow_distortion
    partial, reoriented = check_move_safety(grp, axis, plane_coords, tol, deltas)

    unless partial.empty?
      raise "Aborted, nothing changed: on #{partial.length}+ face(s), only some of the corners lying on the " \
            "moved plane would move. The face would stay flat and nothing would be split, so it would simply " \
            "tilt — a silently distorted wall. Widen the selection (drop or widen the range filter) so whole " \
            "faces move together, split the face first, or pass allow_distortion:true if the tilt is intended. " \
            "First few: #{partial.first(5).inspect}"
    end

    unless reoriented.empty?
      raise "Aborted, nothing changed: #{reoriented.length}+ face(s) would stop being " \
            "#{reoriented.first[:was]} (becoming #{reoriented.first[:would_become]}). Pass " \
            "allow_distortion:true if that is intended. First few: #{reoriented.first(5).inspect}"
    end
  end

  # Vertices under a group, bucketed by the Entities collection that owns
  # them — transform_by_vectors works per-collection — with the accumulated
  # world transform for each bucket.
  def self.collect_vertex_buckets(grp)
    buckets = []
    walk = lambda do |ents, t, label|
      seen = {}
      verts = []
      ents.each do |e|
        if e.is_a?(Sketchup::Edge)
          [e.start, e.end].each do |v|
            next if seen[v.entityID]
            seen[v.entityID] = true
            verts << v
          end
        elsif e.is_a?(Sketchup::Group)
          nm = e.name.to_s.empty? ? 'unnamed group' : e.name
          walk.call(e.entities, t * e.transformation, "#{label}/#{nm}")
        elsif e.is_a?(Sketchup::ComponentInstance)
          walk.call(e.definition.entities, t * e.transformation, "#{label}/#{e.definition.name}")
        end
      end
      buckets << { entities: ents, t: t, vertices: verts, label: label } unless verts.empty?
    end
    walk.call(grp.entities, world_transform(grp), grp.name.to_s.empty? ? 'group' : grp.name)
    buckets
  end

  def self.handle_move_plane(p)
    grp  = require_group(p['group'])
    axis = axis_index(p['axis'])
    raise "'from' is required" if p['from'].nil?
    raise "'to' is required"   if p['to'].nil?

    from = len(p['from'].to_f)
    to   = len(p['to'].to_f)
    tol  = p.key?('tolerance') ? len(p['tolerance'].to_f) : metres(EDIT_PLANE_TOL_M)
    dry  = !!p['dry_run']

    ranges = {}
    %w[x_range y_range z_range].each do |k|
      next unless p[k]
      raise "#{k} must be [min, max] in #{@unit}" unless p[k].is_a?(Array) && p[k].length == 2
      ranges[k[0, 1]] = [len(p[k][0].to_f), len(p[k][1].to_f)]
    end

    shift = to - from
    raise "'from' and 'to' are the same, nothing to move" if shift == 0
    delta_world = axis_vector(axis, shift)

    buckets = collect_vertex_buckets(grp)
    plan = []
    sample = []
    deltas = {}
    per_collection = {}
    total = 0

    buckets.each do |b|
      local_delta = delta_world.transform(b[:t].inverse)
      sel_v = []
      sel_vec = []
      b[:vertices].each do |v|
        wp = v.position.transform(b[:t])
        next unless (coord_on(wp, axis) - from).abs <= tol
        in_region = true
        ranges.each do |ax, lohi|
          c = coord_on(wp, ax)
          in_region = false if c < lohi[0] - tol || c > lohi[1] + tol
        end
        next unless in_region
        sel_v << v
        sel_vec << local_delta
        deltas[v.entityID] = delta_world
        sample << out_point(wp) if sample.length < 20
        total += 1
      end
      unless sel_v.empty?
        plan << { entities: b[:entities], verts: sel_v, vecs: sel_vec, label: b[:label] }
        per_collection[b[:label]] = sel_v.length
      end
    end

    if total == 0
      raise "No vertices lie on #{axis} = #{out_len(from)} within #{out_len(tol)} #{@unit}" +
            (ranges.empty? ? '' : ' and the given region')
    end

    kept = filter_collections(per_collection, p)
    plan = plan.select { |x| kept.include?(x[:label]) }
    per_collection = per_collection.select { |k, _| kept.include?(k) }
    total = plan.inject(0) { |sum, x| sum + x[:verts].length }
    keep_ids = {}
    plan.each { |x| x[:verts].each { |v| keep_ids[v.entityID] = true } }
    deltas = deltas.select { |vid, _| keep_ids[vid] }

    raise_if_unsafe_move(grp, axis, [from], tol, deltas, !!p['allow_distortion'])

    with_edit(grp, "MCP: move_plane #{axis} #{out_len(from)}->#{out_len(to)}", dry, !!p['allow_splits']) do
      plan.each { |x| x[:entities].transform_by_vectors(x[:verts], x[:vecs]) }
      {
        group: grp.name, axis: axis,
        from: out_len(from), to: out_len(to), distance: out_len(shift),
        tolerance: out_len(tol),
        vertices_moved: total,
        vertices_per_collection: per_collection,
        sample_points_before_move: sample
      }
    end
  end

  def self.handle_remap_planes(p)
    grp  = require_group(p['group'])
    axis = axis_index(p['axis'])
    map  = p['map']
    raise "'map' must be a non-empty array of {from, to}" unless map.is_a?(Array) && !map.empty?

    tol = p.key?('tolerance') ? len(p['tolerance'].to_f) : metres(EDIT_PLANE_TOL_M)
    dry = !!p['dry_run']

    pairs = map.map { |m|
      raise "each map entry needs 'from' and 'to'" if m['from'].nil? || m['to'].nil?
      { from: len(m['from'].to_f), to: len(m['to'].to_f) }
    }.sort_by { |m| m[:from] }

    shift_beyond = nil
    if p['shift_beyond']
      sb = p['shift_beyond']
      raise "shift_beyond needs 'from' and 'delta'" if sb['from'].nil? || sb['delta'].nil?
      shift_beyond = { from: len(sb['from'].to_f), delta: len(sb['delta'].to_f) }
    end

    lo = pairs.first[:from]
    hi = pairs.last[:from]

    buckets = collect_vertex_buckets(grp)
    plan = []
    unmapped = []
    per_plane = {}
    deltas = {}
    per_collection = {}
    shifted = 0
    total = 0

    buckets.each do |b|
      sel_v = []
      sel_vec = []
      b[:vertices].each do |v|
        wp = v.position.transform(b[:t])
        c = coord_on(wp, axis)

        hit = pairs.find { |m| (c - m[:from]).abs <= tol }
        if hit
          key = out_len(hit[:from]).to_s
          per_plane[key] = (per_plane[key] || 0) + 1
          d = hit[:to] - hit[:from]
          next if d == 0
          sel_v << v
          sel_vec << axis_vector(axis, d).transform(b[:t].inverse)
          deltas[v.entityID] = axis_vector(axis, d)
          total += 1
          next
        end

        if shift_beyond && c > shift_beyond[:from] + tol
          sel_v << v
          sel_vec << axis_vector(axis, shift_beyond[:delta]).transform(b[:t].inverse)
          deltas[v.entityID] = axis_vector(axis, shift_beyond[:delta])
          shifted += 1
          total += 1
          next
        end

        # Strictly inside the mapped span with no rule: moving its neighbours
        # while it stays put is exactly the silent distortion to prevent.
        if c > lo + tol && c < hi - tol
          unmapped << { point: out_point(wp), coord: out_len(c) } if unmapped.length < 25
        end
      end
      unless sel_v.empty?
        plan << { entities: b[:entities], verts: sel_v, vecs: sel_vec, label: b[:label] }
        per_collection[b[:label]] = sel_v.length
      end
    end

    unless unmapped.empty?
      raise "Aborted, nothing changed: #{unmapped.length}+ vertex/vertices lie strictly between the mapped " \
            "planes #{out_len(lo)} and #{out_len(hi)} on #{axis} with no rule covering them. They would stay " \
            "put while their neighbours move, distorting the geometry. Add a map entry or shift_beyond for " \
            "them, or narrow the mapped span. First few: #{unmapped.first(5).inspect}"
    end

    raise "No vertices matched any mapped plane on #{axis}" if total == 0 && per_plane.empty?

    kept = filter_collections(per_collection, p)
    plan = plan.select { |x| kept.include?(x[:label]) }
    per_collection = per_collection.select { |k, _| kept.include?(k) }
    total = plan.inject(0) { |sum, x| sum + x[:verts].length }
    keep_ids = {}
    plan.each { |x| x[:verts].each { |v| keep_ids[v.entityID] = true } }
    deltas = deltas.select { |vid, _| keep_ids[vid] }

    raise_if_unsafe_move(grp, axis, pairs.map { |m| m[:from] }, tol, deltas, !!p['allow_distortion'])

    with_edit(grp, "MCP: remap_planes #{axis} (#{pairs.length} planes)", dry, !!p['allow_splits']) do
      plan.each { |x| x[:entities].transform_by_vectors(x[:verts], x[:vecs]) }
      {
        group: grp.name, axis: axis,
        map: pairs.map { |m| { from: out_len(m[:from]), to: out_len(m[:to]) } },
        shift_beyond: shift_beyond ? { from: out_len(shift_beyond[:from]), delta: out_len(shift_beyond[:delta]) } : nil,
        tolerance: out_len(tol),
        vertices_moved: total,
        vertices_shifted_beyond: shifted,
        vertices_per_plane: per_plane,
        vertices_per_collection: per_collection
      }
    end
  end

  # --- Openings ---

  def self.require_group_deep(name)
    raise "'group' is required" if name.nil? || name.to_s.empty?
    found = resolve_group(name, true)
    raise "Group '#{name}' not found anywhere in the model" unless found
    found[0, 2]
  end

  # A point on the wall plane, given the wall axis coordinate, the in-plane
  # horizontal coordinate and z.
  def self.wall_point(axis, at, u, z)
    axis == 'x' ? Geom::Point3d.new(at, u, z) : Geom::Point3d.new(u, at, z)
  end

  # Snapping rule from the brief: pull a new point onto an existing vertex
  # within a few millimetres, otherwise duplicate near-coincident edges appear.
  def self.snap_to_existing(world_pt, existing, tol)
    best = nil
    best_d = tol
    existing.each do |wp|
      d = wp.distance(world_pt)
      if d <= best_d
        best_d = d
        best = wp
      end
    end
    best || world_pt
  end

  # Is world_pt covered by solid face on the plane axis=at?
  def self.point_covered?(grp, base_t, axis, at, world_pt, tol)
    faces, = audit_collect(grp, base_t)
    faces.each do |rec|
      f = rec[:face]
      next unless f.valid?
      t = rec[:t]
      n = f.normal.transform(t)
      n.normalize!
      next unless coord_on(Geom::Point3d.new(n.x, n.y, n.z), axis).abs > 0.999
      fp = coord_on(f.vertices.first.position.transform(t), axis)
      next unless (fp - at).abs <= tol
      lp = world_pt.transform(t.inverse)
      cls = f.classify_point(lp)
      mask = Sketchup::Face::PointInside | Sketchup::Face::PointOnVertex | Sketchup::Face::PointOnEdge
      return true if (cls & mask) != 0
    end
    false
  end

  def self.orient_face!(face, t, desired_world_normal)
    n = face.normal.transform(t)
    n.normalize!
    face.reverse! if n.dot(desired_world_normal) < 0
  end

  def self.opening_params(p)
    axis = p['axis'].to_s
    raise "axis must be 'x' or 'y' for a wall opening" unless %w[x y].include?(axis)
    span_axis = axis == 'x' ? 'y' : 'x'
    span_key = "#{span_axis}_range"

    wf = p['wall_faces']
    raise "'wall_faces' must be [outer, inner] coordinates in #{@unit}" unless wf.is_a?(Array) && wf.length == 2
    raise "'#{span_key}' must be [min, max] in #{@unit}" unless p[span_key].is_a?(Array) && p[span_key].length == 2
    raise "'z_range' must be [min, max] in #{@unit}" unless p['z_range'].is_a?(Array) && p['z_range'].length == 2

    u = [len(p[span_key][0].to_f), len(p[span_key][1].to_f)].sort
    z = [len(p['z_range'][0].to_f), len(p['z_range'][1].to_f)].sort

    { axis: axis, span_axis: span_axis,
      outer: len(wf[0].to_f), inner: len(wf[1].to_f),
      u0: u[0], u1: u[1], z0: z[0], z1: z[1],
      from_floor: !!p['from_floor'] }
  end

  def self.handle_cut_opening(p)
    host, ht = require_group_deep(p['group'])
    o = opening_params(p)
    dry = !!p['dry_run']
    tol = metres(EDIT_PLANE_TOL_M)
    snap_tol = metres(EDIT_SNAP_TOL_M)

    centre_u = (o[:u0] + o[:u1]) / 2.0
    centre_z = (o[:z0] + o[:z1]) / 2.0

    # Refuse to cut where an opening already exists.
    [[o[:outer], 'outer'], [o[:inner], 'inner']].each do |at, which|
      c = wall_point(o[:axis], at, centre_u, centre_z)
      unless point_covered?(host, ht, o[:axis], at, c, tol)
        raise "Aborted, nothing changed: the #{which} wall face at #{o[:axis]} = #{out_len(at)} is already open " \
              "at the centre of this rectangle (#{out_len(centre_u)}, #{out_len(centre_z)}) — an opening is " \
              "already cut here. Use fill_opening first if you want to redo it."
      end
    end

    # A frame must sit in the wall. A depth range that misses the wall
    # thickness entirely is almost always a sign flip or the wrong face.
    if p['frame'] && p['frame']['depth_range'].is_a?(Array) && p['frame']['depth_range'].size == 2
      fd0, fd1 = p['frame']['depth_range'].map { |v| len(v.to_f) }.sort
      wlo, whi = [o[:outer], o[:inner]].sort
      if fd1 <= wlo + tol || fd0 >= whi - tol
        raise "Aborted, nothing changed: frame.depth_range #{out_len(fd0)}-#{out_len(fd1)} lies outside the " \
              "wall, which runs #{o[:axis]} = #{out_len(wlo)}-#{out_len(whi)}. Check the sign or which face you measured from."
      end
    end

    _f0, _e0, existing_vertices = audit_collect(host, ht)
    existing = existing_vertices.values

    with_edit(host, "MCP: cut_opening #{out_len(o[:u0])}-#{out_len(o[:u1])}", dry, true, ht) do
      inv = ht.inverse
      cut_faces = 0

      # 1. Cut the rectangle out of each wall face.
      [o[:outer], o[:inner]].each do |at|
        pts = [
          wall_point(o[:axis], at, o[:u0], o[:z0]), wall_point(o[:axis], at, o[:u1], o[:z0]),
          wall_point(o[:axis], at, o[:u1], o[:z1]), wall_point(o[:axis], at, o[:u0], o[:z1])
        ].map { |wp| snap_to_existing(wp, existing, snap_tol).transform(inv) }
        f = host.entities.add_face(pts)
        next unless f
        f.erase! if f.valid?
        cut_faces += 1
      end

      # 2. Reveals. Each points into the opening.
      reveals = []
      side_normal = o[:axis] == 'x' ? [Geom::Vector3d.new(0, 1, 0), Geom::Vector3d.new(0, -1, 0)]
                                    : [Geom::Vector3d.new(1, 0, 0), Geom::Vector3d.new(-1, 0, 0)]
      [[o[:u0], side_normal[0]], [o[:u1], side_normal[1]]].each do |u, want|
        pts = [
          wall_point(o[:axis], o[:outer], u, o[:z0]), wall_point(o[:axis], o[:inner], u, o[:z0]),
          wall_point(o[:axis], o[:inner], u, o[:z1]), wall_point(o[:axis], o[:outer], u, o[:z1])
        ].map { |wp| snap_to_existing(wp, existing, snap_tol).transform(inv) }
        f = host.entities.add_face(pts)
        next unless f
        orient_face!(f, ht, want)
        reveals << { kind: 'side', at: out_len(u), normal: vec3(want) }
      end

      # head, and a sill only when the opening does not start at the floor
      heads = [[o[:z1], Geom::Vector3d.new(0, 0, -1), 'head']]
      heads << [o[:z0], Geom::Vector3d.new(0, 0, 1), 'sill'] unless o[:from_floor]
      heads.each do |z, want, kind|
        pts = [
          wall_point(o[:axis], o[:outer], o[:u0], z), wall_point(o[:axis], o[:inner], o[:u0], z),
          wall_point(o[:axis], o[:inner], o[:u1], z), wall_point(o[:axis], o[:outer], o[:u1], z)
        ].map { |wp| snap_to_existing(wp, existing, snap_tol).transform(inv) }
        f = host.entities.add_face(pts)
        next unless f
        orient_face!(f, ht, want)
        reveals << { kind: kind, at: out_len(z), normal: vec3(want) }
      end

      # 3. A floor-level opening cuts through the wall's bottom face: the side
      #    reveals split it, so remove the piece inside the opening.
      removed_bottom = 0
      if o[:from_floor]
        faces_now, = audit_collect(host, ht)
        faces_now.each do |rec|
          f = rec[:face]
          next unless f.valid?
          n = f.normal.transform(rec[:t])
          n.normalize!
          next unless n.z.abs > 0.999
          c = face_centroid(f, rec[:t])
          next unless (c.z - o[:z0]).abs <= tol
          next unless coord_on(c, o[:span_axis]) > o[:u0] && coord_on(c, o[:span_axis]) < o[:u1]
          ca = coord_on(c, o[:axis])
          lo, hi = [o[:outer], o[:inner]].sort
          next unless ca > lo && ca < hi
          f.erase!
          removed_bottom += 1
        end
      end

      # 4. Optional frame, built in the collection that holds the wall (or a
      #    named group), inside this same undo step.
      frame_info = nil
      if p['frame']
        spec = p['frame']
        %w[depth_range side_low side_high head].each do |k|
          raise "frame.#{k} is required" if spec[k].nil?
        end
        if spec['parent']
          fp, fpt = require_group_deep(spec['parent'])
        else
          fp = host.parent.is_a?(Sketchup::ComponentDefinition) ? host.parent.instances.first : nil
          fpt = ht * host.transformation.inverse
        end
        raise 'Could not resolve where to put the frame; name it with frame.parent' unless fp
        frame_info = build_opening_frame(fp, fpt, o, spec)
      end

      { group: host.name, axis: o[:axis],
        wall_faces: [out_len(o[:outer]), out_len(o[:inner])],
        opening: { o[:span_axis] => [out_len(o[:u0]), out_len(o[:u1])],
                   'z' => [out_len(o[:z0]), out_len(o[:z1])] },
        from_floor: o[:from_floor],
        wall_faces_cut: cut_faces, reveal_faces: reveals,
        bottom_pieces_removed: removed_bottom,
        frame: frame_info,
        self_check: opening_self_check(host, ht, o, tol) }
    end
  end

  # An axis-aligned box from two world corners, built inside ents (whose
  # world transform is t), extruded upwards.
  def self.add_box_world(ents, t, wmin, wmax)
    inv = t.inverse
    base = [
      Geom::Point3d.new(wmin.x, wmin.y, wmin.z), Geom::Point3d.new(wmax.x, wmin.y, wmin.z),
      Geom::Point3d.new(wmax.x, wmax.y, wmin.z), Geom::Point3d.new(wmin.x, wmax.y, wmin.z)
    ].map { |q| q.transform(inv) }
    f = ents.add_face(base)
    return nil unless f
    n = f.normal.transform(t)
    n.normalize!
    height = wmax.z - wmin.z
    f.pushpull(n.z > 0 ? height : -height)
    f
  end

  # Frame around an opening: two full-height sides and a head between them.
  # No bottom member. Sizes are the member thicknesses.
  def self.build_opening_frame(parent, parent_t, o, spec)
    d0 = len(spec['depth_range'][0].to_f)
    d1 = len(spec['depth_range'][1].to_f)
    d0, d1 = d1, d0 if d0 > d1
    side_low  = len(spec['side_low'].to_f)
    side_high = len(spec['side_high'].to_f)
    head      = len(spec['head'].to_f)

    grp = parent.entities.add_group
    grp.name = spec['name'] || 'Opening frame'
    apply_layer(grp, spec['tag']) if spec['tag']
    gt = parent_t * grp.transformation

    lo_in  = o[:u0] + side_low   # inner edge of the low-side member
    hi_in  = o[:u1] - side_high  # inner edge of the high-side member
    head_z = o[:z1] - head

    # One U-shaped profile extruded through the frame depth, rather than three
    # boxes: touching boxes leave internal faces and the group never reads as
    # a solid (volume comes back negative).
    profile = [
      [o[:u0], o[:z0]], [lo_in, o[:z0]], [lo_in, head_z], [hi_in, head_z],
      [hi_in, o[:z0]], [o[:u1], o[:z0]], [o[:u1], o[:z1]], [o[:u0], o[:z1]]
    ].map { |u, z| wall_point(o[:axis], d0, u, z).transform(gt.inverse) }

    face = grp.entities.add_face(profile)
    raise 'Could not build the frame profile' unless face
    depth = d1 - d0
    n = face.normal.transform(gt)
    n.normalize!
    along = o[:axis] == 'x' ? n.x : n.y
    # pushpull runs along the face normal, and the profile sits at d0, so
    # extrude towards d1.
    face.pushpull(along > 0 ? depth : -depth)

    {
      name: grp.name,
      tag: spec['tag'],
      depth_range: [out_len(d0), out_len(d1)],
      clear_opening: [out_len(hi_in - lo_in), out_len(head_z - o[:z0])],
      volume: (grp.volume / (@inches_per_unit**3)).round(6),
      bounds: { min: out_point(grp.bounds.min.transform(parent_t)),
                max: out_point(grp.bounds.max.transform(parent_t)) }
    }
  end

  # The check that used to be scripted by hand: open at the centre of both
  # wall faces, still covered just outside each edge and above the head.
  def self.opening_self_check(host, ht, o, tol)
    probe = metres(0.02)
    centre_u = (o[:u0] + o[:u1]) / 2.0
    centre_z = (o[:z0] + o[:z1]) / 2.0
    results = {}
    failures = []

    [[o[:outer], 'outer'], [o[:inner], 'inner']].each do |at, which|
      c = wall_point(o[:axis], at, centre_u, centre_z)
      open_at_centre = !point_covered?(host, ht, o[:axis], at, c, tol)
      results["#{which}_centre_open"] = open_at_centre
      failures << "#{which} face is not open at the centre" unless open_at_centre

      checks = {
        'below_low_edge'  => wall_point(o[:axis], at, o[:u0] - probe, centre_z),
        'beyond_high_edge' => wall_point(o[:axis], at, o[:u1] + probe, centre_z),
        'above_head'      => wall_point(o[:axis], at, centre_u, o[:z1] + probe)
      }
      checks.each do |label, pt|
        covered = point_covered?(host, ht, o[:axis], at, pt, tol)
        results["#{which}_#{label}_covered"] = covered
        failures << "#{which} face is not covered #{label.tr('_', ' ')}" unless covered
      end
    end

    results['ok'] = failures.empty?
    results['failures'] = failures
    results
  end

  def self.handle_fill_opening(p)
    host, ht = require_group_deep(p['group'])
    o = opening_params(p)
    dry = !!p['dry_run']
    tol = metres(EDIT_PLANE_TOL_M)
    snap_tol = metres(EDIT_SNAP_TOL_M)

    centre_u = (o[:u0] + o[:u1]) / 2.0
    centre_z = (o[:z0] + o[:z1]) / 2.0
    already = [o[:outer], o[:inner]].all? { |at|
      point_covered?(host, ht, o[:axis], at, wall_point(o[:axis], at, centre_u, centre_z), tol)
    }
    raise "Aborted, nothing changed: both wall faces are already solid here — there is no opening to fill." if already

    _f0, _e0, existing_vertices = audit_collect(host, ht)
    existing = existing_vertices.values

    with_edit(host, "MCP: fill_opening #{out_len(o[:u0])}-#{out_len(o[:u1])}", dry, true, ht) do
      inv = ht.inverse
      lo_a, hi_a = [o[:outer], o[:inner]].sort

      # 1. Remove the reveals (anything strictly inside the opening volume).
      removed = 0
      faces_now, = audit_collect(host, ht)
      faces_now.each do |rec|
        f = rec[:face]
        next unless f.valid?
        c = face_centroid(f, rec[:t])
        next unless coord_on(c, o[:span_axis]) > o[:u0] - tol && coord_on(c, o[:span_axis]) < o[:u1] + tol
        next unless c.z > o[:z0] - tol && c.z < o[:z1] + tol
        ca = coord_on(c, o[:axis])
        next unless ca > lo_a - tol && ca < hi_a + tol
        # keep the two wall planes themselves; they are being refilled below
        next if (ca - o[:outer]).abs <= tol || (ca - o[:inner]).abs <= tol
        f.erase!
        removed += 1
      end

      # 2. Refill both wall planes, copying material and orientation from the
      #    coplanar neighbour, then drop the seam so each side is one face.
      filled = []
      [o[:outer], o[:inner]].each do |at|
        neighbour = nil
        faces_after, = audit_collect(host, ht)
        faces_after.each do |rec|
          f = rec[:face]
          next unless f.valid?
          n = f.normal.transform(rec[:t])
          n.normalize!
          next unless coord_on(Geom::Point3d.new(n.x, n.y, n.z), o[:axis]).abs > 0.999
          fp = coord_on(f.vertices.first.position.transform(rec[:t]), o[:axis])
          next unless (fp - at).abs <= tol
          neighbour = { face: f, t: rec[:t], normal: n }
          break
        end

        pts = [
          wall_point(o[:axis], at, o[:u0], o[:z0]), wall_point(o[:axis], at, o[:u1], o[:z0]),
          wall_point(o[:axis], at, o[:u1], o[:z1]), wall_point(o[:axis], at, o[:u0], o[:z1])
        ].map { |wp| snap_to_existing(wp, existing, snap_tol).transform(inv) }
        f = host.entities.add_face(pts)
        next unless f

        if neighbour
          f.material = neighbour[:face].material
          f.back_material = neighbour[:face].back_material
          orient_face!(f, ht, neighbour[:normal])
        end
        filled << out_len(at)
      end

      # 3. If the opening went to the floor, close the bottom back up too.
      if o[:from_floor]
        pts = [
          wall_point(o[:axis], lo_a, o[:u0], o[:z0]), wall_point(o[:axis], hi_a, o[:u0], o[:z0]),
          wall_point(o[:axis], hi_a, o[:u1], o[:z0]), wall_point(o[:axis], lo_a, o[:u1], o[:z0])
        ].map { |wp| snap_to_existing(wp, existing, snap_tol).transform(inv) }
        bf = host.entities.add_face(pts)
        orient_face!(bf, ht, Geom::Vector3d.new(0, 0, -1)) if bf
      end

      merged = merge_seams_in(host, ht)

      { group: host.name, reveal_faces_removed: removed, wall_faces_filled: filled,
        seam_edges_erased: merged }
    end
  end

  # Erase edges between coplanar faces of the same orientation, ignoring
  # material (a freshly filled face inherits its neighbour's anyway). Used by
  # fill_opening to leave one face per wall side rather than a visible patch.
  def self.merge_seams_in(grp, base_t)
    tol_planar = metres(EDIT_PLANAR_TOL_M)
    erased = 0
    _f, edges = audit_collect(grp, base_t)
    edges.each do |rec|
      e = rec[:edge]
      next unless e.valid?
      next unless e.faces.length == 2
      f1, f2 = e.faces
      n1 = f1.normal.transform(rec[:t])
      n1.normalize!
      n2 = f2.normal.transform(rec[:t])
      n2.normalize!
      next unless n1.dot(n2) > 0.9999
      a, b, c, d = f1.plane
      s = f2.vertices.first.position
      next if (a * s.x + b * s.y + c * s.z + d).abs > tol_planar
      e.erase!
      erased += 1
    end
    erased
  end

  def self.handle_merge_coplanar(p)
    grp = require_group(p['group'])
    dry = !!p['dry_run']
    ignore_back = !!p['ignore_back_material']
    tol_planar = metres(EDIT_PLANAR_TOL_M)

    _faces, edges = audit_collect(grp)
    candidates = []
    back_material_blocked = 0

    edges.each do |rec|
      e = rec[:edge]
      next unless e.faces.length == 2
      f1, f2 = e.faces
      n1 = f1.normal.transform(rec[:t])
      n1.normalize!
      n2 = f2.normal.transform(rec[:t])
      n2.normalize!
      next unless n1.dot(n2) > 0.9999 # same orientation, not two sides of a shell

      m1 = f1.material ? f1.material.name : nil
      m2 = f2.material ? f2.material.name : nil
      next unless m1 == m2

      a, b, c, d = f1.plane
      s = f2.vertices.first.position
      next if (a * s.x + b * s.y + c * s.z + d).abs > tol_planar

      b1 = f1.back_material ? f1.back_material.name : nil
      b2 = f2.back_material ? f2.back_material.name : nil
      if b1 != b2 && !ignore_back
        back_material_blocked += 1
        next
      end

      candidates << { edge: e, point: out_point(e.start.position.transform(rec[:t])),
                      back_materials: [b1, b2] }
    end

    if candidates.empty?
      if back_material_blocked > 0
        raise "#{back_material_blocked} coplanar seam(s) in '#{grp.name}' match on orientation and front " \
              "material but their two faces carry different back materials, so merging would discard one of " \
              "them. Pass ignore_back_material:true to merge anyway (the surviving face keeps its own back " \
              "material), or paint the back faces to match first."
      end
      raise "No mergeable coplanar seams found in '#{grp.name}'"
    end

    with_edit(grp, "MCP: merge_coplanar #{grp.name}", dry, true) do
      erased = 0
      candidates.each do |c|
        e = c[:edge]
        next unless e.valid?
        next unless e.faces.length == 2
        e.erase!
        erased += 1
      end
      { group: grp.name, seams_found: candidates.length, edges_erased: erased,
        skipped_differing_back_material: back_material_blocked,
        sample_points: candidates.first(20).map { |c| c[:point] } }
    end
  end

  def self.axis_name(ax)
    %w[x y z][ax]
  end

  # weld_vertices with cross_group:true. Vertices in different groups are
  # genuinely separate points and cannot be merged, but a pair a fraction of a
  # millimetre apart can be made exactly coincident. Moving a single corner
  # would bend its face (SketchUp then splits it), so the fix moves whole
  # planes: for each pair, the moving vertex's group shifts every vertex lying
  # on the same axis-aligned plane (within 0.1 mm) by the pair's offset along
  # that axis, going through the group's own transformation chain.
  # keep 'outer' (default): the vertex in the shallower group stays and the
  # deeper (nested) group moves; 'inner' does the opposite. Pairs in sibling
  # groups at the same depth are ambiguous: the first-found vertex stays
  # (reported as ambiguous_pairs). Each vertex takes part in one pair per call;
  # run again for clusters of three or more. Refuses conflicting offsets for the
  # same plane, and a group that would move a vertex another pair relies on.
  # The edit harness still aborts if a move would fold or split a face.
  def self.weld_cross_group(grp, tol, dry, keep, allow_splits)
    raise "keep must be 'outer' or 'inner'" unless %w[outer inner].include?(keep)
    buckets = collect_vertex_buckets(grp)
    items = []
    buckets.each_with_index do |b, bi|
      b[:vertices].each { |v| items << { bi: bi, v: v, w: v.position.transform(b[:t]) } }
    end

    by_bucket = {}
    items.each { |it| (by_bucket[it[:bi]] ||= []) << it }
    locked = {}
    pair_list = []
    samples = []
    pairs = 0
    ambiguous = 0
    # Greedy and order-dependent, so close pairs are visited in (i, j) order.
    close = []
    each_close_pair(items.map { |it| it[:w] }, tol) { |i, j, d| close << [i, j, d] }
    close.sort!
    close.each do |i, j, d|
      a = items[i]
      b = items[j]
      next if a[:bi] == b[:bi]
      next if d <= 0.0
      next if locked[a[:v].entityID] || locked[b[:v].entityID]
      da = buckets[a[:bi]][:label].count('/')
      db = buckets[b[:bi]][:label].count('/')
      if da == db
        ambiguous += 1
        mover, target = b, a
      else
        deeper, shallower = da > db ? [a, b] : [b, a]
        mover, target = keep == 'inner' ? [shallower, deeper] : [deeper, shallower]
      end
      locked[mover[:v].entityID] = true
      locked[target[:v].entityID] = true
      pair_list << { mover: mover, target: target, dw: target[:w] - mover[:w] }
      pairs += 1
      if samples.length < 20
        samples << { moved: out_point(mover[:w]), onto: out_point(target[:w]), distance: out_len(d),
                     moved_in: buckets[mover[:bi]][:label], kept_in: buckets[target[:bi]][:label] }
      end
    end
    raise "No near-coincident vertex pairs across different groups within #{out_len(tol)} #{@unit} in '#{grp.name}'" if pairs == 0

    # Expand each pair into a plane move: every vertex of the mover's group on
    # the same axis-aligned plane shifts by the pair's offset along that axis.
    plane_tol = metres(0.0001)
    vertex_shift = {} # vertex.entityID => { it:, shift: [x, y, z] (nil = no move on that axis) }
    pair_list.each do |pr|
      m = pr[:mover]
      3.times do |ax|
        sh = pr[:dw].to_a[ax]
        next if sh.abs < 1e-9
        by_bucket[m[:bi]].each do |it|
          next unless (it[:w].to_a[ax] - m[:w].to_a[ax]).abs <= plane_tol
          rec = (vertex_shift[it[:v].entityID] ||= { it: it, shift: [nil, nil, nil] })
          if rec[:shift][ax] && (rec[:shift][ax] - sh).abs > metres(0.00002)
            raise "Conflicting snaps for the plane at #{axis_name(ax)} = #{out_len(m[:w].to_a[ax])} in " \
                  "#{buckets[m[:bi]][:label]}: #{out_len(rec[:shift][ax])} vs #{out_len(sh)}. Nothing changed."
          end
          rec[:shift][ax] = sh
        end
      end
    end
    pair_list.each do |pr|
      if vertex_shift[pr[:target][:v].entityID]
        raise "A vertex kept in place by one pair (in #{buckets[pr[:target][:bi]][:label]}) would be moved by " \
              "another. Nothing changed; run the snap twice, or use keep to change which side moves."
      end
    end

    plan = {}
    vertex_shift.each_value do |rec|
      it = rec[:it]
      bk = buckets[it[:bi]]
      entry = (plan[it[:bi]] ||= { entities: bk[:entities], verts: [], vecs: [] })
      vec_world = Geom::Vector3d.new(*rec[:shift].map { |x| x || 0.0 })
      entry[:verts] << it[:v]
      entry[:vecs] << vec_world.transform(bk[:t].inverse)
    end
    moved_in = plan.keys.map { |bi| buckets[bi][:label] }

    with_edit(grp, "MCP: weld_vertices cross_group #{grp.name}", dry, allow_splits) do
      plan.values.each { |x| x[:entities].transform_by_vectors(x[:verts], x[:vecs]) }
      { group: grp.name, cross_group: true, keep: keep, tolerance: out_len(tol), pairs_snapped: pairs,
        vertices_moved: vertex_shift.length, groups_moved: moved_in, ambiguous_pairs: ambiguous,
        samples: samples }
    end
  end

  def self.handle_weld_vertices(p)
    grp = require_group(p['group'])
    tol = p.key?('tolerance') ? len(p['tolerance'].to_f) : metres(EDIT_COINCIDENT_TOL_M)
    dry = !!p['dry_run']
    if p['cross_group']
      return weld_cross_group(grp, tol, dry, (p['keep'] || 'outer').to_s, !!p['allow_splits'])
    end

    # Vertices can only be welded within one Entities collection — two
    # vertices in different groups are genuinely separate points.
    buckets = collect_vertex_buckets(grp)
    plan = []
    pairs = 0
    samples = []

    buckets.each do |b|
      positions = b[:vertices].map { |v| v.position.transform(b[:t]) }
      merged = {}
      sel_v = []
      sel_vec = []
      # Greedy and order-dependent, so close pairs are visited in (i, j) order.
      close = []
      each_close_pair(positions, tol) { |i, j, d| close << [i, j, d] }
      close.sort!
      close.each do |i, j, d|
        next if merged[i] || merged[j]
        next if d <= 0.0
        delta_world = positions[i] - positions[j]
        sel_v << b[:vertices][j]
        sel_vec << delta_world.transform(b[:t].inverse)
        merged[j] = true
        pairs += 1
        if samples.length < 20
          samples << { from: out_point(positions[j]), to: out_point(positions[i]), distance: out_len(d) }
        end
      end
      plan << { entities: b[:entities], verts: sel_v, vecs: sel_vec } unless sel_v.empty?
    end

    if pairs == 0
      # audit_geometry compares every vertex in the group against every other,
      # across nesting levels. Welding can only move a vertex onto another in
      # the same collection, so say so rather than claiming there is nothing.
      _f, _e, all_vertices = audit_collect(grp)
      cross = 0
      each_close_pair(all_vertices.values, tol) { |_i, _j, d| cross += 1 if d > 0.0 }
      if cross > 0
        raise "Found #{cross} near-coincident vertex pair(s) in '#{grp.name}' within #{out_len(tol)} #{@unit}, but none " \
              "of them sit in the same entities collection — they are in different nested groups/components, " \
              "which are genuinely separate points that welding cannot merge. They need the nested groups " \
              "reworked (or exploded) first. audit_geometry lists their locations."
      end
      raise "No vertex pairs closer than #{out_len(tol)} #{@unit} found in '#{grp.name}'"
    end

    with_edit(grp, "MCP: weld_vertices #{grp.name}", dry, !!p['allow_splits']) do
      plan.each { |x| x[:entities].transform_by_vectors(x[:verts], x[:vecs]) }
      { group: grp.name, tolerance: out_len(tol), pairs_welded: pairs, samples: samples }
    end
  end

  def self.handle_add_dimension(p)
    raise "'point_a' and 'point_b' are required" unless p['point_a'] && p['point_b']
    a = parse_point(p['point_a'])
    b = parse_point(p['point_b'])
    off = p['offset'] || [0, 0, 0]
    offset = Geom::Vector3d.new(len(off[0].to_f), len(off[1].to_f), len(off[2].to_f))
    tag = p['tag'] || 'Dimensions'

    model.start_operation('MCP: add_dimension', true)
    dim = nil
    begin
      dim = model.entities.add_dimension_linear(a, b, offset)
      apply_layer(dim, tag)
      model.commit_operation
    rescue => e
      begin
        model.abort_operation
      rescue
        nil
      end
      raise e
    end

    {
      id: dim.entityID,
      persistent_id: dim.respond_to?(:persistent_id) ? dim.persistent_id : nil,
      tag: tag,
      from: out_point(a), to: out_point(b),
      length: out_len(a.distance(b))
    }
  end

  def self.handle_save(_p)
    path = model.path
    raise 'This model has never been saved — use File > Save As in SketchUp first' if path.nil? || path.empty?
    saved = model.save
    { status: saved ? 'saved' : 'failed', path: path, modified: model.modified? }
  end

  def self.handle_save_copy(p)
    path = model.path
    raise 'This model has never been saved — use File > Save As in SketchUp first' if path.nil? || path.empty?
    suffix = p['suffix'].to_s
    suffix = Time.now.strftime('%Y%m%d-%H%M%S') if suffix.empty?
    # The copy goes next to the original; a suffix must not steer it elsewhere.
    unless suffix =~ /\A[A-Za-z0-9_-]+\z/
      raise "suffix may only contain letters, digits, '-' and '_' (got #{suffix.inspect})"
    end
    dest = File.join(File.dirname(path), "#{File.basename(path, '.skp')}_#{suffix}.skp")
    saved = model.save_copy(dest)
    { status: saved ? 'saved' : 'failed', path: dest, original: path, modified: model.modified? }
  end

  # --- Create geometry ---

  def self.handle_create_face(p)
    pts = parse_points(p['points'])
    raise "Need >= 3 points" if pts.length < 3
    model.start_operation('MCP: Face', true)
    face = entities.add_face(pts)
    apply_layer(face, p['layer'])
    apply_material(face, p['material'])
    model.commit_operation
    { id: face.entityID, type: 'Face', area: out_area(face.area), normal: vec3(face.normal) }
  end

  def self.handle_create_edge(p)
    s = parse_point(p['start'])
    e = parse_point(p['end'])
    model.start_operation('MCP: Edge', true)
    edge = entities.add_line(s, e)
    apply_layer(edge, p['layer'])
    model.commit_operation
    { id: edge.entityID, type: 'Edge', length: out_len(edge.length) }
  end

  def self.handle_create_group(p)
    model.start_operation('MCP: Group', true)
    group = entities.add_group
    group.name = p['name'] || ''
    apply_layer(group, p['layer'])
    model.commit_operation
    { id: group.entityID, name: group.name }
  end

  def self.handle_create_box(p)
    w = len(p['width'])
    d = len(p['depth'])
    h = len(p['height'])
    o = p['origin'] ? parse_point(p['origin']) : ORIGIN

    model.start_operation('MCP: Box', true)
    grp = entities.add_group
    ge = grp.entities
    pts = [
      o,
      Geom::Point3d.new(o.x + w, o.y,     o.z),
      Geom::Point3d.new(o.x + w, o.y + d, o.z),
      Geom::Point3d.new(o.x,     o.y + d, o.z)
    ]
    face = ge.add_face(pts)
    face.pushpull(-h)  # pushpull into +Z
    apply_layer(grp, p['layer'])
    apply_material(face, p['material']) if p['material']
    grp.name = p['name'] || "Box_#{p['width']}x#{p['depth']}x#{p['height']}"
    model.commit_operation
    { id: grp.entityID, name: grp.name, width: out_len(w), depth: out_len(d), height: out_len(h) }
  end

  def self.handle_create_circle(p)
    center   = p['center']   ? parse_point(p['center'])   : ORIGIN
    normal   = p['normal']   ? Geom::Vector3d.new(*p['normal'].map(&:to_f)) : Z_AXIS
    radius   = len(p['radius'])
    segments = (p['segments'] || 24).to_i
    raise "Radius must be positive" if radius <= 0
    raise "Segments must be >= 3"   if segments < 3

    model.start_operation('MCP: Circle', true)
    edges = entities.add_circle(center, normal, radius, segments)
    if p['layer']
      edges.each { |e| apply_layer(e, p['layer']) }
    end
    model.commit_operation
    { edge_count: edges.length, center: out_point(center), radius: out_len(radius), segments: segments }
  end

  def self.handle_create_arc(p)
    center     = p['center'] ? parse_point(p['center']) : ORIGIN
    xaxis      = p['xaxis']  ? Geom::Vector3d.new(*p['xaxis'].map(&:to_f))  : X_AXIS
    normal     = p['normal'] ? Geom::Vector3d.new(*p['normal'].map(&:to_f)) : Z_AXIS
    radius     = len(p['radius'])
    start_a    = (p['start_angle'] || 0).to_f
    end_a      = (p['end_angle']   || 180).to_f
    segments   = (p['segments']    || 12).to_i
    raise "Radius must be positive" if radius <= 0

    model.start_operation('MCP: Arc', true)
    edges = entities.add_arc(center, xaxis, normal, radius, start_a.degrees, end_a.degrees, segments)
    if p['layer']
      edges.each { |e| apply_layer(e, p['layer']) }
    end
    model.commit_operation
    { edge_count: edges.length, center: out_point(center), radius: out_len(radius) }
  end

  def self.handle_create_polygon(p)
    center    = p['center'] ? parse_point(p['center']) : ORIGIN
    normal    = p['normal'] ? Geom::Vector3d.new(*p['normal'].map(&:to_f)) : Z_AXIS
    radius    = len(p['radius'])
    num_sides = p['num_sides'].to_i
    inscribed = p['inscribed'].nil? ? true : p['inscribed']
    raise "Radius must be positive"     if radius <= 0
    raise "Need at least 3 sides"       if num_sides < 3

    model.start_operation('MCP: Polygon', true)
    edges = entities.add_ngon(center, normal, radius, num_sides, inscribed)
    # Also create the face
    pts = edges.map { |e| e.start.position }
    face = entities.add_face(pts) rescue nil
    apply_layer(face, p['layer']) if face && p['layer']
    apply_material(face, p['material']) if face && p['material']
    model.commit_operation
    {
      edge_count: edges.length,
      face_id:    face ? face.entityID : nil,
      center:     out_point(center),
      radius:     out_len(radius),
      num_sides:  num_sides
    }
  end

  def self.handle_push_pull(p)
    eid  = p['entity_id']
    dist = len(p['distance'])
    raise "entity_id required" unless eid

    face = find_entity_by_id(eid)
    raise "Entity #{eid} not found"        unless face
    raise "Entity #{eid} is not a Face"    unless face.is_a?(Sketchup::Face)

    model.start_operation('MCP: PushPull', true)
    face.pushpull(dist)
    model.commit_operation
    { status: 'ok', entity_id: eid, distance: out_len(dist) }
  end

  def self.handle_follow_me(p)
    fid  = p['face_id']
    pids = p['path_ids']
    raise "face_id required"               unless fid
    raise "path_ids array required"         unless pids.is_a?(Array)

    face = find_entity_by_id(fid)
    raise "Face #{fid} not found"           unless face
    raise "Entity #{fid} is not a Face"     unless face.is_a?(Sketchup::Face)

    path = pids.map do |id|
      e = find_entity_by_id(id)
      raise "Edge #{id} not found"          unless e
      raise "Entity #{id} is not an Edge"   unless e.is_a?(Sketchup::Edge)
      e
    end

    model.start_operation('MCP: FollowMe', true)
    face.followme(path)
    model.commit_operation
    { status: 'ok', face_id: fid, path_edges: path.length }
  end

  # --- Transformations ---

  def self.handle_move_entity(p)
    eid = p['entity_id']
    vec = p['vector']
    raise "entity_id required"           unless eid
    raise "vector [x,y,z] required"      unless vec.is_a?(Array) && vec.length == 3

    entity = find_entity_by_id(eid)
    raise "Entity #{eid} not found"      unless entity
    raise "Entity cannot be transformed" unless entity.respond_to?(:transform!)

    v = Geom::Vector3d.new(len(vec[0]), len(vec[1]), len(vec[2]))
    model.start_operation('MCP: Move', true)
    entity.transform!(Geom::Transformation.translation(v))
    model.commit_operation
    { status: 'moved', entity_id: eid, vector: [out_len(v.x), out_len(v.y), out_len(v.z)] }
  end

  def self.handle_rotate_entity(p)
    eid  = p['entity_id']
    raise "entity_id required" unless eid

    entity = find_entity_by_id(eid)
    raise "Entity #{eid} not found"      unless entity
    raise "Entity cannot be transformed" unless entity.respond_to?(:transform!)

    pt  = parse_point(p['axis_point'])
    vec = Geom::Vector3d.new(*p['axis_vector'].map(&:to_f))
    ang = p['angle'].to_f

    model.start_operation('MCP: Rotate', true)
    entity.transform!(Geom::Transformation.rotation(pt, vec, ang.degrees))
    model.commit_operation
    { status: 'rotated', entity_id: eid, angle: ang }
  end

  def self.handle_scale_entity(p)
    eid = p['entity_id']
    raise "entity_id required" unless eid

    entity = find_entity_by_id(eid)
    raise "Entity #{eid} not found"      unless entity
    raise "Entity cannot be transformed" unless entity.respond_to?(:transform!)

    origin = p['origin'] ? parse_point(p['origin']) : ORIGIN
    sc = p['scale']

    t = if sc.is_a?(Array) && sc.length == 3
          Geom::Transformation.scaling(origin, sc[0].to_f, sc[1].to_f, sc[2].to_f)
        else
          s = sc.to_f
          Geom::Transformation.scaling(origin, s, s, s)
        end

    model.start_operation('MCP: Scale', true)
    entity.transform!(t)
    model.commit_operation
    { status: 'scaled', entity_id: eid }
  end

  # --- Components ---

  def self.handle_create_component(p)
    name = p['name'] || 'MCP Component'
    model.start_operation('MCP: Component', true)
    defn = model.definitions.add(name)
    defn.description = p['description'] || ''
    pt = p['origin'] ? parse_point(p['origin']) : ORIGIN
    inst = entities.add_instance(defn, Geom::Transformation.new(pt))
    model.commit_operation
    { definition: defn.name, instance_id: inst.entityID }
  end

  def self.handle_place_component(p)
    name = p['name'] || ''
    defn = model.definitions.find { |d| d.name == name }
    raise "Component '#{name}' not found" unless defn
    pt = p['origin'] ? parse_point(p['origin']) : ORIGIN
    model.start_operation('MCP: Place', true)
    inst = entities.add_instance(defn, Geom::Transformation.new(pt))
    model.commit_operation
    { instance_id: inst.entityID, definition: defn.name }
  end

  # --- Execute Ruby ---

  def self.handle_execute_ruby(p)
    code = p['code'] || ''
    raise "No code provided" if code.strip.empty?

    output = []
    old_stdout = $stdout
    $stdout = StringIO.new

    begin
      result = eval(code, TOPLEVEL_BINDING)
      output = $stdout.string.split("\n")
    ensure
      $stdout = old_stdout
    end

    { result: result.inspect, output: output }
  rescue ScriptError, StandardError => e
    # ScriptError covers SyntaxError, which a bare rescue does not catch; left
    # uncaught it escapes every handler and the connection closes unanswered.
    { error: "#{e.class}: #{e.message}", backtrace: (e.backtrace || []).first(5) }
  end

  # --- Roof Truss (simple built-in) ---

  def self.handle_create_roof_truss(p)
    span_ft     = p['span'].to_f
    pitch_str   = p['pitch'] || '6:12'
    truss_type  = p['type']  || 'fink'
    count       = (p['count'] || 1).to_i
    spacing     = (p['spacing'] || 24).to_f
    overhang    = (p['overhang'] || 12).to_f
    lumber_str  = p['lumber_size'] || '2x4'
    origin      = p['origin'] ? parse_point_in(p['origin']) : ORIGIN
    layer_name  = p['layer']

    # Parse pitch
    parts = pitch_str.split(':')
    rise_per_12 = parts[0].to_f
    span_in = span_ft * 12.0
    half_span = span_in / 2.0
    peak_height = half_span * (rise_per_12 / 12.0)

    # Lumber actual dimensions
    lumber_dims = {
      '2x4' => [1.5, 3.5],
      '2x6' => [1.5, 5.5],
      '2x8' => [1.5, 7.5]
    }
    thick, depth = lumber_dims[lumber_str] || [1.5, 3.5]

    model.start_operation("MCP: Roof Truss", true)
    truss_ids = []

    count.times do |i|
      y_offset = i * spacing
      grp = entities.add_group
      grp.name = "Truss_#{i + 1}"
      apply_layer(grp, layer_name)
      ge = grp.entities

      ox = origin.x
      oy = origin.y + y_offset
      oz = origin.z

      # Key points
      left_bottom    = [ox - overhang, oy, oz]
      left_wall      = [ox, oy, oz]
      peak           = [ox + half_span, oy, oz + peak_height]
      right_wall     = [ox + span_in, oy, oz]
      right_bottom   = [ox + span_in + overhang, oy, oz]

      # Bottom chord (full span with overhangs)
      ge.add_line(parse_point_in(left_bottom), parse_point_in(right_bottom))

      # Left rafter
      ge.add_line(parse_point_in(left_bottom), parse_point_in(peak))

      # Right rafter
      ge.add_line(parse_point_in(right_bottom), parse_point_in(peak))

      if truss_type == 'king'
        # King post: single vertical at center
        ge.add_line(parse_point_in([ox + half_span, oy, oz]), parse_point_in(peak))
      else
        # Fink / W-truss pattern
        # Vertical at center
        center_bottom = [ox + half_span, oy, oz]
        ge.add_line(parse_point_in(center_bottom), parse_point_in(peak))

        # Quarter points on bottom chord
        q1_x = ox + half_span * 0.5
        q3_x = ox + half_span * 1.5
        q1_bottom = [q1_x, oy, oz]
        q3_bottom = [q3_x, oy, oz]

        # Points on rafters at quarter spans
        q1_rafter_z = oz + (half_span * 0.5) * (rise_per_12 / 12.0) * (half_span / (half_span + overhang))
        # Simpler: interpolate along left rafter
        t_left = 0.5  # halfway along left rafter
        q1_rafter = [q1_x, oy, oz + (q1_x - (ox - overhang)) * (peak_height / (half_span + overhang))]
        q3_rafter = [q3_x, oy, oz + ((ox + span_in + overhang) - q3_x) * (peak_height / (half_span + overhang))]

        # Verticals at quarter points
        ge.add_line(parse_point_in(q1_bottom), parse_point_in(q1_rafter))
        ge.add_line(parse_point_in(q3_bottom), parse_point_in(q3_rafter))

        # Diagonal webs (W pattern)
        ge.add_line(parse_point_in(q1_rafter), parse_point_in(center_bottom))
        ge.add_line(parse_point_in(q3_rafter), parse_point_in(center_bottom))
      end

      truss_ids << grp.entityID
    end

    model.commit_operation
    {
      status:    'created',
      count:     count,
      span_ft:   span_ft,
      pitch:     pitch_str,
      type:      truss_type,
      truss_ids: truss_ids
    }
  end

  # ---------------------------------------------------------------------------
  # Route table
  # ---------------------------------------------------------------------------

  ROUTES = {
    ['GET',  '/model/info']              => :handle_get_model_info,
    ['GET',  '/model/layers']            => :handle_list_layers,
    ['GET',  '/model/materials']         => :handle_list_materials,
    ['GET',  '/model/entities']          => :handle_list_entities,
    ['GET',  '/model/components']        => :handle_list_components,
    ['GET',  '/selection']               => :handle_get_selection,
    ['POST', '/selection/select']        => :handle_select,
    ['POST', '/view/zoom_to']            => :handle_zoom_to,
    ['POST', '/view/screenshot']         => :handle_screenshot,
    ['POST', '/wall_planes']             => :handle_list_wall_planes,
    ['POST', '/measure']                 => :handle_measure,
    ['GET',  '/audit_geometry']          => :handle_audit_geometry,
    ['GET',  '/changes_since']           => :handle_changes_since,
    ['POST', '/edit/move_plane']         => :handle_move_plane,
    ['POST', '/edit/remap_planes']       => :handle_remap_planes,
    ['POST', '/edit/cut_opening']        => :handle_cut_opening,
    ['POST', '/edit/fill_opening']       => :handle_fill_opening,
    ['POST', '/edit/merge_coplanar']     => :handle_merge_coplanar,
    ['POST', '/edit/weld_vertices']      => :handle_weld_vertices,
    ['POST', '/edit/add_dimension']      => :handle_add_dimension,
    ['POST', '/edit/save']               => :handle_save,
    ['POST', '/edit/save_copy']          => :handle_save_copy,
    ['POST', '/geometry/face']           => :handle_create_face,
    ['POST', '/geometry/edge']           => :handle_create_edge,
    ['POST', '/geometry/group']          => :handle_create_group,
    ['POST', '/geometry/box']            => :handle_create_box,
    ['POST', '/geometry/circle']         => :handle_create_circle,
    ['POST', '/geometry/arc']            => :handle_create_arc,
    ['POST', '/geometry/polygon']        => :handle_create_polygon,
    ['POST', '/geometry/pushpull']       => :handle_push_pull,
    ['POST', '/geometry/followme']       => :handle_follow_me,
    ['POST', '/transform/move']          => :handle_move_entity,
    ['POST', '/transform/rotate']        => :handle_rotate_entity,
    ['POST', '/transform/scale']         => :handle_scale_entity,
    ['POST', '/components/create']       => :handle_create_component,
    ['POST', '/components/place']        => :handle_place_component,
    ['POST', '/construction/roof_truss'] => :handle_create_roof_truss,
    ['POST', '/ruby/execute']            => :handle_execute_ruby,
  }.freeze

  # ---------------------------------------------------------------------------
  # HTTP handling
  # ---------------------------------------------------------------------------

  def self.build_response(data, status = 200)
    json = JSON.generate(data)
    text = { 200 => 'OK', 400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found',
             500 => 'Internal Server Error', 504 => 'Gateway Timeout' }[status] || 'Error'
    "HTTP/1.1 #{status} #{text}\r\n" \
    "Content-Type: application/json\r\n" \
    "Content-Length: #{json.bytesize}\r\n" \
    "X-SketchUp-MCP-Unit: #{@unit}\r\n" \
    "Connection: close\r\n" \
    "\r\n" \
    "#{json}"
  end

  def self.build_error(msg, status = 400)
    build_response({ error: msg }, status)
  end

  READ_DEADLINE_S  = 2                # whole request, not just the first byte
  MAX_HEADER_BYTES = 64 * 1024
  MAX_BODY_BYTES   = 32 * 1024 * 1024

  # Reads one request without ever blocking SketchUp's main thread for more
  # than READ_DEADLINE_S: a client that stalls part-way (or sends a
  # Content-Length it never delivers) used to freeze SketchUp in gets/read.
  # Returns [headers, body] as raw strings, or nil.
  def self.read_raw_request(client)
    deadline = Time.now + READ_DEADLINE_S
    buf = ''.b
    header_end = nil
    body_len = 0
    loop do
      if header_end.nil? && (i = buf.index("\r\n\r\n"))
        header_end = i
        body_len = buf[0, i] =~ /^content-length:\s*(\d+)/i ? $1.to_i : 0
        if body_len > MAX_BODY_BYTES
          log "read_http_request: body of #{body_len} bytes is over the limit; closing without a response"
          return nil
        end
      end
      if header_end.nil? && buf.bytesize > MAX_HEADER_BYTES
        log "read_http_request: headers over #{MAX_HEADER_BYTES} bytes; closing without a response"
        return nil
      end
      if header_end && buf.bytesize >= header_end + 4 + body_len
        return [buf[0, header_end], buf[header_end + 4, body_len]]
      end

      remaining = deadline - Time.now
      unless remaining > 0 && IO.select([client], nil, nil, remaining)
        log "read_http_request: no complete request within #{READ_DEADLINE_S}s; closing without a response"
        return nil
      end
      begin
        buf << client.read_nonblock(64 * 1024)
      rescue IO::WaitReadable
        next
      rescue EOFError
        log "read_http_request: client closed the connection before the request was complete"
        return nil
      end
    end
  end

  def self.read_http_request(client)
    raw = read_raw_request(client)
    return nil unless raw
    headers_raw, body = raw
    headers_raw.force_encoding('UTF-8') # read as raw bytes; see the note below

    lines = headers_raw.split("\r\n")
    request_line = lines[0] || ''
    method, full_path, _ = request_line.split(' ', 3)
    unless method && full_path
      log "read_http_request: could not parse a request line from: #{request_line.inspect}"
      return nil
    end

    # Parse path & query. Force UTF-8: Ruby's default external encoding for
    # socket reads is not guaranteed to be UTF-8 (varies by OS/locale), and
    # percent-decoded query values inherit whatever encoding the raw string
    # had — leaving group names with accents etc. mis-tagged, which later
    # breaks JSON.generate on any string built from them.
    path, query_string = full_path.split('?', 2)
    query = {}
    if query_string
      query_string.split('&').each do |pair|
        k, v = pair.split('=', 2)
        key = URI.decode_www_form_component(k).force_encoding('UTF-8')
        val = URI.decode_www_form_component(v || '').force_encoding('UTF-8')
        query[key] = val
      end
    end

    body = body.dup.force_encoding('UTF-8')

    headers = {}
    lines[1..-1].each do |l|
      k, v = l.split(':', 2)
      headers[k.strip.downcase] = v.strip if k && v
    end

    { method: method, path: path, query: query, body: body, headers: headers }
  rescue => e
    log "Read error: #{e.class}: #{e.message}"
    nil
  end

  # The server only listens on 127.0.0.1, but every web page open in a
  # browser on this machine can still send requests to it, and execute_ruby
  # makes that arbitrary code execution. Browsers always send Origin on such
  # requests, cannot add a custom header without a CORS preflight (which is
  # never answered), and a DNS-rebinding page arrives with a foreign Host.
  # The Python server is not a browser and passes all three checks.
  def self.refuse_reason(headers)
    return 'requests from web pages are not accepted' if headers['origin']
    allowed_hosts = ["127.0.0.1:#{PORT}", "localhost:#{PORT}"]
    unless allowed_hosts.include?(headers['host'].to_s.downcase)
      return "unexpected Host header #{headers['host'].inspect}"
    end
    unless headers['x-sketchup-mcp-unit']
      return 'missing X-SketchUp-MCP-Unit header (send m, cm, mm or inch)'
    end
    nil
  end

  # Runs on SketchUp's main thread (called from the UI timer), so handlers
  # can use the SketchUp API directly. No Ruby threads are used.
  def self.dispatch_request(req)
    method = req[:method]
    path   = req[:path]

    refusal = refuse_reason(req[:headers])
    if refusal
      log "Refused #{method} #{path}: #{refusal}"
      return build_error("Refused: #{refusal}", 403)
    end

    handler = ROUTES[[method, path]]
    unless handler
      return build_error("Unknown route: #{method} #{path}", 404)
    end

    # Unit for this request only; safe as module state because requests are
    # handled one at a time on the main thread.
    unit = req[:headers]['x-sketchup-mcp-unit']
    unless INCHES_PER[unit]
      return build_error("Unknown unit '#{unit}'. Use one of: #{INCHES_PER.keys.join(', ')}", 400)
    end
    @unit            = unit
    @inches_per_unit = INCHES_PER[unit]
    @world_t         = {}

    # Parse params
    params = {}
    if method == 'POST' && !req[:body].empty?
      begin
        params = JSON.parse(req[:body])
      rescue JSON::ParserError => e
        return build_error("Invalid JSON: #{e.message}", 400)
      end
    elsif method == 'GET'
      params = req[:query]
    end

    begin
      build_response(send(handler, params))
    rescue ScriptError, StandardError => e
      log "Handler error: #{e.class}: #{e.message}"
      log e.backtrace.first(3).join("\n") if e.backtrace
      # Leave the model in a clean state if a handler failed mid-operation
      model.abort_operation rescue nil
      build_error("#{e.class}: #{e.message}", 500)
    end
  end

  # ---------------------------------------------------------------------------
  # Main-thread poller (called by UI.start_timer)
  # ---------------------------------------------------------------------------

  def self.poll
    return unless @running && @server
    # Handle at most a few waiting connections per tick to keep the UI responsive
    5.times do
      begin
        client = @server.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR, Errno::EWOULDBLOCK, Errno::EAGAIN
        return
      end
      handle_client(client)
    end
  rescue IOError
    # server socket closed while stopping
  rescue => e
    log "Poll error: #{e.class}: #{e.message}"
  end

  def self.handle_client(client)
    req = read_http_request(client)
    if req
      client.write(dispatch_request(req))
    else
      log "handle_client: closing connection without a response (see read_http_request log line above for why)"
    end
  rescue => e
    log "Client error: #{e.class}: #{e.message}"
  ensure
    client.close rescue nil
  end

  # ---------------------------------------------------------------------------
  # Server lifecycle
  # ---------------------------------------------------------------------------

  def self.start_server
    if @server
      log "Server already running on port #{PORT}"
      return
    end

    begin
      @server  = TCPServer.new('127.0.0.1', PORT)
      @running = true

      # Poll for connections on the main SketchUp UI thread
      @timer_id = UI.start_timer(0.1, true) { SU_MCP.poll }

      log "Server started on http://127.0.0.1:#{PORT}"
      log "Log file: #{LOG_FILE}"

    rescue Errno::EADDRINUSE
      msg = "Port #{PORT} already in use. Close other SketchUp instances or check for conflicts."
      log "ERROR: #{msg}"
      UI.messagebox(msg) if defined?(UI)
      @server = nil
    rescue => e
      msg = "Failed to start: #{e.class} - #{e.message}"
      log "ERROR: #{msg}"
      UI.messagebox(msg) if defined?(UI)
      @server = nil
    end
  end

  def self.stop_server
    return unless @server
    @running = false
    UI.stop_timer(@timer_id) if @timer_id
    @timer_id = nil
    @server.close rescue nil
    @server = nil
    log "Server stopped"
  end

  def self.restart_server
    stop_server
    start_server
  end

  def self.server_running?
    !@server.nil? && @running
  end

  # ---------------------------------------------------------------------------
  # SketchUp menu registration & auto-start
  # ---------------------------------------------------------------------------

  unless file_loaded?(__FILE__)
    log "Loading SketchUp MCP Plugin v2.0"
    log "Ruby #{RUBY_VERSION} | SketchUp #{Sketchup.version}"

    menu = UI.menu('Plugins').add_submenu('MCP Server')
    menu.add_item('Start Server')   { SU_MCP.start_server }
    menu.add_item('Stop Server')    { SU_MCP.stop_server }
    menu.add_item('Restart Server') { SU_MCP.restart_server }
    menu.add_item('Server Status')  {
      if SU_MCP.server_running?
        UI.messagebox("MCP Server is RUNNING on port #{SU_MCP::PORT}")
      else
        UI.messagebox("MCP Server is STOPPED")
      end
    }

    # Auto-start
    SU_MCP.start_server

    # changes_since: attach to whatever model is already open, and watch
    # for the user switching files.
    begin
      @session_id = "#{Time.now.to_i}-#{rand(1_000_000)}"
      @app_observer = ChangeAppObserver.new
      Sketchup.add_observer(@app_observer)
      attach_change_observer(Sketchup.active_model)
    rescue => e
      SU_MCP.log "Failed to set up change observer: #{e.class}: #{e.message}"
    end

    file_loaded(__FILE__)
    log "Plugin loaded OK"
  end
end
