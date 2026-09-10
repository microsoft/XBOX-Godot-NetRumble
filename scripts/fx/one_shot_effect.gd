class_name OneShotEffect
extends CPUParticles2D

## One-shot CPUParticles2D effect that frees itself when all its emitters have finished.
## All CPUParticles2D nodes in the subtree are collected and started in _ready; the
## scene is removed from the tree once the last emitter reports its finished signal.

var _pending_emitters: int = 0
var _finished_emitters: Dictionary = {}


func _ready() -> void:
	var emitters := _collect_emitters(self)
	_pending_emitters = emitters.size()
	if _pending_emitters == 0:
		queue_free()
		return

	for emitter in emitters:
		if not emitter.finished.is_connected(_on_emitter_finished):
			emitter.finished.connect(_on_emitter_finished.bind(emitter))
		emitter.emitting = true
		emitter.restart()


func _collect_emitters(node: Node) -> Array[CPUParticles2D]:
	var emitters: Array[CPUParticles2D] = []
	if node is CPUParticles2D:
		emitters.append(node as CPUParticles2D)
	for child in node.get_children():
		emitters.append_array(_collect_emitters(child))
	return emitters


func _on_emitter_finished(emitter: CPUParticles2D) -> void:
	var id := emitter.get_instance_id()
	if _finished_emitters.has(id):
		return
	_finished_emitters[id] = true
	_pending_emitters -= 1
	if _pending_emitters <= 0:
		queue_free()
