class_name NRChatLog
extends PanelContainer

const MESSAGE_LIMIT := 4

@onready var _rows: Array[Label] = [%Message1, %Message2, %Message3, %Message4]

var _messages: Array[Dictionary] = []


func _ready() -> void:
	_refresh()


func add_message(peer_id: int, sender: String, text: String) -> void:
	_messages.append({"peer_id": peer_id, "sender": sender, "text": text})
	if _messages.size() > MESSAGE_LIMIT:
		_messages.pop_front()
	_refresh()


func refresh_senders(names: Dictionary[int, String]) -> void:
	for index in range(_messages.size() - 1, -1, -1):
		var peer_id: int = _messages[index]["peer_id"]
		if not names.has(peer_id):
			_messages.remove_at(index)
		else:
			_messages[index]["sender"] = names[peer_id]
	_refresh()


func clear() -> void:
	_messages.clear()
	_refresh()


func _refresh() -> void:
	visible = not _messages.is_empty()
	for index in _rows.size():
		var row := _rows[index]
		row.visible = index < _messages.size()
		row.text = "%s: %s" % [_messages[index]["sender"], _messages[index]["text"]] if row.visible else ""
