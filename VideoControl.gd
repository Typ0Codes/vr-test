extends Control

const YTDLP_HOSTS := ["youtube.com", "youtu.be"]
const FONT_EXTS := ["ttf", "otf", "ttc", "woff", "woff2"]

@onready var video: VideoPlayback = $VBoxContainer/Control/VideoPlayback
@onready var input: LineEdit = $VBoxContainer/UI/LineEdit
@onready var sub_toggle: CheckButton = $VBoxContainer/UI/SubToggle
@onready var sub_track: OptionButton = $VBoxContainer/UI/SubTrack
@onready var sub_parent: Control = $VBoxContainer/Control   
@onready var thebarthingatthebottomofvideoplayers: HSlider = $VBoxContainer/UI/HSlider

var sub_overlay: Control
var cues: Array = []
var styles: Dictionary = {}
var play_res := Vector2(384, 288)
var fonts: Dictionary = {}
var font_cache: Dictionary = {}
var active_labels: Dictionary = {}
var last_rect := Rect2()

var current_video_path := ""
var dl_thread: Thread
var sub_thread: Thread

var scrubbing := false

const DENO_PATH := "~/.deno/bin/deno"


func _ready() -> void:
	input.text_submitted.connect(_on_submitted)
	sub_track.item_selected.connect(_on_track_selected)
	video.video_loaded.connect(_populate_tracks)

	sub_overlay = Control.new()
	sub_overlay.name = "SubOverlay"
	sub_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub_parent.add_child(sub_overlay)
	sub_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sub_overlay.visible = sub_toggle.button_pressed
	sub_toggle.toggled.connect(func(on): sub_overlay.visible = on)
	
	thebarthingatthebottomofvideoplayers.focus_mode = Control.FOCUS_NONE
	thebarthingatthebottomofvideoplayers.step = 0.01
	thebarthingatthebottomofvideoplayers.drag_started.connect(func(): scrubbing = true)
	thebarthingatthebottomofvideoplayers.drag_ended.connect(_on_slider_drag_ended)
	video.video_loaded.connect(_on_video_loaded_seekbar)
	
	input.focus_entered.connect(func(): get_tree().call_group("vr_keyboard", "show_keyboard"))
	input.focus_exited.connect(func(): get_tree().call_group("vr_keyboard", "hide_keyboard"))
	input.text_submitted.connect(func(_t): input.release_focus())



func _on_submitted(text: String) -> void:
	print("submitted: ", text)
	text = text.strip_edges()
	if text == "":
		return
	if _is_youtube(text):
		_load_youtube(text)
	else:
		_load_file(text)


func _is_youtube(url: String) -> bool:
	if not url.begins_with("http"):
		return false
	var host := url.get_slice("://", 1).get_slice("/", 0).get_slice(":", 0).to_lower()
	for h in YTDLP_HOSTS:
		if host == h or host.ends_with("." + h):
			return true
	return false


func _normalize_path(p: String) -> String:
	p = p.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if p.begins_with("res://") or p.begins_with("user://"):
		p = ProjectSettings.globalize_path(p)
	return p



func _open_video(path: String) -> void:
	path = _normalize_path(path)
	current_video_path = path
	_clear_subs()
	if video.is_open():
		video.close()
	video.set_video_path(path)
	video.play()


func _load_file(p: String) -> void:
	p = _normalize_path(p)
	var is_url := p.begins_with("http://") or p.begins_with("https://")
	if not is_url and not FileAccess.file_exists(p):
		push_error("File not found: " + p)
		return
	_open_video(p)


func _load_youtube(url: String) -> void:
	if dl_thread and dl_thread.is_alive():
		print("Download already running, ignoring")
		return
	print("Downloading: ", url)
	dl_thread = Thread.new()
	dl_thread.start(_download.bind(url))


func _download(url: String) -> void:
	var dir := ProjectSettings.globalize_path("user://yt")
	DirAccess.make_dir_recursive_absolute(dir)

	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)

	var deno := _find_deno()
	print("deno path: '", deno, "'")
	
	var args: Array = [
		"--no-playlist", 
		"--remote-components", "ejs:github"
	]
	
	if deno != "":
		args.append_array(["--js-runtimes", "deno:" + deno])
		
	args.append_array([
		"-f", "bestvideo+bestaudio/best",
		"--merge-output-format", "mp4",
		"--write-subs", "--write-auto-subs",
		"--sub-langs", "en.*",
		"--convert-subs", "srt",
		"-o", dir + "/video.%(ext)s",
		url
	])
	print("yt-dlp args: ", args)

	var output := []
	var code := OS.execute("yt-dlp", args, output, true)
	print("yt-dlp exit code: ", code)
	if code != 0:
		print("yt-dlp output: ", "".join(output))
	_downloaded.call_deferred(dir)


func _downloaded(dir: String) -> void:
	dl_thread.wait_to_finish()

	var vid := ""
	var srt := ""
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".srt") and srt == "":
			srt = dir + "/" + f
		elif f.begins_with("video.") and not f.ends_with(".srt") and not f.ends_with(".part"):
			vid = dir + "/" + f

	if vid == "":
		push_error("yt-dlp failed (is it installed and on PATH?)")
		return

	if srt != "":
		var sidecar := vid.get_basename() + ".srt"
		if srt != sidecar:
			DirAccess.copy_absolute(srt, sidecar)

	_open_video(vid)



func _populate_tracks() -> void:
	if video.path != "":
		current_video_path = _normalize_path(video.path)
	_clear_subs()
	fonts.clear()
	font_cache.clear()
	print("current_video_path: ", current_video_path)

	sub_track.clear()
	sub_track.add_item("Off")
	sub_track.set_item_metadata(0, -1)

	if not current_video_path.begins_with("http"):
		var base := current_video_path.get_basename()
		var ext := ""
		if FileAccess.file_exists(base + ".ass"):
			ext = ".ass"
		elif FileAccess.file_exists(base + ".srt"):
			ext = ".srt"
		if ext != "":
			sub_track.add_item("External (%s)" % ext)
			sub_track.set_item_metadata(sub_track.item_count - 1, "sidecar")

	var pos := 0
	for stream_idx in video.subtitle_streams:
		var lang := video.get_stream_language(stream_idx)
		var title := video.get_stream_title(stream_idx)
		var label := "Track %d" % pos
		if lang != "":
			label += " [%s]" % lang
		if title != "":
			label += " - " + title
		sub_track.add_item(label)
		sub_track.set_item_metadata(sub_track.item_count - 1, pos)
		pos += 1

	sub_track.select(0)


func _on_track_selected(i: int) -> void:
	var meta = sub_track.get_item_metadata(i)
	if typeof(meta) == TYPE_INT and meta == -1:
		_clear_subs()
	elif typeof(meta) == TYPE_STRING:
		var base := current_video_path.get_basename()
		if FileAccess.file_exists(base + ".ass"):
			_load_ass_file(base + ".ass")
		elif FileAccess.file_exists(base + ".srt"):
			_load_srt_file(base + ".srt")
	else:
		_extract_embedded(int(meta))


func _extract_embedded(pos: int) -> void:
	if current_video_path == "":
		push_error("No video path known, can't extract subtitles")
		return
	if sub_thread and sub_thread.is_alive():
		return

	var key := current_video_path.md5_text()
	var dir := ProjectSettings.globalize_path("user://subs")
	DirAccess.make_dir_recursive_absolute(dir)
	var out := "%s/%s_%d.ass" % [dir, key, pos]
	var font_dir := ProjectSettings.globalize_path("user://fonts/" + key)

	if FileAccess.file_exists(out):
		_load_fonts(font_dir)
		_load_ass_file(out)
		return

	sub_thread = Thread.new()
	sub_thread.start(_run_extract.bind(current_video_path, pos, out, font_dir))


func _run_extract(src: String, pos: int, out: String, font_dir: String) -> void:
	var ffmpeg_output := []
	var code := OS.execute("ffmpeg", [
		"-y", "-i", src,
		"-map", "0:s:%d" % pos,
		"-c:s", "ass",
		out
	], ffmpeg_output, true)
	if code != 0:
		print("ffmpeg exit code: ", code)
		print("ffmpeg src: ", src)
		print("ffmpeg output: ", "".join(ffmpeg_output))

	if not DirAccess.dir_exists_absolute(font_dir):
		_dump_fonts(src, font_dir)

	_extract_done.call_deferred(code, out, font_dir)


func _dump_fonts(src: String, font_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(font_dir)
	var probe := []
	OS.execute("ffprobe", [
		"-v", "error", "-select_streams", "t",
		"-show_entries", "stream_tags=filename",
		"-of", "csv=p=0", src
	], probe, false)
	if probe.is_empty():
		return

	var names: PackedStringArray = str(probe[0]).split("\n")
	var args: PackedStringArray = ["-y", "-v", "error"]
	var count := 0
	for i in names.size():
		var n := names[i].strip_edges()
		if n == "":
			continue
		args.append("-dump_attachment:t:%d" % i)
		args.append(font_dir + "/" + n.get_file())
		count += 1
	if count == 0:
		return
	args.append("-i")
	args.append(src)
	OS.execute("ffmpeg", args, [], false)


func _extract_done(code: int, out: String, font_dir: String) -> void:
	sub_thread.wait_to_finish()
	if code != 0 or not FileAccess.file_exists(out):
		push_error("Subtitle extraction failed (code %d). Image-based tracks (PGS/DVD) can't be converted." % code)
		_clear_subs()
		return
	_load_fonts(font_dir)
	_load_ass_file(out)


func _load_fonts(font_dir: String) -> void:
	fonts.clear()
	font_cache.clear()
	if not DirAccess.dir_exists_absolute(font_dir):
		return
	for f in DirAccess.get_files_at(font_dir):
		if not (f.get_extension().to_lower() in FONT_EXTS):
			continue
		var ff := FontFile.new()
		if ff.load_dynamic_font(font_dir + "/" + f) != OK:
			continue
		var fam := ff.get_font_name().to_lower()
		if fam == "":
			continue
		if not fonts.has(fam) or ff.get_font_style_name().to_lower() == "regular":
			fonts[fam] = ff
	print("Loaded %d font families from attachments" % fonts.size())



func _g(d: Dictionary, k: String, def: String) -> String:
	return str(d.get(k, def))


func _split_fmt(val: String) -> PackedStringArray:
	var out := PackedStringArray()
	for p in val.split(","):
		out.append(p.strip_edges().to_lower())
	return out


func _default_style() -> Dictionary:
	return {
		"name": "Default", "font": "Arial", "fsize": 20.0,
		"color": Color.WHITE, "outline_color": Color.BLACK,
		"back_color": Color(0, 0, 0, 0.5),
		"bold": false, "italic": false, "underline": false, "strike": false,
		"outline": 2.0, "shadow": 1.0, "alignment": 2,
		"ml": 10, "mr": 10, "mv": 10,
	}


func _ass_color(raw: String) -> Color:
	var s := raw.strip_edges()
	var v := 0
	if s.begins_with("&H") or s.begins_with("&h"):
		s = s.substr(2).trim_suffix("&")
		v = s.hex_to_int() if s != "" else 0
	else:
		v = int(s)
	var r := v & 0xFF
	var g := (v >> 8) & 0xFF
	var b := (v >> 16) & 0xFF
	var a := (v >> 24) & 0xFF
	return Color(r / 255.0, g / 255.0, b / 255.0, 1.0 - a / 255.0)


func _ass_time(s: String) -> float:
	var p := s.strip_edges().split(":")
	if p.size() != 3:
		return 0.0
	return p[0].to_float() * 3600.0 + p[1].to_float() * 60.0 + p[2].to_float()


func _parse_style(val: String, fmt: PackedStringArray) -> Dictionary:
	var parts := val.split(",")
	var d := {}
	for i in mini(parts.size(), fmt.size()):
		d[fmt[i]] = parts[i].strip_edges()
	return {
		"name": _g(d, "name", "Default"),
		"font": _g(d, "fontname", "Arial"),
		"fsize": _g(d, "fontsize", "20").to_float(),
		"color": _ass_color(_g(d, "primarycolour", "&H00FFFFFF")),
		"outline_color": _ass_color(_g(d, "outlinecolour", "&H00000000")),
		"back_color": _ass_color(_g(d, "backcolour", "&H80000000")),
		"bold": _g(d, "bold", "0") != "0",
		"italic": _g(d, "italic", "0") != "0",
		"underline": _g(d, "underline", "0") != "0",
		"strike": _g(d, "strikeout", "0") != "0",
		"outline": _g(d, "outline", "2").to_float(),
		"shadow": _g(d, "shadow", "0").to_float(),
		"alignment": int(_g(d, "alignment", "2")),
		"ml": int(_g(d, "marginl", "10")),
		"mr": int(_g(d, "marginr", "10")),
		"mv": int(_g(d, "marginv", "10")),
	}


func _load_ass_file(path: String) -> void:
	_clear_subs()
	styles.clear()
	play_res = Vector2(0, 0)

	var raw := FileAccess.get_file_as_string(path).replace("\r", "")
	var section := ""
	var style_fmt := PackedStringArray()
	var ev_fmt := PackedStringArray()
	var parsed: Array = []

	for line in raw.split("\n"):
		var l := line.strip_edges()
		if l == "" or l.begins_with(";"):
			continue
		if l.begins_with("[") and l.ends_with("]"):
			section = l.to_lower()
			continue
		var colon := l.find(":")
		if colon < 0:
			continue
		var key := l.substr(0, colon).strip_edges().to_lower()
		var val := l.substr(colon + 1).strip_edges()

		if section == "[script info]":
			if key == "playresx":
				play_res.x = val.to_float()
			elif key == "playresy":
				play_res.y = val.to_float()
		elif section == "[v4+ styles]" or section == "[v4 styles]":
			if key == "format":
				style_fmt = _split_fmt(val)
			elif key == "style":
				var st := _parse_style(val, style_fmt)
				styles[st["name"]] = st
		elif section == "[events]":
			if key == "format":
				ev_fmt = _split_fmt(val)
			elif key == "dialogue":
				var cue := _parse_dialogue(val, ev_fmt)
				if not cue.is_empty():
					parsed.append(cue)

	if play_res.y <= 0:
		play_res.y = 288.0
	if play_res.x <= 0:
		play_res.x = play_res.y * 4.0 / 3.0

	parsed.sort_custom(func(a, b): return a["start"] < b["start"])
	cues = parsed
	print("Loaded %d ASS events, PlayRes %s" % [cues.size(), play_res])


func _parse_dialogue(val: String, fmt: PackedStringArray) -> Dictionary:
	var n := fmt.size()
	if n == 0:
		return {}
	var parts := val.split(",", true, n - 1)
	if parts.size() < n:
		return {}
	var d := {}
	for i in n:
		d[fmt[i]] = parts[i]

	var sname := _g(d, "style", "Default").trim_prefix("*")
	var st: Dictionary = styles.get(sname, styles.get("Default", {}))
	if st.is_empty():
		st = _default_style()

	var eml := int(_g(d, "marginl", "0"))
	var emr := int(_g(d, "marginr", "0"))
	var emv := int(_g(d, "marginv", "0"))

	var cue := {
		"start": _ass_time(_g(d, "start", "0:00:00.00")),
		"end": _ass_time(_g(d, "end", "0:00:00.00")),
		"layer": int(_g(d, "layer", "0")),
		"style": st,
		"ml": eml if eml > 0 else int(st["ml"]),
		"mr": emr if emr > 0 else int(st["mr"]),
		"mv": emv if emv > 0 else int(st["mv"]),
		"an": int(st["alignment"]),
		"pos": [],
		"move": [],
		"fad": [],
		"segments": [],
	}
	_parse_text(_g(d, "text", ""), cue)
	if cue["segments"].is_empty():
		return {}
	return cue


func _base_state(st: Dictionary) -> Dictionary:
	return {
		"font": st["font"], "fsize": st["fsize"],
		"bold": st["bold"], "italic": st["italic"],
		"underline": st["underline"], "strike": st["strike"],
		"color": st["color"], "outline_color": st["outline_color"],
		"drawing": false,
	}


func _flush(segs: Array, buf: String, cur: Dictionary) -> void:
	if buf == "" or cur["drawing"]:
		return
	var s := cur.duplicate()
	s["text"] = buf
	segs.append(s)


func _parse_text(text: String, cue: Dictionary) -> void:
	var base: Dictionary = cue["style"]
	var cur := _base_state(base)
	var segs: Array = []
	var buf := ""
	var i := 0
	var n := text.length()

	while i < n:
		var ch := text[i]
		if ch == "{":
			var close := text.find("}", i)
			if close == -1:
				buf += text.substr(i)
				break
			_flush(segs, buf, cur)
			buf = ""
			_apply_block(text.substr(i + 1, close - i - 1), cur, base, cue)
			i = close + 1
		elif ch == "\\" and i + 1 < n and text[i + 1] == "N":
			buf += "\n"
			i += 2
		elif ch == "\\" and i + 1 < n and text[i + 1] == "n":
			buf += " "
			i += 2
		elif ch == "\\" and i + 1 < n and text[i + 1] == "h":
			buf += "\u00A0"
			i += 2
		else:
			buf += ch
			i += 1

	_flush(segs, buf, cur)
	cue["segments"] = segs


func _apply_block(block: String, cur: Dictionary, base: Dictionary, cue: Dictionary) -> void:
	var pieces := block.split("\\")
	var depth := 0
	for idx in range(1, pieces.size()):
		var p := pieces[idx]
		var inside := depth > 0
		depth += p.count("(") - p.count(")")
		if inside or p == "":
			continue
		_apply_tag(p, cur, base, cue)


func _args(p: String) -> Array:
	var inner := p.substr(p.find("(") + 1).trim_suffix(")")
	var out: Array = []
	for s in inner.split(","):
		out.append(s.strip_edges().to_float())
	return out


func _apply_tag(p: String, cur: Dictionary, base: Dictionary, cue: Dictionary) -> void:
	if p.begins_with("an") and p.length() == 3 and p[2].is_valid_int():
		cue["an"] = int(p.substr(2))
	elif p.begins_with("pos("):
		var a := _args(p)
		if a.size() >= 2:
			cue["pos"] = [a[0], a[1]]
	elif p.begins_with("move("):
		var a := _args(p)
		if a.size() >= 4:
			cue["move"] = a
			cue["pos"] = [a[0], a[1]]
	elif p.begins_with("fade(") or p.begins_with("fad("):
		var a := _args(p)
		if a.size() == 2:
			cue["fad"] = a
	elif p.begins_with("fscx") or p.begins_with("fscy") or p.begins_with("fsp"):
		pass
	elif p.begins_with("fs"):
		var v := p.substr(2).to_float()
		cur["fsize"] = v if v > 0.0 else base["fsize"]
	elif p.begins_with("fn"):
		cur["font"] = p.substr(2) if p.length() > 2 else base["font"]
	elif p.begins_with("1c") or p.begins_with("c"):
		var arg := p.substr(2) if p.begins_with("1c") else p.substr(1)
		if arg.begins_with("&"):
			cur["color"] = _ass_color(arg)
		elif arg == "":
			cur["color"] = base["color"]
	elif p.begins_with("3c"):
		var arg := p.substr(2)
		if arg.begins_with("&"):
			cur["outline_color"] = _ass_color(arg)
	elif p.begins_with("alpha") or p.begins_with("1a"):
		var arg := p.substr(5) if p.begins_with("alpha") else p.substr(2)
		if arg.begins_with("&H"):
			var a := arg.substr(2).trim_suffix("&").hex_to_int()
			var col: Color = cur["color"]
			col.a = 1.0 - a / 255.0
			cur["color"] = col
	elif p.begins_with("bord") or p.begins_with("blur") or p.begins_with("be") or p.begins_with("shad"):
		pass
	elif p.begins_with("b") and p.substr(1).is_valid_int():
		cur["bold"] = int(p.substr(1)) != 0
	elif p.begins_with("i") and p.substr(1).is_valid_int():
		cur["italic"] = int(p.substr(1)) != 0
	elif p.begins_with("u") and p.substr(1).is_valid_int():
		cur["underline"] = int(p.substr(1)) != 0
	elif p.begins_with("s") and p.substr(1).is_valid_int():
		cur["strike"] = int(p.substr(1)) != 0
	elif p.begins_with("p") and p.substr(1).is_valid_int():
		cur["drawing"] = int(p.substr(1)) > 0   
	elif p.begins_with("r"):
		var nb: Dictionary = styles.get(p.substr(1), base)
		cur.clear()
		cur.merge(_base_state(nb))




func _load_srt_file(path: String) -> void:
	_clear_subs()
	styles.clear()
	play_res = Vector2(384, 288)
	var st := _default_style()
	var out: Array = []
	for c in _parse_srt(path):
		var seg := _base_state(st)
		seg["text"] = c["text"]
		out.append({
			"start": c["start"], "end": c["end"], "layer": 0, "style": st,
			"ml": st["ml"], "mr": st["mr"], "mv": st["mv"], "an": 2,
			"pos": [], "move": [], "fad": [], "segments": [seg],
		})
	cues = out
	print("Loaded %d SRT cues" % cues.size())


func _clean_text(s: String) -> String:
	var re := RegEx.new()
	re.compile("<[^>]*>|\\{[^}]*\\}")   
	return re.sub(s, "", true).replace("\r", "").strip_edges()


func _parse_srt(path: String) -> Array:
	var out := []
	var raw := FileAccess.get_file_as_string(path).replace("\r", "")
	for block in raw.split("\n\n", false):
		var lines := block.split("\n", false)
		if lines.size() < 3:
			continue
		var times := lines[1].split(" --> ")
		if times.size() != 2:
			continue
		var text := _clean_text("\n".join(lines.slice(2)))
		if text == "":
			continue
		out.append({
			"start": _ts(times[0]),
			"end": _ts(times[1]),
			"text": text,
		})
	return out


func _ts(s: String) -> float:
	var p := s.strip_edges().split(" ")[0].replace(",", ".").split(":")
	return p[0].to_float() * 3600.0 + p[1].to_float() * 60.0 + p[2].to_float()




func _clear_subs() -> void:
	cues = []
	_free_labels()


func _free_labels() -> void:
	for l in active_labels.values():
		l.queue_free()
	active_labels.clear()



func _video_rect() -> Rect2:
	var area := Rect2(video.position, video.size)
	if area.size.x < 1.0 or area.size.y < 1.0:
		return area
	var tex = null
	if video.video_texture:
		tex = video.video_texture.texture
	if tex == null or tex.get_height() == 0:
		return area
	var aspect := float(tex.get_width()) / float(tex.get_height())
	var fit := area
	if area.size.x / area.size.y > aspect:
		fit.size.x = area.size.y * aspect
		fit.position.x += (area.size.x - fit.size.x) * 0.5
	else:
		fit.size.y = area.size.x / aspect
		fit.position.y += (area.size.y - fit.size.y) * 0.5
	return fit


func _process(_d: float) -> void:
	_update_thebarthingatthebottomofvideoplayers()
	
	if cues.is_empty() or not sub_overlay.visible or not video.is_open():
		return

	var rect := _video_rect()
	if rect.size.x < 2.0 or rect.size.y < 2.0:
		return
	if rect != last_rect:        
		last_rect = rect
		_free_labels()

	var t := video.get_current_playback_position_float()

	
	for id in active_labels.keys():
		var c: Dictionary = cues[id]
		if t < c["start"] or t > c["end"]:
			active_labels[id].queue_free()
			active_labels.erase(id)

	
	for i in cues.size():
		var c: Dictionary = cues[i]
		if c["start"] > t:
			break
		if t <= c["end"] and not active_labels.has(i):
			active_labels[i] = _make_label(c, rect)

	for id in active_labels:
		_update_label(active_labels[id], cues[id], t, rect)


func _get_font(fname: String, bold: bool, italic: bool) -> Font:
	var key := "%s|%s|%s" % [fname.to_lower(), bold, italic]
	if font_cache.has(key):
		return font_cache[key]

	var lk := fname.strip_edges().trim_prefix("@").to_lower()
	var base: Font
	if fonts.has(lk):
		base = fonts[lk]
	else:
		var sf := SystemFont.new()
		sf.font_names = PackedStringArray([fname])
		base = sf

	var f: Font = base
	if bold or italic:
		var fv := FontVariation.new()
		fv.base_font = base
		if bold:
			fv.variation_embolden = 0.7
		if italic:
			fv.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.25, 1), Vector2.ZERO)
		f = fv
	font_cache[key] = f
	return f


func _make_label(c: Dictionary, rect: Rect2) -> RichTextLabel:
	var sx := rect.size.x / play_res.x
	var sy := rect.size.y / play_res.y
	var st: Dictionary = c["style"]
	var an: int = c["an"]
	var col := (an - 1) % 3
	var h_align: HorizontalAlignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][col]
	var has_pos: bool = c["pos"].size() >= 2

	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = false
	rtl.scroll_active = false
	rtl.fit_content = true
	rtl.clip_contents = false
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rtl.z_index = int(c["layer"])
	rtl.autowrap_mode = TextServer.AUTOWRAP_OFF if has_pos else TextServer.AUTOWRAP_WORD_SMART
	rtl.add_theme_constant_override("line_separation", 0)

	if float(st["shadow"]) > 0.0:
		rtl.add_theme_color_override("font_shadow_color", st["back_color"])
		rtl.add_theme_constant_override("shadow_offset_x", int(round(float(st["shadow"]) * sx)))
		rtl.add_theme_constant_override("shadow_offset_y", int(round(float(st["shadow"]) * sy)))

	sub_overlay.add_child(rtl)

	rtl.push_paragraph(h_align)
	for s in c["segments"]:
		var pops := 0
		var font := _get_font(s["font"], s["bold"], s["italic"])
		rtl.push_font(font, maxi(1, int(round(float(s["fsize"]) * sy))))
		pops += 1
		rtl.push_color(s["color"])
		pops += 1
		if float(st["outline"]) > 0.0:
			rtl.push_outline_size(int(round(float(st["outline"]) * sy)))
			rtl.push_outline_color(s["outline_color"])
			pops += 2
		if s["underline"]:
			rtl.push_underline()
			pops += 1
		if s["strike"]:
			rtl.push_strikethrough()
			pops += 1
		rtl.add_text(s["text"])
		for _i in pops:
			rtl.pop()
	rtl.pop()   

	return rtl


func _update_label(rtl: RichTextLabel, c: Dictionary, t: float, rect: Rect2) -> void:
	var sx := rect.size.x / play_res.x
	var sy := rect.size.y / play_res.y
	var an: int = c["an"]
	var col := (an - 1) % 3
	var row := int((an - 1) / 3)            
	var pos: Array = c["pos"]

	if pos.size() >= 2:
		var ms := rtl.get_combined_minimum_size()
		rtl.size = Vector2(maxf(ms.x, rtl.get_content_width()) + 4.0, ms.y)
	else:
		var w := maxf(rect.size.x - float(int(c["ml"]) + int(c["mr"])) * sx, 10.0)
		rtl.size = Vector2(w, rtl.get_combined_minimum_size().y)

	
	var sz := rtl.size
	if pos.size() >= 2:
		var px: float = pos[0]
		var py: float = pos[1]
		var mv: Array = c["move"]
		if mv.size() >= 4:
			var t1 := 0.0
			var t2: float = (float(c["end"]) - float(c["start"])) * 1000.0
			if mv.size() >= 6:
				t1 = mv[4]
				t2 = mv[5]
			var el := (t - float(c["start"])) * 1000.0
			var k := clampf((el - t1) / maxf(t2 - t1, 1.0), 0.0, 1.0)
			px = lerpf(mv[0], mv[2], k)
			py = lerpf(mv[1], mv[3], k)
		var anchor := Vector2(sz.x * col * 0.5, sz.y * (2 - row) * 0.5)
		rtl.position = rect.position + Vector2(px * sx, py * sy) - anchor
	else:
		var x := rect.position.x + float(c["ml"]) * sx
		var mvv := float(c["mv"]) * sy
		var y := 0.0
		if row == 0:
			y = rect.end.y - mvv - sz.y
		elif row == 2:
			y = rect.position.y + mvv
		else:
			y = rect.position.y + (rect.size.y - sz.y) * 0.5
		rtl.position = Vector2(x, y)

	
	var alpha := 1.0
	var fd: Array = c["fad"]
	if fd.size() == 2:
		var since := (t - float(c["start"])) * 1000.0
		var left := (float(c["end"]) - t) * 1000.0
		if fd[0] > 0.0 and since < fd[0]:
			alpha = since / fd[0]
		if fd[1] > 0.0 and left < fd[1]:
			alpha = minf(alpha, left / fd[1])
	rtl.modulate.a = clampf(alpha, 0.0, 1.0)


func _on_button_pressed() -> void:
	if video.is_playing:
		video.pause()
	else:
		video.play()
		
func _on_video_loaded_seekbar() -> void:
	thebarthingatthebottomofvideoplayers.min_value = 0.0
	thebarthingatthebottomofvideoplayers.max_value = video.get_video_length_float()
	thebarthingatthebottomofvideoplayers.set_value_no_signal(0.0)


func _on_slider_drag_ended(value_changed: bool) -> void:
	scrubbing = false
	if not value_changed or not video.is_open():
		return
	var frame := int(thebarthingatthebottomofvideoplayers.value * video.get_video_framerate())
	frame = clampi(frame, 0, maxi(video.get_video_frame_count() - 2, 0))
	video.seek_frame(frame)


func _update_thebarthingatthebottomofvideoplayers() -> void:
	if scrubbing or not video.is_open():
		return
	thebarthingatthebottomofvideoplayers.set_value_no_signal(video.get_current_playback_position_float())


func _get_clipboard() -> String:
	var out := []
	var code := -1

	if OS.get_environment("WAYLAND_DISPLAY") != "":
		code = OS.execute("wl-paste", ["--no-newline"], out, true)

	if code != 0:
		code = OS.execute("xclip", ["-selection", "clipboard", "-o"], out, true)
	if code != 0:
		code = OS.execute("xsel", ["--clipboard", "--output"], out, true)

	if code == 0 and not out.is_empty():
		return str(out[0]).strip_edges()


	return DisplayServer.clipboard_get().strip_edges()


func _on_button_2_pressed() -> void:
	var clip := _get_clipboard()
	print("clipboard: '", clip, "'")
	if clip == "":
		return
	input.text = clip
	input.release_focus()
	_on_submitted(clip)
	
	
func _find_deno() -> String:
	var home := OS.get_environment("HOME")
	var candidates := [
		home + "/.deno/bin/deno",
		home + "/.local/bin/deno",
		"/usr/local/bin/deno",
		"/usr/bin/deno",
		"/opt/homebrew/bin/deno",
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return ""
