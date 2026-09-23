extends CharacterBody2D

@warning_ignore("unused_signal")
signal state_changed(new_state: String)
@warning_ignore("unused_signal")
signal dash_started(total_time: float)
@warning_ignore("unused_signal")
signal dash_updated(remaining_time: float, total_time: float)
@warning_ignore("unused_signal")
signal dash_ended()
signal player_died
signal player_revive

@export var stats: PlayerStats
@export var animator_path: NodePath
@export var slash_effect: PackedScene
@export var hurtbox_collision: CollisionShape2D
@export var camera: Camera2D

@onready var animator: AnimatedSprite2D = get_node(animator_path)
@onready var sm: Node = $StateMachine

@export var footstep_sounds: Array[AudioStream] = []
@export var step_player: AudioStreamPlayer2D
@export var sfx_player: AudioStreamPlayer2D

# --- SISTEMA DE PESOS DA IA (Rewards e Penalidades) ---
@export_category("AI Rewards & Penalties")
@export var weight_hit_enemy: float = 2.0
@export var weight_take_damage: float = -3.0
@export var weight_death: float = -10.0
@export var weight_miss_attack: float = -0.5
@export var weight_edge_map: float = -0.2      
@export var weight_too_close: float = -0.05
@export var min_safe_distance: float = 80.0
@export var weight_invalid_jump: float = -0.5
@export var weight_jump_spam: float = -0.8
@export var min_jump_interval: float = 0.4
@export var weight_wrong_attack_direction: float = -1.0
@export var weight_idle_near_enemy: float = -2.0
@export var enemy_danger_radius: float = 300.0
@export var min_move_speed_threshold: float = 20.0

@export_group("Arena Center Penalty")
@export var arena_center_x: float = 600.0          
@export var center_safe_radius: float = 150.0      
@export var weight_far_from_center: float = -0.002 

# Entradas da IA
var ai_movement_x: float = 0.0
var ai_movement_y: float = 0.0
var ai_movement: float = 0.0
var ai_jump: bool = false
var prev_ai_jump: bool = false
var ai_attack: bool = false
var ai_attack_direction: Vector2 = Vector2.RIGHT

@export var control_by_ai: bool = true

@onready var ai_controller: Node2D = $ai_controller

const FOOTSTEP_01 = preload("res://audio/gameplay/footstep_01.wav")
const FOOTSTEP_02 = preload("res://audio/gameplay/footstep_02.wav")
const FOOTSTEP_03 = preload("res://audio/gameplay/footstep_03.wav")
const FOOTSTEP_04 = preload("res://audio/gameplay/footstep_04.wav")
const FOOTSTEP_05 = preload("res://audio/gameplay/footstep_05.wav")

var _knockback: Vector2 = Vector2.ZERO
var _knockback_time_left: float = 0.0
var _knockback_decay: float = 14.0

var last_step := -1
var interactable_faction = 0
var _facing := 1
var _invincible := 0.0
var _coyote := 0.5
var _jump_buffer := 0.0
var _jumps_max := 1
var _jumps_left := 1
var was_on_floor := false
var air_stall_used := false

var _time_since_last_jump: float = 999.0

var getting_up: bool = true
var is_dead: bool = false
var adjust_cam: bool = false

@onready var spawn_position: Vector2 = global_position

func _ready() -> void:
	if getting_up:
		_play_wake_up_sequence()
		while getting_up:
			await get_tree().create_timer(0.1).timeout

	_recompute_jump_caps()
	_reset_jumps_on_ground(true)
	sm.init(self)

	if animator and not getting_up:
		animator.play("idle")

func _play_wake_up_sequence() -> void:
	await get_tree().create_timer(2.0).timeout
	adjust_cam = true
	await get_tree().create_timer(2.0).timeout
	if animator:
		if not animator.animation_finished.is_connected(_wake_player):
			animator.animation_finished.connect(_wake_player)
		animator.play("wake_up")

func _get_nearest_enemy() -> Node2D:
	var nearest_enemy: Node2D = null
	var min_distance: float = INF
	
	var bodies = _find_nodes_by_type(get_tree().root, CharacterBody2D)
	
	for e in bodies:
		if e != self and is_instance_valid(e):
			var dist = global_position.distance_to(e.global_position)
			if dist < min_distance:
				min_distance = dist
				nearest_enemy = e
				
	return nearest_enemy

func _find_nodes_by_type(node: Node, type) -> Array:
	var results = []
	if is_instance_of(node, type):
		results.append(node)
	for child in node.get_children():
		results.append_array(_find_nodes_by_type(child, type))
	return results

func reward_hit_enemy():
	if control_by_ai:
		ai_controller.reward += weight_hit_enemy

func reward_take_damage():
	if control_by_ai:
		ai_controller.reward += weight_take_damage

func play_step_sfx() -> void:
	if footstep_sounds.is_empty():
		return
	var index = randi() % footstep_sounds.size()
	if footstep_sounds.size() > 1 and index == last_step:
		index = (index + 1) % footstep_sounds.size()
	last_step = index

	step_player.set_stream(footstep_sounds[index])
	step_player.pitch_scale = randf_range(0.93, 1.05)
	step_player.play()

func play_sfx(audio: AudioStream) -> void:
	sfx_player.set_stream(audio)
	sfx_player.play()

func adjust_camera(_delta) -> void:
	if adjust_cam and getting_up:
		camera.position = lerp(camera.position, Vector2.ZERO, 0.04)
	elif is_dead:
		camera.offset = lerp(camera.offset, Vector2(15.0, 0.0), 0.04)
		camera.position = lerp(camera.position, Vector2.ZERO, 0.04)
		camera.zoom = lerp(camera.zoom, Vector2(0.912, 0.912), 0.04)

func get_attack_direction() -> Vector2:
	var dir := Vector2.ZERO
	
	if control_by_ai:
		# Threshold para evitar acionamentos por zona morta/ruído do modelo
		if abs(ai_movement_y) > 0.4:
			dir.y = sign(ai_movement_y) # -1.0 para CIMA, 1.0 para BAIXO
		elif abs(ai_movement_x) > 0.2:
			dir.x = sign(ai_movement_x)
		else:
			dir.x = _facing
	else:
		# Entradas manuais do jogador
		var input_y = Input.get_axis("ui_up", "ui_down")
		var input_x = Input.get_axis("ui_left", "ui_right")
		
		if input_y != 0:
			dir.y = input_y
		elif input_x != 0:
			dir.x = input_x
		else:
			dir.x = _facing
			
	return dir

func _physics_process(delta: float) -> void:
	if !is_dead:
		adjust_camera(delta)
		_update_common_timers(delta)
		
		var keyboard_move = Input.get_axis("ui_left", "ui_right")
		var final_movement = keyboard_move
		
		if final_movement == 0.0 and control_by_ai:
			final_movement = ai_movement_x
			
		if final_movement != 0 && !getting_up:
			velocity.x = move_toward(velocity.x, final_movement * stats.move_speed, stats.accel_ground * delta)
			set_facing(sign(final_movement))
		else:
			velocity.x = move_toward(velocity.x, 0, stats.friction * delta)

		var ai_jump_just_pressed = false
		if control_by_ai:
			if ai_jump and not prev_ai_jump:
				ai_jump_just_pressed = true
			prev_ai_jump = ai_jump 
			
		var jump_pressed = Input.is_action_just_pressed("jump") or ai_jump_just_pressed
		
		if jump_pressed && !getting_up:
			print("[DEBUG] Pulo Solicitado | _jumps_left:", _jumps_left, " | _jumps_max:", _jumps_max, " | No chão:", is_on_floor())
			if control_by_ai:
				if _time_since_last_jump < min_jump_interval:
					ai_controller.reward += weight_jump_spam
				_time_since_last_jump = 0.0

			if _jumps_left > 0:
				buffer_jump()
			else:
				if control_by_ai:
					ai_controller.reward += weight_invalid_jump
				
		sm.update(delta)

		if _knockback_time_left > 0.0:
			_knockback_time_left = max(_knockback_time_left - delta, 0.0)
			_knockback = _knockback.move_toward(Vector2.ZERO, _knockback_decay * delta)
			velocity.x = _knockback.x
			if _knockback.y != 0.0:
				if _knockback.y < velocity.y:
					velocity.y = _knockback.y
					
		var attack_pressed = Input.is_action_just_pressed("attack") or (ai_attack and control_by_ai)
		
		var nearest = _get_nearest_enemy()
		
		if attack_pressed && !getting_up:
			ai_attack_direction = get_attack_direction()
			
			#if control_by_ai:
				#if nearest == null or global_position.distance_to(nearest.global_position) > 180.0:
					#ai_controller.reward += weight_miss_attack
				#elif nearest != null:
					#var to_enemy_dir = global_position.direction_to(nearest.global_position)
					#
					#if ai_attack_direction.dot(to_enemy_dir) <= 0.0:
						#ai_controller.reward += weight_wrong_attack_direction
			
			if sm.current_state and sm.get_state_name(sm.current_state) != "Attack":
				if sm.states.has("Attack") and sm.is_ready("attack"):
					sm.change_state("Attack")

		if control_by_ai:
			var map_left_limit = 50.0
			var map_right_limit = 1150.0
			if global_position.x < map_left_limit or global_position.x > map_right_limit:
				ai_controller.reward += weight_edge_map * delta 

			var distance_from_center = abs(global_position.x - arena_center_x)
			if distance_from_center > center_safe_radius:
				var excess_distance = distance_from_center - center_safe_radius
				ai_controller.reward += excess_distance * weight_far_from_center * delta

			if nearest != null:
				var dist_to_enemy = global_position.distance_to(nearest.global_position)
				if dist_to_enemy < min_safe_distance:
					var close_diff = min_safe_distance - dist_to_enemy
					ai_controller.reward += close_diff * weight_too_close * delta
				
				if dist_to_enemy <= enemy_danger_radius and abs(velocity.x) < min_move_speed_threshold:
					ai_controller.reward += weight_idle_near_enemy * delta
	else:
		adjust_camera(delta)
		velocity.x = 0.0
		velocity.y = 150.0

	move_and_slide()

func has_jump_buffer() -> bool:
	return _jump_buffer > 0.0

func consume_jump_buffer() -> void:
	_jump_buffer = 0.0

func buffer_jump() -> void:
	_jump_buffer = stats.jump_buffer_time

func can_coyote_jump() -> bool:
	return (_coyote > 0.0 and not is_on_floor()) or is_on_floor()

func consume_ground_or_coyote_jump() -> bool:
	if is_on_floor() and _jumps_left > 0:
		_jumps_left -= 1
		print("[DEBUG] Pulo consumido (Chão) | Restantes:", _jumps_left)
		return true
	elif _coyote > 0.0 and _jumps_left > 0:
		_jumps_left -= 1
		_coyote = 0.0
		print("[DEBUG] Pulo consumido (Coyote) | Restantes:", _jumps_left)
		return true
	return false

func can_double_jump() -> bool:
	if not stats.enable_double_jump:
		return false
	if _jumps_left <= 0:
		return false
	if stats.allow_second_jump_from_ground:
		return true
	return not is_on_floor()

func consume_double_jump() -> void:
	if _jumps_left > 0:
		_jumps_left -= 1
		print("[DEBUG] Pulo Duplo consumido | Restantes:", _jumps_left)

func has_animator() -> bool:
	return animator != null

func set_facing(dir: int) -> void:
	if dir != 0:
		_facing = dir
		if animator:
			animator.flip_h = _facing > 0

func set_hurtbox(state: bool) -> void:
	if hurtbox_collision:
		hurtbox_collision.set_deferred("disabled", state)

func refresh_landing() -> void:
	_reset_jumps_on_ground(true)

func _update_common_timers(delta: float) -> void:
	var grounded = is_on_floor()
	if grounded and not was_on_floor:
		_coyote = stats.coyote_time
		_reset_jumps_on_ground(true)
		_jump_buffer = 0.0
		air_stall_used = false
	elif not grounded:
		_coyote = max(_coyote - delta, 0.0)
	_jump_buffer = max(_jump_buffer - delta, 0.0)
	_invincible = max(_invincible - delta, 0.0)
	_time_since_last_jump += delta
	was_on_floor = grounded

func _recompute_jump_caps() -> void:
	if stats.enable_double_jump:
		_jumps_max = 2
	else:
		_jumps_max = 1

func _reset_jumps_on_ground(full: bool) -> void:
	if full:
		_jumps_left = _jumps_max
		print("[DEBUG] Jumps resetados no chão | Novos _jumps_left:", _jumps_left)
	else:
		_jumps_left = 0

func _death(_source: Node) -> void:
	#emit_signal("player_died")
	player_revive.emit()
	set_facing(-1)
	camera.limit_left = -10000000
	camera.limit_right = 10000000
	camera.limit_bottom = 820
	#EventBus.player_revive.emit()
	is_dead = false
	if animator:
		animator.z_index = 30
		animator.play("dead")

func _wake_player():
	if getting_up:
		await get_tree().create_timer(2.0).timeout
		EventBus.player_woke.emit()
		getting_up = false
		if has_node("PlayerUI"):
			$PlayerUI.visible = true

func revive(spawn_pos: Vector2) -> void:
	global_position = spawn_pos
	velocity = Vector2.ZERO
	is_dead = false
	getting_up = false
	
	_knockback = Vector2.ZERO
	_knockback_time_left = 0.0

	ai_movement = 0.0
	ai_jump = false
	ai_attack = false
	if is_instance_valid(ai_controller):
		ai_controller.reward = 0.0

	if camera:
		camera.offset = Vector2.ZERO
		camera.zoom = Vector2.ONE

	if animator:
		animator.z_index = 0
	
	getting_up = true
	_ready()

	var health_comp: Health = get_node_or_null("Health") as Health
	if health_comp:
		health_comp.current_health = health_comp.max_health
		health_comp.declared_dead = false
		health_comp.invulnerable = false
		health_comp.health_changed.emit(health_comp.current_health, health_comp.max_health)

	_reset_jumps_on_ground(true)
	
	if sm.states.has("Idle"):
		sm.change_state("Idle")
	
	getting_up = false
	is_dead = false
		
func _notify_damage() -> void:
	EventBus.player_damaged.emit()
	print("Player taking damage")

func has_knockback_control() -> bool:
	return _knockback_time_left > 0.0

func apply_knockback(_source: Node, kb: Vector2) -> void:
	_knockback = kb
	_knockback_time_left = 0.2
	if animator:
		animator.play("stun")

func get_faction() -> int:
	return interactable_faction
