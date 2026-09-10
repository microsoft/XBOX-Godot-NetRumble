class_name IdentityService
extends RefCounted

## Sign-in for online play. Follows the addon's canonical flow documented in
## docs/addon-getting-started.md.
##
## Sign-in is REQUIRED for multiplayer. PlayFab Party is the game's transport and
## PlayFab Lobby is its matchmaking, and both take a PlayFabUser, so there is no
## "play online as a guest" path. Xbox identity is acquired with the
## check -> silent -> UI fallback (GDK.users.get_primary_user /
## add_default_user_async / add_user_with_ui_async) and handed to
## PlayFab.users.sign_in_with_xuser_async.
##
## Local multi-instance override, debug desktop builds only. The GDK binds one Xbox user
## per PC, so two signed-in GDK instances cannot coexist on one machine — testing Party
## would otherwise need two PCs. Passing --pf-user=<name> (or setting PF_CUSTOM_ID)
## switches this service to PlayFab custom-id sign-in, which has no such constraint, so
## several local instances can each be a distinct PlayFab entity in the same lobby and
## Party network. This is the mechanism the addon's own PlayFab tutorials use for local
## Party testing; the Xbox path is unchanged and remains the shipping path.
##
## Because that path reaches PlayFab with no Xbox identity behind it — and creates the
## account on first use — it is gated by developer_overrides_allowed() and cannot run on
## a console or in an exported release build, where the Xbox-linked path is the only way
## in.
##
## Addon SDK objects (XboxUser, PlayFabUser, XboxResult, PlayFabResult) are held as
## Variant on purpose: the godot_gdk / godot_playfab classes only exist when their
## native libraries load, so naming them in type positions would break parsing on a
## machine without the extensions. Domain data stays strongly typed.

## Command-line flag / environment variable selecting a per-instance PlayFab identity.
const USER_ARG := "--pf-user"
const USER_ENV := "PF_CUSTOM_ID"
## Feature tag identifying a console build, as used by NRSystemKeyboard.
const CONSOLE_FEATURE := "scarlett"
## Overrides playfab/runtime/title_id. The title id shipped with this sample does not
## allow custom-id account creation, so anyone testing Party locally needs to point at
## a title of their own.
const TITLE_ARG := "--pf-title"
const TITLE_ENV := "PF_TITLE_ID"
const TITLE_SETTING := "playfab/runtime/title_id"
## Custom ids are namespaced so tutorial and sample accounts can't collide.
const CUSTOM_ID_PREFIX := "godot-netrumble-"

## Shown in place of a title identifier that neither the GDK runtime nor
## MicrosoftGame.config could supply, so a display row keeps its shape.
const UNKNOWN_TITLE_ID := "unavailable"

## MicrosoftGame.config, the packaging source of truth for the Store ID, consulted only
## when the runtime cannot answer (see _config_store_id). Two locations because the two
## unpackaged cases put it in different places: the project copy covers the editor, and
## the copy the GDK exporter stages beside the executable covers a loose exported build,
## where the project file is not in the PCK. export_presets.cfg is deliberately never
## read: its ids configure the export template and currently name a different title.
const GAME_CONFIG_PROJECT_PATH := "res://MicrosoftGame.config"
const GAME_CONFIG_FILE_NAME := "MicrosoftGame.config"

## Package lookup arguments for the process's own package. Spelled out as ints because
## XboxPackage's enums only exist once the GDK extension has loaded, and these lookups
## have to parse and run without it. Both differ from the addon's defaults, which
## describe DLC rather than the game itself.
##
## 0 is XPackageKind::Game (the addon's PACKAGE_KIND_GAME).
const _PACKAGE_KIND_GAME := 0
## 0 is XPackageEnumerationScope::ThisOnly, the calling process's own package, which is
## exactly the one being looked up here. The addon names its 0 constant
## ENUMERATION_SCOPE_THIS_PUBLISHER, but it casts the value straight through to the
## native enum (ThisOnly, ThisAndRelated, ThisPublisher), so 0 really is ThisOnly and
## the addon's name is a misnomer; native ThisPublisher (2) is rejected as out of range.
const _ENUMERATION_SCOPE_THIS_ONLY := 0

## The step sign-in is currently on, in words fit to show the player. Sign-in is a chain
## of platform calls that cannot be stepped through on a desktop machine, and a stalled
## one is otherwise indistinguishable from any other — the screen shows this under the
## spinner so a stall names itself without a debugger attached.
signal stage_changed(stage: String)

var gdk_user: Variant = null
var playfab_user: Variant = null
var display_name: String = ""
var entity_id: String = ""
var xbox_user_id: String = ""
## Player-facing reason the last sign_in() failed. Empty after a success.
var last_error: String = ""

## Title identifiers are fixed for the lifetime of the process, so the first lookup
## that the runtime actually answered is kept rather than re-queried per caller. Holds
## title_id and store_id only: the sandbox can change outside the game, so it is read
## fresh on every call.
var _title_identifiers: Dictionary = {}
## Set when the title is closing. The call in flight is left to land, but nothing new is
## started on the other side of it.
var _shutting_down := false


## Stops the sign-in chain going any further than the call already in flight. Nothing is
## cancelled: the outstanding call is left to complete on its own, and only the steps that
## would have followed it are skipped.
func begin_shutdown() -> void:
	_shutting_down = true


func is_signed_in() -> bool:
	return playfab_user != null


## True when this instance was launched with a custom-id override, i.e. it is a local
## test client rather than a real Xbox sign-in.
func is_custom_id_session() -> bool:
	return not resolve_custom_id_token().is_empty()


func sign_in() -> bool:
	last_error = ""

	var token := resolve_custom_id_token()
	if not token.is_empty():
		return await _sign_in_with_custom_id(CUSTOM_ID_PREFIX + token)

	var xbox_user: Variant = await _ensure_xbox_user()
	if xbox_user == null:
		return false

	var pf_user: Variant = await _ensure_playfab_user(xbox_user)
	if pf_user == null:
		return false

	gdk_user = xbox_user
	playfab_user = pf_user
	display_name = String(xbox_user.gamertag)
	xbox_user_id = String(xbox_user.xuid)
	entity_id = _entity_id_of(pf_user)
	# Publishing the display name is a fresh network call, and the title is closing. The
	# identity above is already assembled, so this is the one step worth skipping.
	if _shutting_down:
		return true
	await _publish_entity_display_name()
	return true


## Publishes the player's name as this account's PlayFab entity display name (XR-014).
##
## PlayFab identifies accounts by entity id, and an entity id is an opaque account
## identifier that must never be shown to another player. Any PlayFab feature that
## returns a list of entities returns a display name per row — but only the one stored
## on the entity profile, unlike Xbox Live services which resolve a gamertag for you.
## If the title never writes one, those rows come back empty or as raw entity ids.
##
## Written once per sign-in rather than at each point of use: it is a profile property,
## not match data, and the gamertag only changes between sessions. Best-effort like the
## rest of the non-multiplayer surface — a failure costs a nicer-looking profile, not
## the session, so it warns and lets sign-in succeed.
func _publish_entity_display_name() -> void:
	if display_name.is_empty() or playfab_user == null:
		return
	var pf: Variant = _playfab()
	if pf == null:
		return

	_stage("Publishing your gamertag to PlayFab")
	var result: Variant = await pf.accounts.set_display_name_async(playfab_user, {
		"entity": playfab_user.entity_key,
		"display_name": display_name,
	})
	if result == null or not result.ok:
		push_warning("[Services] Publishing the PlayFab display name failed: %s" % _reason(result))


func sign_out() -> void:
	gdk_user = null
	playfab_user = null
	display_name = ""
	entity_id = ""
	xbox_user_id = ""
	last_error = ""


## GDK rich presence lives on ActivityService, alongside the multiplayer activity and
## the rest of the platform-facing session state.


# --- Title identifiers ------------------------------------------------------

## The Xbox sandbox, Title ID and Store ID of the running title, for display.
##
## All three are read from the GDK runtime, so what is shown is the identity the process
## actually resolved against Xbox services:
##   * Sandbox comes from GDK.system.get_sandbox_id() (XSystemGetXboxLiveSandboxId),
##     e.g. XDKS.1, or RETAIL when no development sandbox is set.
##   * Title ID comes from GDK.system.get_title_id_hex() (XGameGetXboxTitleId), which
##     answers as soon as the runtime is initialized.
##   * Store ID has no direct getter — XStore only answers questions about a product id
##     the caller already holds — so it is recovered from the package the process runs
##     out of: get_current_process_package_identifier() then find_package_by_identifier(),
##     whose dictionary carries store_id.
##
## The Store ID alone falls back to MicrosoftGame.config, because it is the one value
## that is unknowable rather than merely unavailable when running unpackaged: there is
## no package, so there is no Store identity to report. The Title ID has no such
## fallback — the runtime answers it in the editor too, and the config spells it in a
## different format (bare lowercase hex against the runtime's 0x-prefixed uppercase),
## so reading it from there would make the same title look like two different ids.
##
## Returns {"sandbox_id": String, "title_id": String, "store_id": String}, each
## UNKNOWN_TITLE_ID when nothing can supply it. Safe to call before the GDK is
## initialized, and before (or without) anyone signing in: these identify the title and
## its environment, not the player.
func get_title_identifiers() -> Dictionary:
	# The sandbox is environment state rather than title identity: it is switched from
	# outside the game (the Xbox app, XblSetSandbox) and so is read fresh every time,
	# where the ids below are fixed for the process and cached.
	var ids := {"sandbox_id": _runtime_sandbox_id()}

	if not _title_identifiers.is_empty():
		ids.merge(_title_identifiers)
	else:
		ids.merge({
			"title_id": _runtime_title_id(),
			"store_id": _runtime_store_id(),
		})

		# Whether the runtime answered in full, decided before the config fills anything
		# in. Caching is what makes this the process-lifetime answer, so it has to be
		# earned by the runtime: caching a config-derived value would pin it for a
		# session that goes on to initialize the GDK, and caching a partial answer would
		# pin the placeholder.
		var runtime_answered := not (String(ids["title_id"]).is_empty()
				or String(ids["store_id"]).is_empty())

		if String(ids["store_id"]).is_empty():
			ids["store_id"] = _config_store_id()

		for key: String in ["title_id", "store_id"]:
			if String(ids[key]).is_empty():
				ids[key] = UNKNOWN_TITLE_ID

		if runtime_answered:
			_title_identifiers = {"title_id": ids["title_id"], "store_id": ids["store_id"]}

	if String(ids["sandbox_id"]).is_empty():
		ids["sandbox_id"] = UNKNOWN_TITLE_ID
	return ids


## The Xbox Live sandbox, e.g. XDKS.1, or RETAIL when none is set. Unlike the Store ID
## this does not need a registered package, only an initialized runtime.
func _runtime_sandbox_id() -> String:
	var gdk: Variant = _initialized_gdk()
	if gdk == null:
		return ""
	var result: Variant = gdk.system.get_sandbox_id()
	if result == null or not result.ok:
		return ""
	return String(result.data).strip_edges()


## Uppercase 0x-prefixed hex, e.g. 0x7E0B7C03. Empty when the runtime cannot answer.
func _runtime_title_id() -> String:
	var gdk: Variant = _initialized_gdk()
	if gdk == null:
		return ""
	var result: Variant = gdk.system.get_title_id_hex()
	if result == null or not result.ok:
		return ""
	return String(result.data).strip_edges()


func _runtime_store_id() -> String:
	var gdk: Variant = _initialized_gdk()
	if gdk == null:
		return ""

	var identifier: Variant = gdk.package.get_current_process_package_identifier()
	if identifier == null or not identifier.ok:
		return ""

	var package: Variant = gdk.package.find_package_by_identifier(
			String(identifier.data), _PACKAGE_KIND_GAME, _ENUMERATION_SCOPE_THIS_ONLY)
	if package == null or not package.ok or typeof(package.data) != TYPE_DICTIONARY:
		return ""

	var info: Dictionary = package.data
	return String(info.get("store_id", "")).strip_edges()


## <StoreId> from MicrosoftGame.config, or empty when the file is absent, unreadable or
## has no such element. Only the Store ID is taken from here; see get_title_identifiers.
func _config_store_id() -> String:
	for path: String in _game_config_paths():
		var store_id := _read_config_store_id(path)
		if not store_id.is_empty():
			return store_id
	return ""


## Where MicrosoftGame.config can be found when running unpackaged: the project copy
## (the editor case), then the copy staged beside the executable (a loose exported
## build, whose PCK does not carry the project file).
func _game_config_paths() -> PackedStringArray:
	var paths := PackedStringArray([GAME_CONFIG_PROJECT_PATH])
	var exe_dir := OS.get_executable_path().get_base_dir()
	if not exe_dir.is_empty():
		paths.append(exe_dir.path_join(GAME_CONFIG_FILE_NAME))
	return paths


func _read_config_store_id(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""

	var parser := XMLParser.new()
	if parser.open(path) != OK:
		return ""

	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		if parser.get_node_name() != "StoreId":
			continue
		# Self-closing <StoreId/> carries no value, and reading past it would consume
		# the following element instead.
		if parser.is_empty():
			return ""
		if parser.read() != OK or parser.get_node_type() != XMLParser.NODE_TEXT:
			return ""
		return parser.get_node_data().strip_edges()

	return ""


## The GDK singleton only once the runtime is up. Both title identifier lookups go
## through the runtime rather than the extension alone, and calling them on a loaded
## but uninitialized extension just returns errors.
func _initialized_gdk() -> Variant:
	return PlatformAccess.gdk_ready()


# --- Xbox (GDK) path --------------------------------------------------------

func _ensure_xbox_user() -> Variant:
	_stage("Starting the Microsoft GDK")
	var gdk: Variant = _gdk()
	if gdk == null:
		last_error = "The Microsoft GDK extension is not installed in this build."
		return null

	if not gdk.is_initialized():
		var init: Variant = gdk.initialize()
		if init == null or not init.ok:
			last_error = "The Microsoft GDK could not start. Check that MicrosoftGame.config sits next to the executable.\n\n%s" % _reason(init)
			return null

	_stage("Looking for a signed-in Xbox account")
	var primary: Variant = gdk.users.get_primary_user()
	if primary != null and primary.signed_in:
		return primary

	_stage("Signing in to Xbox")
	var silent: Variant = await gdk.users.add_default_user_async()
	if silent != null and silent.ok and silent.data != null and silent.data.signed_in:
		return silent.data

	# no_default_user on a clean PC is the cue to escalate to the system UI path.
	# This only resolves under the advanced user model; MicrosoftGame.config selects
	# the simplified one, where interactive adds come back E_INVALIDARG and this
	# falls through to last_error below.
	_stage("Waiting for the Xbox sign-in screen")
	var ui: Variant = await gdk.users.add_user_with_ui_async()
	if ui != null and ui.ok and ui.data != null and ui.data.signed_in:
		return ui.data

	last_error = "Xbox sign-in did not complete. Sign in to the Xbox app, then try again.\n\n%s" % _reason(ui)
	return null


func _ensure_playfab_user(xbox_user: Variant) -> Variant:
	if not _ensure_playfab():
		return null

	if xbox_user == null or not xbox_user.signed_in:
		last_error = "No Xbox user is signed in."
		return null

	_stage("Signing in to PlayFab")
	var result: Variant = await _playfab().users.sign_in_with_xuser_async(xbox_user)
	if result == null or not result.ok:
		last_error = "PlayFab rejected the Xbox sign-in.\n\n%s" % _reason(result)
		return null
	return result.data

# --- Custom-id path (local multi-instance testing) --------------------------

func _sign_in_with_custom_id(custom_id: String) -> bool:
	if not _ensure_playfab():
		return false

	# create_account=true provisions the account on first run and reuses it after.
	_stage("Signing in to PlayFab")
	var result: Variant = await _playfab().users.sign_in_with_custom_id_async(custom_id, true)
	if result == null or not result.ok:
		last_error = "PlayFab custom-id sign-in failed for '%s'.\n\n%s" % [custom_id, _reason(result)]
		return false

	gdk_user = null
	playfab_user = result.data
	xbox_user_id = ""
	entity_id = _entity_id_of(playfab_user)
	# No gamertag on this path, so the instance is named after its own token. That
	# also gives each local test client a distinct roster name.
	display_name = custom_id.trim_prefix(CUSTOM_ID_PREFIX).capitalize()
	# Published for the same reason as the Xbox path: without it this account has no
	# profile display name at all, which reads as a bug rather than the absence of a
	# gamertag. Skipped when closing, for the same reason as there.
	if not _shutting_down:
		await _publish_entity_display_name()
	print("[Services] Signed in as PlayFab custom id '%s' (%s override)." % [custom_id, USER_ARG])
	return true


## Whether the developer overrides below may take effect at all.
##
## Both of them exist to make local testing possible and neither belongs in a shipping
## build: the custom-id path signs a player in to PlayFab with no Xbox identity behind
## it and creates the account on demand, and the title override repoints the build at a
## different PlayFab title. A retail console build must reach PlayFab only through the
## Xbox-linked path, so the overrides are inert whenever this is a console build or an
## exported release build, no matter what the command line or environment says.
##
## Debug desktop builds and the editor keep them, which is where the two-instances-on-
## one-PC Party test flow runs.
static func developer_overrides_allowed() -> bool:
	if OS.has_feature(CONSOLE_FEATURE):
		return false
	return OS.is_debug_build()


## True when the platform provides a protected, per-user store — the Game Save synced
## folder — and personal data must therefore stay out of `user://`.
##
## `user://` on console is one storage area shared by the whole title, with no per-user
## partition and no encryption, so anything written there outlives the account that wrote
## it and is readable by the next one (XR-014, XR-052). The Game Save folder is neither:
## the platform scopes it to the user it was resolved for and protects it at rest, which
## is why it is the only store the console build uses.
##
## Desktop has no such folder — Game Saves reject a session with no local user handle —
## so desktop keeps the plaintext files. That is the development configuration, it holds
## no console account's data, and it is not what ships. Static for the same reason
## `resolve_custom_id_token()` is: PlayerProfile answers this during its own `_ready()`,
## before Services has finished constructing.
static func has_protected_storage() -> bool:
	return OS.has_feature(CONSOLE_FEATURE)


## Resolution order: --pf-user=<token> (or "--pf-user <token>", including user args
## passed after `--`), then PF_CUSTOM_ID. Empty means "use the Xbox path", which is the
## only answer a console or release build can give. Static so callers such as
## PlayerProfile can namespace per-instance state at startup without waiting for
## Services to finish constructing.
static func resolve_custom_id_token() -> String:
	var token := _read_arg(USER_ARG)
	if token.is_empty():
		token = OS.get_environment(USER_ENV).strip_edges()
	if token.is_empty():
		return ""
	if not developer_overrides_allowed():
		_warn_override_ignored(USER_ARG)
		return ""
	return token


## Reports a suppressed override once per flag. Without this a developer who launches a
## release build with --pf-user just sees the Xbox sign-in path run instead, with no
## indication of why.
static var _warned_overrides: Dictionary = {}

static func _warn_override_ignored(flag: String) -> void:
	if _warned_overrides.has(flag):
		return
	_warned_overrides[flag] = true
	push_warning("[Services] %s is a debug-only override and is ignored in this build." % flag)


## Reads "<flag>=<value>" or "<flag> <value>" from the command line, including user
## args passed after Godot's `--` separator.
static func _read_arg(flag: String) -> String:
	var args: Array = []
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	for i in args.size():
		var arg := String(args[i])
		if arg.begins_with(flag + "="):
			return arg.substr(flag.length() + 1).strip_edges()
		if arg == flag and i + 1 < args.size():
			return String(args[i + 1]).strip_edges()
	return ""


# --- Shared -----------------------------------------------------------------

func _ensure_playfab() -> bool:
	var pf: Variant = _playfab()
	if pf == null:
		last_error = "The PlayFab extension is not installed in this build."
		return false
	if pf.is_initialized():
		return true
	_stage("Starting PlayFab")
	# Apply the title override before initializing; the title id is read from
	# ProjectSettings when PlayFab starts, so it has to be in place first. This is why
	# playfab/runtime/initialize_on_startup is off — we own the moment of init.
	_apply_title_override()
	var init: Variant = pf.initialize()
	if init == null or not init.ok:
		last_error = "PlayFab could not start. Set playfab/runtime/title_id in Project Settings, or pass %s=<id>.\n\n%s" % [TITLE_ARG, _reason(init)]
		return false
	return true


func _apply_title_override() -> void:
	if not developer_overrides_allowed():
		if not _read_arg(TITLE_ARG).is_empty() or not OS.get_environment(TITLE_ENV).strip_edges().is_empty():
			_warn_override_ignored(TITLE_ARG)
		return
	var title := _read_arg(TITLE_ARG)
	if title.is_empty():
		title = OS.get_environment(TITLE_ENV).strip_edges()
	if title.is_empty():
		return
	ProjectSettings.set_setting(TITLE_SETTING, title)
	print("[Services] PlayFab title id overridden to '%s'." % title)


func _entity_id_of(pf_user: Variant) -> String:
	if pf_user == null:
		return ""
	var key: Dictionary = pf_user.entity_key
	return String(key.get("id", ""))


func _gdk() -> Variant:
	return PlatformAccess.gdk()


func _playfab() -> Variant:
	return PlatformAccess.playfab()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)


## Announces the step about to be attempted. Emitted immediately before the call it
## names, so whatever is on screen when sign-in stops is the call that stopped.
func _stage(stage: String) -> void:
	stage_changed.emit(stage)
