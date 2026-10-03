extends RigidBody3D

# Fixed, hand-written logic (not LLM-generated) -- fired projectiles all
# behave the same way regardless of what weapon/prompt spawned them, so
# there's no need to generate code per shot. Straight-line travel,
# self-destructs after `life` seconds. Kinematic (see _fire_projectile in
# main.gd) so it still physically pushes whatever dynamic body it hits
# instead of passing through.

var velocity: Vector3 = Vector3.ZERO
var life: float = 3.0

func _process(delta: float) -> void:
	life -= delta
	if life <= 0.0:
		queue_free()
		return
	global_position += velocity * delta
