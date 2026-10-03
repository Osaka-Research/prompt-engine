extends SceneTree

# Headless smoke test: confirms the visual-polish pass (sky, glow, material
# roughness/metallic) didn't break scene loading or object spawning --
# can't judge the actual look headlessly, just that nothing errors and the
# new material properties are actually applied.

var main

func _init():
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	root.add_child(main)
	await process_frame

	var world_env: WorldEnvironment = main.get_node("WorldEnvironment")
	var env: Environment = world_env.environment
	print("background_mode=%d sky=%s glow_enabled=%s tonemap_mode=%d" % [
		env.background_mode, env.sky != null, env.glow_enabled, env.tonemap_mode
	])

	main.prompt_box.text = "add an apple"
	main._on_submit()
	await main.http.request_completed
	await create_timer(0.3).timeout
	print("status: ", main.status_label.text)

	var apple = main.objects.get("apple")
	if apple == null:
		print("FAIL: apple not spawned")
		quit()
		return
	var mesh: MeshInstance3D = apple.get_children().filter(func(c): return c is MeshInstance3D)[0]
	var mat: StandardMaterial3D = mesh.material_override
	print("apple material roughness=%.2f metallic=%.2f albedo=%s" % [mat.roughness, mat.metallic, mat.albedo_color])

	var ok = env.background_mode == 2 and env.sky != null and env.glow_enabled and mat.roughness < 1.0 and mat.metallic > 0.0
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	quit()
