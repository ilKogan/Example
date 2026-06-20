extends Control


func _ready() -> void:
	$Label.text = "Hello from %s v%s!" % [
		ProjectSettings.get_setting("application/config/name"),
		ProjectSettings.get_setting("application/config/version"),
	]
