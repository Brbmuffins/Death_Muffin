class_name DmQaMjpeg
extends RefCounted
## The writer of a clip's frames (client/README.md "Clips and tune"): one JPEG per frame, appended one after the other into a `.mjpeg` file (a motion-JPEG stream: every picture starts with FF D8 and ends
## with FF D9, which ffmpeg reads with `-f mjpeg -framerate 30`). The first picture sets the size: scaled down to WIDTH pixels wide (never up), both sides even (a video needs them), and every later picture
## is brought to that size. Only the QA clip run (main/qa_clips.gd) uses it, and it knows nothing of the game: the pictures are handed to it, so a test feeds it made-up ones.

const WIDTH := 960        ## the widest a clip's picture is
const QUALITY := 0.85     ## the JPEG's quality

var path := ""
var width := 0
var height := 0
var frames := 0           ## pictures written (a picture given for several frames counts each)
var _file: FileAccess


## Opens (replaces) the file. False when it cannot be written.
func open(file: String) -> bool:
	path = file
	_file = FileAccess.open(file, FileAccess.WRITE)
	return _file != null


## One picture, written `times` times (a slow frame still fills its share of the clip's frames). The image is converted and scaled in place. False when it is no picture, the file is not open or the
## encoder gave none.
func add(img: Image, times := 1) -> bool:
	if _file == null or img == null or img.is_empty() or img.is_compressed() or times < 1:
		return false
	if width == 0:
		width = maxi(2, mini(WIDTH, img.get_width()) & ~1)
		height = maxi(2, int(roundf(float(img.get_height()) * float(width) / float(img.get_width()))) & ~1)
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	if img.get_width() != width or img.get_height() != height:
		img.resize(width, height, Image.INTERPOLATE_BILINEAR)
	var jpg := img.save_jpg_to_buffer(QUALITY)
	if jpg.size() < 4 or jpg[0] != 0xFF or jpg[1] != 0xD8 or jpg[jpg.size() - 2] != 0xFF or jpg[jpg.size() - 1] != 0xD9:
		return false
	for _i in times:
		_file.store_buffer(jpg)
	frames += times
	return true


func close() -> void:
	if _file != null:
		_file.close()
		_file = null
