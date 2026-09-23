extends AIController2D

@onready var player: CharacterBody2D = owner

# --- VARIÁVEIS DO LOGGER ---
var db: SQLite
var _log_buffer: Array = []
var _last_move_x: float = 0.0
var _last_move_y: float = 0.0
var _last_jump: bool = false
var _last_attack: bool = false
# ---------------------------

func get_obs() -> Dictionary:
	var obs: Array = []
	
	obs.append(player.global_position.x / 1000.0)
	obs.append(player.global_position.y / 1000.0)
	obs.append(player.velocity.x / 500.0)
	obs.append(player.velocity.y / 500.0)
	obs.append(1.0 if player.is_on_floor() else 0.0)
	
	var nearest_enemy = player._get_nearest_enemy()
	if is_instance_valid(nearest_enemy):
		var diff: Vector2 = nearest_enemy.global_position - player.global_position
		var dist: float = diff.length()
		
		obs.append(clamp(diff.x / 500.0, -1.0, 1.0))
		obs.append(clamp(diff.y / 500.0, -1.0, 1.0))
		
		obs.append(clamp(dist / 500.0, 0.0, 1.0))
		
		obs.append(1.0 if diff.x > 0 else -1.0)
		obs.append(1.0 if diff.y > 0 else -1.0)
	else:
		obs.append(0.0)
		obs.append(0.0)
		obs.append(1.0)
		obs.append(0.0)
		obs.append(0.0)
		
	return {"obs": obs}

func get_reward() -> float:
	var current_reward = reward
	reward = 0.0
	
	# Adição sutil: não altera o fluxo original, apenas envia a cópia do valor
	_log_step_data(current_reward)
	
	return current_reward

func get_action_space() -> Dictionary:
	return {
		"move_x": {"size": 1, "action_type": "continuous"},
		"move_y": {"size": 1, "action_type": "continuous"},
		
		# Botões de Ação
		"jump": {"size": 2, "action_type": "discrete"},
		"attack": {"size": 2, "action_type": "discrete"}
	}

func set_action(action) -> void:
	player.ai_movement_x = clamp(float(action["move_x"][0]), -1.0, 1.0)
	player.ai_movement_y = clamp(float(action["move_y"][0]), -1.0, 1.0)
	
	player.ai_movement = player.ai_movement_x
	
	var jump_val = action["jump"]
	player.ai_jump = (jump_val[0] > 0 if jump_val is Array else jump_val == 1)
	
	var attack_val = action["attack"]
	player.ai_attack = (attack_val[0] > 0 if attack_val is Array else attack_val == 1)
	
	# Adição sutil: guarda apenas a leitura final sem interferir na ação do frame
	_cache_current_actions()

# ==========================================
# MÉTODOS AUXILIARES: NÃO INTERFEREM NA IA
# ==========================================
func _cache_current_actions() -> void:
	_last_move_x = player.ai_movement_x
	_last_move_y = player.ai_movement_y
	_last_jump = player.ai_jump
	_last_attack = player.ai_attack

func _setup_database() -> void:
	db = SQLite.new()
	# Usa res:// para salvar na pasta 'logs' na raiz do projeto.
	# Mantemos o get_instance_id() para evitar o erro de Database Locked com múltiplos agentes.
	db.path = "res://logs/ai_training_logs_%s.db" % str(get_instance_id())
	db.open_db()
	
	var table_dict: Dictionary = {
		"id": {"data_type": "int", "primary_key": true, "auto_increment": true},
		"timestamp": {"data_type": "text"},
		"move_x": {"data_type": "real"},
		"move_y": {"data_type": "real"},
		"jump": {"data_type": "int"},
		"attack": {"data_type": "int"},
		"reward": {"data_type": "real"}
	}
	
	db.create_table("agent_logs", table_dict)

func _log_step_data(step_reward: float) -> void:
	# O lazy loading evita precisarmos sobrescrever a função original _ready()
	if db == null:
		_setup_database()
		
	var data: Dictionary = {
		"timestamp": Time.get_datetime_string_from_system(),
		"move_x": _last_move_x,
		"move_y": _last_move_y,
		"jump": 1 if _last_jump else 0,
		"attack": 1 if _last_attack else 0,
		"reward": step_reward
	}
	
	_log_buffer.append(data)
	
	# Ao invés de salvar linha por linha, acumulamos 100 e salvamos tudo de uma vez
	# Isso previne que o Python dê TimeOut esperando o Godot calcular a física
	if _log_buffer.size() >= 100:
		_flush_logs()

func _flush_logs() -> void:
	if db != null and _log_buffer.size() > 0:
		db.insert_rows("agent_logs", _log_buffer) # O plugin sqlite aceita arrays de dicionários direto
		_log_buffer.clear()

func _exit_tree() -> void:
	# Ao destruir o nó, descarrega o restante do buffer para não perder os últimos dados
	_flush_logs()
	if db != null:
		db.close_db()
