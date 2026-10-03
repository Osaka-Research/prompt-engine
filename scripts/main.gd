extends Node3D

# Empty scene + prompt box: types a command, sends it to a local Termux
# server (server/prompt_server.py) which shells out to the already-logged-in
# `claude` CLI for a structured JSON action, and this applies it live --
# spawn a primitive, or attach a behavior to something already spawned.

const SERVER_URL := "http://127.0.0.1:8420/prompt"

@onready var http: HTTPRequest = $HTTPRequest
@onready var prompt_box: LineEdit = $UI/PromptRow/PromptBox
@onready var submit_btn: Button = $UI/PromptRow/SubmitButton
@onready var status_label: Label = $UI/StatusLabel
@onready var objects_root: Node3D = $ObjectsRoot
@onready var camera_rig: Node3D = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var ground: Node3D = $Ground
@onready var move_controls: GridContainer = $UI/MoveControls
@onready var drive_controls: GridContainer = $UI/DriveControls
@onready var generated_controls: GridContainer = $UI/GeneratedControls
@onready var move_forward_btn: Button = $UI/MoveControls/MoveForward
@onready var move_back_btn: Button = $UI/MoveControls/MoveBack
@onready var move_left_btn: Button = $UI/MoveControls/MoveLeft
@onready var move_right_btn: Button = $UI/MoveControls/MoveRight
@onready var object_list: ItemList = $UI/ObjectPanel/ObjectList

var objects: Dictionary = {}  # name (String) -> Node3D; scriptless until a behavior command hot-loads generated code onto it
var last_object_name: String = ""
var selected_object_names: Array[String] = []  # multi-select from the object list; >1 means "describe a relation between these"
var spawn_count := 0

# ── Free-roam camera: yaw on the rig (movement stays level regardless of
# pitch), pitch on the Camera3D child only, clamped so it can't flip over. ──
const LOOK_SPEED := 0.006
const MOVE_SPEED := 4.0
const PITCH_LIMIT := deg_to_rad(80.0)

var yaw := 0.0
var pitch := deg_to_rad(-10.0)
var dragging := false
var drag_pointer_id := -1
var move_dir := Vector3.ZERO  # from held touch buttons; keyboard WASD is read directly each frame

# Whatever object last got player controls generated for it (see
# _build_controls) -- the camera follows/orbits this instead of free-roaming
# while it's set, so driving something is actually watchable. Cleared back
# to free-roam whenever controls are cleared (a new thing gets driven, or
# a non-controlled behavior replaces this one).
var driven_object: Node3D = null
const FOLLOW_DISTANCE := 6.0
const FOLLOW_HEIGHT := 3.0

func _ready() -> void:
	submit_btn.pressed.connect(_on_submit)
	prompt_box.text_submitted.connect(func(_text): _on_submit())
	http.request_completed.connect(_on_response)
	prompt_box.grab_focus()

	# Manual toggle multi-select (item_clicked fires on every tap regardless
	# of ctrl/shift, which don't exist on touch) -- tap adds/removes that
	# item from the selection instead of ItemList's native single-tap-clears
	# behavior. One selected = implicit target for the next prompt (same
	# slot "last spawned" already used). Two or more = the next prompt can
	# describe a relation between them (see _apply_behavior's refs wiring).
	object_list.item_clicked.connect(func(index: int, _pos: Vector2, _btn: int):
		if object_list.is_selected(index):
			object_list.deselect(index)
		else:
			object_list.select(index, false)
		_update_selection_from_list()
	)

	_bind_hold(move_forward_btn, Vector3(0, 0, -1))
	_bind_hold(move_back_btn, Vector3(0, 0, 1))
	_bind_hold(move_left_btn, Vector3(-1, 0, 0))
	_bind_hold(move_right_btn, Vector3(1, 0, 0))

func _bind_hold(btn: Button, dir: Vector3) -> void:
	btn.button_down.connect(func(): move_dir += dir)
	btn.button_up.connect(func(): move_dir -= dir)

# Touch drag and mouse-drag (right button, so left click still works on UI)
# both rotate the camera. Ignores drags that started on a Control (the UI
# buttons/prompt box already consume those before they reach _input).
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			dragging = true
			drag_pointer_id = event.index
		elif event.index == drag_pointer_id:
			dragging = false
	elif event is InputEventScreenDrag and dragging and event.index == drag_pointer_id:
		_apply_look_delta(event.relative)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		dragging = event.pressed
	elif event is InputEventMouseMotion and dragging:
		_apply_look_delta(event.relative)

func _apply_look_delta(rel: Vector2) -> void:
	yaw -= rel.x * LOOK_SPEED
	pitch = clampf(pitch - rel.y * LOOK_SPEED, -PITCH_LIMIT, PITCH_LIMIT)
	camera_rig.rotation.y = yaw
	camera.rotation.x = pitch

func _process(delta: float) -> void:
	if driven_object != null and is_instance_valid(driven_object):
		# Orbit-follow: position tracks the driven object, offset backward
		# along wherever the rig is currently facing -- dragging to look
		# around it also orbits the camera around it, instead of a rigid
		# fixed chase angle.
		var yaw_forward: Vector3 = -camera_rig.global_transform.basis.z
		var desired_pos: Vector3 = driven_object.global_position - yaw_forward * FOLLOW_DISTANCE + Vector3(0, FOLLOW_HEIGHT, 0)
		camera_rig.global_position = camera_rig.global_position.lerp(desired_pos, clampf(delta * 6.0, 0.0, 1.0))
	else:
		# Direct key polling, not the ui_* actions -- those are bound to
		# arrow keys and double as UI focus/cursor navigation, which fights
		# with the prompt box (it keeps input focus between submits).
		var input_dir := move_dir
		if Input.is_key_pressed(KEY_A): input_dir.x -= 1.0
		if Input.is_key_pressed(KEY_D): input_dir.x += 1.0
		if Input.is_key_pressed(KEY_W): input_dir.z -= 1.0
		if Input.is_key_pressed(KEY_S): input_dir.z += 1.0
		if input_dir.length_squared() > 1.0:
			input_dir = input_dir.normalized()
		if input_dir != Vector3.ZERO:
			var basis := camera_rig.global_transform.basis
			var world_dir := (basis.x * input_dir.x + basis.z * input_dir.z)
			world_dir.y = 0.0
			if world_dir.length_squared() > 0.0:
				camera_rig.global_position += world_dir.normalized() * MOVE_SPEED * delta

	# Re-center the ground plane under the camera every frame instead of
	# using one large-but-finite mesh -- a fixed-size plane always has an
	# edge somewhere; this one never does, however far you roam.
	ground.position.x = camera_rig.position.x
	ground.position.z = camera_rig.position.z

# Where the camera is currently looking, projected onto the y=0 ground --
# spawned objects land there instead of a random spot. Falls back to a fixed
# distance in front when looking up/away from the ground (no intersection).
func _look_at_ground() -> Vector3:
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	if dir.y < -0.01:
		var t := -from.y / dir.y
		if t > 0.5 and t < 60.0:
			return Vector3(from.x + dir.x * t, 0.0, from.z + dir.z * t)
	return from + dir * 6.0

var last_submitted_text := ""

func _on_submit() -> void:
	var text := prompt_box.text.strip_edges()
	if text == "":
		return
	last_submitted_text = text
	status_label.text = "Thinking..."
	submit_btn.disabled = true
	var body := JSON.stringify({"prompt": text, "known_objects": objects.keys(), "selected_objects": selected_object_names})
	var err := http.request(SERVER_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		status_label.text = "Couldn't reach the prompt server (is prompt_server.py running?)"
		submit_btn.disabled = false
		return
	prompt_box.text = ""

func _on_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	submit_btn.disabled = false
	prompt_box.grab_focus()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		status_label.text = "Server error (code %d)" % response_code
		return
	var json := JSON.new()
	var parse_err := json.parse(body.get_string_from_utf8())
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		status_label.text = "Bad response from server"
		push_warning("JSON parse failed (err %s): %s" % [parse_err, body.get_string_from_utf8()])
		return
	_apply_action(json.data)

func _apply_action(action: Dictionary) -> void:
	match action.get("action", "unknown"):
		"spawn":
			_spawn_object(action)
		"behavior":
			_apply_behavior(action, last_submitted_text, selected_object_names)
		"ui":
			_apply_ui_action(action)
		"detail":
			_apply_detail(action, last_submitted_text, selected_object_names)
		"weapon":
			_apply_weapon(action, last_submitted_text, selected_object_names)
		_:
			var err: String = action.get("error", "")
			status_label.text = "Didn't understand that." if err == "" else "Error: " + err

# Adds ONE fire button for the target object -- additive to whatever's
# already in generated_controls (unlike _build_controls for driving, which
# replaces the whole panel), so attaching a weapon doesn't wipe out
# existing driving controls for the same or another object. Known limit:
# if driving controls get regenerated later (a fresh "let me drive it"),
# THAT still clears the whole panel including this button -- no per-target
# control zones yet, just one shared panel.
func _apply_weapon(action: Dictionary, prompt_text: String, selected: Array[String]) -> void:
	var target_name: String = action.get("target", "")
	var target: Node3D = _resolve_target(target_name, prompt_text, selected)
	if target == null:
		status_label.text = "Nothing to attach a weapon to yet."
		return

	var label: String = action.get("label", "FIRE")
	var btn := Button.new()
	btn.text = label
	_apply_control_button_scale(btn)
	btn.modulate = Color(1.0, 0.55, 0.55, 0.85)
	btn.pressed.connect(func(): _fire_projectile(target, action))
	generated_controls.add_child(btn)
	status_label.text = "%s armed" % target.name

# Reuses _build_shape (same primitive vocabulary as spawn/detail) and the
# same RigidBody3D + kinematic-freeze pattern as a driven object, so a shot
# still physically collides with and pushes whatever dynamic body it hits
# instead of passing through it. How it MOVES is LLM-generated per weapon
# (spec.projectile_script, same rules/hot-load mechanism as a 'behavior'
# script) -- straight line, arc, whatever "attach a rocket launcher" or
# "make it move in a spiral" actually asked for, not hardcoded to one
# shape of motion. scripts/projectile.gd is only a fallback for when
# generation is missing or fails to compile.
func _fire_projectile(target: Node3D, spec: Dictionary) -> void:
	if not is_instance_valid(target):
		return

	var built := _build_shape(spec.get("projectile_shape", "sphere"))
	var mesh: Mesh = built["mesh"]
	var collision_shape: Shape3D = built["collision_shape"]

	var size := Vector3(0.15, 0.15, 0.15)
	var size_arr: Array = spec.get("projectile_size", [])
	if size_arr.size() == 3:
		size = Vector3(
			clampf(float(size_arr[0]), 0.03, 2.0),
			clampf(float(size_arr[1]), 0.03, 2.0),
			clampf(float(size_arr[2]), 0.03, 2.0),
		)

	var offset := Vector3(0, 0.3, -1.0)
	var offset_arr: Array = spec.get("projectile_offset", [])
	if offset_arr.size() == 3:
		offset = Vector3(offset_arr[0], offset_arr[1], offset_arr[2])

	var proj := RigidBody3D.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	var mat := _make_material(spec.get("projectile_color", "yellow"))
	mesh_instance.material_override = mat
	mesh_instance.scale = size
	proj.add_child(mesh_instance)

	var collider := CollisionShape3D.new()
	collider.shape = collision_shape
	collider.scale = size
	proj.add_child(collider)
	proj.mass = 0.3

	objects_root.add_child(proj)
	var world_offset: Vector3 = target.global_transform.basis * offset
	# Orient (not just position) to the shooter's current facing -- the
	# generated script reads its OWN -transform.basis.z as the fire
	# direction each frame, same self-only convention as behavior scripts,
	# instead of main.gd injecting an external velocity.
	proj.global_transform = Transform3D(target.global_transform.basis, target.global_position + world_offset)
	proj.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	proj.freeze = true

	var source: String = spec.get("projectile_script", "")
	var loaded := false
	if source.strip_edges() != "":
		var script := GDScript.new()
		script.source_code = source
		if script.reload() == OK:
			proj.set_script(script)
			proj.set_process(true)
			proj.set_physics_process(true)
			loaded = true
		else:
			push_warning("bad generated projectile script (falling back to straight line):\n" + source)
	if not loaded:
		proj.set_script(load("res://scripts/projectile.gd"))
		proj.velocity = -proj.global_transform.basis.z * 15.0
		proj.life = 3.0

# Adds small decorative sub-meshes to an already-spawned object ("make the
# car more detailed") -- each part is just another primitive, offset from
# the object's center, parented under it so it moves/rotates/scales with
# the parent automatically. No new collision shapes: these are visual
# only, approximated well enough by the parent's existing collider.
func _apply_detail(action: Dictionary, prompt_text: String, selected: Array[String]) -> void:
	var target_name: String = action.get("target", "")
	var target: Node3D = _resolve_target(target_name, prompt_text, selected)
	if target == null:
		status_label.text = "Nothing to add detail to yet."
		return

	var parts: Array = action.get("parts", [])
	if parts.is_empty():
		status_label.text = "No detail parts generated for that."
		return

	# Plain decoration (wheels, windows, lights) parents parts directly on
	# `target` same as before. A named sub-object ("add a man on top of
	# the car") instead becomes its own real RigidBody3D -- registered in
	# `objects` so it's independently selectable/addressable (can get its
	# own weapon/behavior later, e.g. "give the man a gun") -- parented
	# under `target` so it physically rides along automatically, with a
	# rough capsule collider of its own since it's now a real object, not
	# just visual filler.
	var parts_parent: Node3D = target
	var sub_name: String = action.get("name", "")
	if sub_name != "" and not objects.has(sub_name):
		var sub_size := Vector3(0.4, 1.0, 0.4)
		var sub_size_arr: Array = action.get("size", [])
		if sub_size_arr.size() == 3:
			sub_size = Vector3(
				clampf(float(sub_size_arr[0]), 0.1, 4.0),
				clampf(float(sub_size_arr[1]), 0.1, 4.0),
				clampf(float(sub_size_arr[2]), 0.1, 4.0),
			)
		var sub_offset := Vector3(0, 1.0, 0)
		var sub_offset_arr: Array = action.get("offset", [])
		if sub_offset_arr.size() == 3:
			sub_offset = Vector3(float(sub_offset_arr[0]), float(sub_offset_arr[1]), float(sub_offset_arr[2]))

		var sub := RigidBody3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = maxf(sub_size.x, sub_size.z) * 0.5
		cap.height = sub_size.y
		var collider := CollisionShape3D.new()
		collider.shape = cap
		sub.add_child(collider)
		sub.mass = 5.0
		# Rides along with the parent by default (kinematic = no gravity
		# fighting the parent's transform); a later behavior/weapon can
		# still target it and unfreeze it exactly like any other object.
		sub.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		sub.freeze = true

		target.add_child(sub)
		sub.name = sub_name
		sub.position = sub_offset

		objects[sub_name] = sub
		last_object_name = sub_name
		_refresh_object_list()

		parts_parent = sub

	for part in parts:
		if typeof(part) != TYPE_DICTIONARY:
			continue
		var shape: String = part.get("shape", "box")
		var color_name: String = part.get("color", "black")
		var built := _build_shape(shape)
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = built["mesh"]
		var mat := _make_material(color_name)
		mesh_instance.material_override = mat

		var size := Vector3(0.3, 0.3, 0.3)
		var size_arr: Array = part.get("size", [])
		if size_arr.size() == 3:
			size = Vector3(
				clampf(float(size_arr[0]), 0.05, 4.0),
				clampf(float(size_arr[1]), 0.05, 4.0),
				clampf(float(size_arr[2]), 0.05, 4.0),
			)
		mesh_instance.scale = size

		var offset := Vector3.ZERO
		var offset_arr: Array = part.get("offset", [])
		if offset_arr.size() == 3:
			offset = Vector3(float(offset_arr[0]), float(offset_arr[1]), float(offset_arr[2]))
		mesh_instance.position = offset

		parts_parent.add_child(mesh_instance)

	if sub_name != "" and parts_parent != target:
		status_label.text = "%s added to %s" % [sub_name, target.name]
	else:
		status_label.text = "%s got more detailed (+%d parts)" % [target.name, parts.size()]

# Adjusts the app's own interface rather than the 3D scene -- currently
# just the size of the generated driving/control buttons. Rescales
# whatever's on screen right now AND remembers the scale for buttons
# generated later (see _build_controls), so it doesn't reset next time you
# drive something new.
var controls_scale := 1.0

func _apply_ui_action(action: Dictionary) -> void:
	var ui_target: String = action.get("ui_target", "")
	var scale_factor: float = clampf(float(action.get("scale", 1.0)), 0.4, 3.0)
	if ui_target != "controls":
		status_label.text = "Nothing to adjust for that yet."
		return
	controls_scale = scale_factor
	for btn in generated_controls.get_children():
		_apply_control_button_scale(btn)
	status_label.text = "Controls resized"

# Mesh and matching collision shape at the same 1-unit baseline (scaled
# together by callers), shared by both spawning a whole new object and
# adding a decorative "detail" part to an existing one -- same primitive
# vocabulary either way.
func _build_shape(shape: String) -> Dictionary:
	var mesh: Mesh
	var collision_shape: Shape3D
	match shape:
		"box":
			mesh = BoxMesh.new()
			var s := BoxShape3D.new()
			s.size = Vector3.ONE
			collision_shape = s
		"cone":
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.0
			cyl.bottom_radius = 0.5
			cyl.height = 1.0
			mesh = cyl
			var s := CylinderShape3D.new()
			s.radius = 0.5
			s.height = 1.0
			collision_shape = s
		"cylinder":
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.5
			cyl.bottom_radius = 0.5
			cyl.height = 1.0
			mesh = cyl
			var s := CylinderShape3D.new()
			s.radius = 0.5
			s.height = 1.0
			collision_shape = s
		"capsule":
			var cap := CapsuleMesh.new()
			cap.radius = 0.25
			cap.height = 1.0
			mesh = cap
			var s := CapsuleShape3D.new()
			s.radius = 0.25
			s.height = 1.0
			collision_shape = s
		_:
			mesh = SphereMesh.new()
			var s := SphereShape3D.new()
			s.radius = 0.5
			collision_shape = s
	return {"mesh": mesh, "collision_shape": collision_shape}

func _spawn_object(action: Dictionary) -> void:
	var shape: String = action.get("shape", "sphere")
	var color_name: String = action.get("color", "white")
	var obj_name: String = action.get("object", "thing")

	var built := _build_shape(shape)
	var mesh: Mesh = built["mesh"]
	var collision_shape: Shape3D = built["collision_shape"]

	var mat := _make_material(color_name)

	var size := Vector3.ONE
	var size_arr: Array = action.get("size", [])
	if size_arr.size() == 3:
		size = Vector3(
			clampf(float(size_arr[0]), 0.2, 8.0),
			clampf(float(size_arr[1]), 0.2, 8.0),
			clampf(float(size_arr[2]), 0.2, 8.0),
		)

	# Every spawned object is a real RigidBody3D -- gravity, mass, and bounce
	# by default, so an apple actually rests on the ground and bounces off
	# things instead of being a ghost. _apply_behavior() below freezes it
	# into kinematic (script-driven, still solid, unaffected by gravity)
	# only once something gives it a movement behavior like "drive".
	var root := RigidBody3D.new()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = mat
	mesh_instance.scale = size
	root.add_child(mesh_instance)

	var collider := CollisionShape3D.new()
	collider.shape = collision_shape
	collider.scale = size
	root.add_child(collider)

	# Rough mass from volume -- bigger things push smaller things around
	# convincingly instead of everything weighing the same regardless of size.
	var volume: float = size.x * size.y * size.z
	root.mass = clampf(volume * 2.0, 0.2, 60.0)

	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = 0.45
	phys_mat.friction = 0.6
	root.physics_material_override = phys_mat

	spawn_count += 1
	var unique_name: String = obj_name if not objects.has(obj_name) else "%s_%d" % [obj_name, spawn_count]
	root.name = unique_name
	var ground_point := _look_at_ground()
	root.position = ground_point + Vector3(0, size.y * 0.5 + 0.05, 0)

	objects_root.add_child(root)
	objects[unique_name] = root
	last_object_name = unique_name
	_refresh_object_list()
	status_label.text = "Added " + unique_name

# Rebuilds the left-side list from scratch and re-highlights whichever
# object is currently the implicit target, so the highlight always matches
# what a bare "it"/"that" in the next prompt would actually resolve to.
func _refresh_object_list() -> void:
	object_list.clear()
	for obj_name in objects.keys():
		object_list.add_item(obj_name)
	var idx := 0
	for i in object_list.item_count:
		if object_list.get_item_text(i) == last_object_name:
			idx = i
			break
	if object_list.item_count > 0:
		object_list.select(idx)
	# Spawning shifts focus to the new thing -- drop any stale multi-select
	# from before it existed rather than silently including it in the next
	# relation prompt. (Built with explicit .append(), not a ternary array
	# literal -- `[x] if c else []` is untyped Array and fails to assign
	# into this Array[String] var at runtime.)
	selected_object_names.clear()
	if object_list.item_count > 0:
		selected_object_names.append(last_object_name)
	_refresh_highlights()

# Keeps selected_object_names in sync with whatever's actually highlighted
# in the list (single tap = one implicit target, same as before; 2+ = the
# next prompt can describe a relation between them).
func _update_selection_from_list() -> void:
	var names: Array[String] = []
	for idx in object_list.get_selected_items():
		names.append(object_list.get_item_text(idx))
	selected_object_names = names
	if names.size() == 1:
		last_object_name = names[0]
		status_label.text = "Targeting " + names[0]
	elif names.size() > 1:
		status_label.text = "Targeting relation: " + ", ".join(names)
	else:
		status_label.text = "Nothing selected"
	_refresh_highlights()

const HIGHLIGHT_EMISSION := Color(1.0, 0.95, 0.3)
const HIGHLIGHT_ENERGY := 0.8

# So it's visually obvious in the actual 3D scene which object(s) a prompt
# is about to affect, not just which row is highlighted in the side list --
# glows every currently-selected object, un-glows everything else. Full
# clear-and-reapply each time rather than tracking a diff, since the object
# count here is small and this is simpler to get right.
func _refresh_highlights() -> void:
	for obj_name in objects.keys():
		_set_object_highlight(objects[obj_name], false)
	for obj_name in selected_object_names:
		if objects.has(obj_name):
			_set_object_highlight(objects[obj_name], true)

func _set_object_highlight(obj: Node3D, on: bool) -> void:
	for child in obj.get_children():
		if child is MeshInstance3D:
			var mat: Material = (child as MeshInstance3D).material_override
			if mat is StandardMaterial3D:
				mat.emission_enabled = on
				if on:
					mat.emission = HIGHLIGHT_EMISSION
					mat.emission_energy_multiplier = HIGHLIGHT_ENERGY

# Target resolution, in priority order:
# 1. Model's guess, if it's one of the objects the user explicitly
#    multi-selected -- the selection itself (not prompt wording) is the
#    disambiguating signal for a relation prompt like "make it chase
#    the other one".
# 2. Model's guess, if that object's name was actually typed in the
#    prompt -- otherwise ("make it fly") it's just a guess, and an
#    explicit tap in the object list is more reliable than that guess
#    (same class of issue as the earlier keyboard-vs-generated-controls
#    prompt-following problem -- the model doesn't reliably defer to
#    context on its own, so this is enforced client-side instead).
# 3. Whatever's currently the implicit target (last tapped/spawned).
# 4. The model's guess anyway, as a last resort.
func _resolve_target(target_name: String, prompt_text: String, selected: Array[String]) -> Node3D:
	var target: Node3D = null
	if target_name != "" and objects.has(target_name) and selected.has(target_name):
		target = objects.get(target_name)
	elif target_name != "" and objects.has(target_name) and prompt_text.to_lower().contains(target_name.to_lower()):
		target = objects.get(target_name)
	else:
		target = objects.get(last_object_name)
	if target == null:
		target = objects.get(target_name)
	return target

func _apply_behavior(action: Dictionary, prompt_text: String, selected: Array[String]) -> void:
	var target_name: String = action.get("target", "")
	var source: String = action.get("script", "")
	var target: Node3D = _resolve_target(target_name, prompt_text, selected)
	if target == null:
		status_label.text = "Nothing to apply that to yet."
		return
	if source.strip_edges() == "":
		status_label.text = "No behavior generated for that."
		return

	# Hot-load the generated behavior onto the already-running node -- no
	# rebuild, no scene reload. A script that fails to compile just leaves
	# the object as it was instead of crashing the game.
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		status_label.text = "Generated behavior had an error -- left unchanged."
		push_warning("bad generated script for %s (err %d):\n%s" % [target.name, err, source])
		return
	target.set_script(script)
	# set_script() on a node already in the tree doesn't retroactively
	# register it for _process/_physics_process -- that's normally decided
	# once at tree-entry based on whether the script overrides them. Force
	# it, or hot-loaded movement code silently never runs.
	target.set_process(true)
	target.set_physics_process(true)

	# A script now wants to directly drive this object's position/rotation
	# every frame -- freeze it into kinematic mode so it stops fighting
	# gravity/physics integration, while staying a solid body that still
	# pushes and collides with everything else (an apple this hits still
	# bounces normally; this object just isn't bounced around itself
	# anymore since it's under direct script control now).
	if target is RigidBody3D:
		target.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		target.freeze = true

	# Relation to another selected object: the script never looks this up
	# itself (no get_node/groups allowed in generated code) -- main.gd wires
	# the actual node in as a plain script var after load, same pattern as
	# controls setting throttle/steer. A ref naming an object that no
	# longer exists (or was never actually selected) is just skipped.
	var refs: Dictionary = action.get("refs", {})
	for var_name in refs.keys():
		var other_name: String = refs[var_name]
		var other_node: Node3D = objects.get(other_name)
		if other_node != null and other_node != target:
			target.set(var_name, other_node)

	var controls: Array = action.get("controls", [])
	if controls.size() > 0:
		_build_controls(target, controls)
		status_label.text = "%s is yours to drive" % target.name
	else:
		_clear_controls()
		status_label.text = "%s got new behavior" % target.name

# Replaces whatever control buttons were generated for a previous object --
# one player, one thing driven at a time, so old buttons don't pile up.
# Also drops the camera back to free-roam (see _process) since nothing is
# player-driven anymore once this is called on its own.
const CONTROL_BUTTON_BASE_SIZE := 52.0
const CONTROL_BUTTON_BASE_FONT := 20

func _apply_control_button_scale(btn: Button) -> void:
	var size := CONTROL_BUTTON_BASE_SIZE * controls_scale
	btn.custom_minimum_size = Vector2(size, size)
	btn.add_theme_font_size_override("font_size", int(CONTROL_BUTTON_BASE_FONT * controls_scale))

# Only touches the driving D-pad (drive_controls) and the free-roam
# camera buttons (move_controls) -- fire/action buttons in
# generated_controls are separate and persist independently (see
# _apply_weapon), so switching a car back to autonomous no longer wipes
# out a weapon it was armed with.
func _clear_controls() -> void:
	for child in drive_controls.get_children():
		child.queue_free()
	driven_object = null
	drive_controls.visible = false
	move_controls.visible = true

# Movement buttons go in drive_controls (bottom-left, where the free-roam
# camera buttons normally are -- swapped out for these while driving,
# see below) arranged as a proper D-pad cross by matching the ▲▼◀▶
# labels the model is instructed to use for movement, instead of just
# listing buttons in arrival order. Anything else (a non-vehicle control
# scheme with different labels) still shows up, appended after the cross.
# Fire/action buttons are separate (see _apply_weapon) and stay on the
# right, matching a normal game's move-left/act-right layout.
func _build_controls(target: Node3D, controls: Array) -> void:
	_clear_controls()
	driven_object = target
	drive_controls.visible = true
	move_controls.visible = false

	var by_label := {}
	var leftover: Array = []
	for spec in controls:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		var label: String = spec.get("label", "?")
		if label in ["▲", "▼", "◀", "▶"] and not by_label.has(label):
			by_label[label] = spec
		else:
			leftover.append(spec)

	if by_label.size() > 0:
		var cross: Array = [null, by_label.get("▲"), null, by_label.get("◀"), by_label.get("▼"), by_label.get("▶")]
		for spec in cross:
			if spec == null:
				var spacer := Control.new()
				var s := CONTROL_BUTTON_BASE_SIZE * controls_scale
				spacer.custom_minimum_size = Vector2(s, s)
				drive_controls.add_child(spacer)
			else:
				drive_controls.add_child(_make_hold_button(target, spec))
	for spec in leftover:
		drive_controls.add_child(_make_hold_button(target, spec))

# One held button per control spec, matched to a var the just-loaded
# behavior script declared. Holding adds its value to that var on the
# target; releasing subtracts it back off -- additive (not a flat set/0)
# so opposite buttons (throttle forward/back) held together cancel out
# correctly instead of the later release clobbering the still-held one.
func _make_hold_button(target: Node3D, spec: Dictionary) -> Button:
	var label: String = spec.get("label", "?")
	var var_name: String = spec.get("var", "")
	var value: float = float(spec.get("value", 0.0))
	var btn := Button.new()
	btn.text = label
	btn.modulate = Color(1, 1, 1, 0.75)
	_apply_control_button_scale(btn)
	if var_name != "":
		btn.button_down.connect(func():
			if is_instance_valid(target):
				target.set(var_name, float(target.get(var_name)) + value))
		btn.button_up.connect(func():
			if is_instance_valid(target):
				target.set(var_name, float(target.get(var_name)) - value))
	return btn

func _color_from_name(color_name: String) -> Color:
	match color_name.to_lower():
		"red": return Color(0.85, 0.1, 0.1)
		"green": return Color(0.1, 0.8, 0.2)
		"blue": return Color(0.15, 0.4, 0.9)
		"yellow": return Color(0.95, 0.85, 0.1)
		"orange": return Color(0.95, 0.5, 0.1)
		"purple": return Color(0.6, 0.2, 0.8)
		"black": return Color(0.05, 0.05, 0.05)
		"white": return Color(0.9, 0.9, 0.9)
		_: return Color(0.7, 0.7, 0.7)

# Shared by every mesh's material (spawn/detail/projectile) instead of each
# site building its own flat StandardMaterial3D -- pure albedo with default
# roughness=1/metallic=0 reads as flat matte plastic under real lighting.
# A little roughness variation + a touch of metallic gives primitives an
# actual highlight/sheen from the sky and directional light instead of
# looking like an unlit color swatch.
func _make_material(color_name: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color_from_name(color_name)
	mat.roughness = 0.45
	mat.metallic = 0.15
	mat.metallic_specular = 0.6
	return mat
