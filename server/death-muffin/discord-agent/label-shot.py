#!/usr/bin/env python3
"""Burn "BRANCH PREVIEW . not live . <branch>" into the raw PNGs a sandboxed Godot run wrote to <worktree>/.dm-shots/.raw/ and publish them as
<worktree>/.dm-shots/<name>.png. Runs OUTSIDE the sandbox on files the branch's code may have written, so it trusts nothing: every path is
reached through directory file descriptors with O_NOFOLLOW, only regular PNG files with sane dimensions are read, names are re-validated,
and the output is written to a temp name and renamed. Usage: label-shot.py <worktree> [branch]. Exit 0 = every raw image was labelled."""
import io, os, re, stat, sys
from PIL import Image, ImageDraw, ImageFont

MAX_BYTES = 12 * 1024 * 1024
MAX_PIXELS = 4096 * 4096
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}\.png$")
FONTS = ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"]


def opendir(parent_fd, name):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)


def label(img, branch):
    img = img.convert("RGB")
    text = "BRANCH PREVIEW · not live" + (" · " + branch if branch else "")
    size = max(12, round(img.width / 80))
    font = None
    for f in FONTS:
        try:
            font = ImageFont.truetype(f, size)
            break
        except OSError:
            pass
    if font is None:
        font = ImageFont.load_default(size)
    d = ImageDraw.Draw(img)
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    pad = size // 2
    x, y = 8, 8
    d.rounded_rectangle((x, y, x + (r - l) + 2 * pad, y + (b - t) + pad * 2), radius=(b - t) // 2 + pad, fill=(0x4C, 0x1D, 0x95))
    d.text((x + pad - l, y + pad - t), text, font=font, fill=(255, 255, 255))
    return img


def main():
    top = sys.argv[1]
    branch = re.sub(r"[^A-Za-z0-9._/-]", "", sys.argv[2])[:60] if len(sys.argv) > 2 else ""
    try:
        wt = os.open(top, os.O_RDONLY | os.O_DIRECTORY)
        shots = opendir(wt, ".dm-shots")
        raw = opendir(shots, ".raw")
    except OSError as e:
        print("label-shot: no raw shots (%s)" % e.strerror)
        return 0
    bad = 0
    for name in sorted(os.listdir(raw)):
        try:
            if not NAME.match(name):
                raise ValueError("odd file name")
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=raw)
            with os.fdopen(fd, "rb") as fh:
                st = os.fstat(fh.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_BYTES:
                    raise ValueError("not a regular file or too big")
                data = fh.read()
            img = Image.open(io.BytesIO(data))
            if img.format != "PNG":
                raise ValueError("not a PNG")
            out = io.BytesIO()
            label(img, branch).save(out, "PNG", optimize=True)
            tmp = "." + name + ".tmp"
            ofd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=shots)
            with os.fdopen(ofd, "wb") as oh:
                oh.write(out.getvalue())
            os.rename(tmp, name, src_dir_fd=shots, dst_dir_fd=shots)
            print("shot .dm-shots/%s" % name)
        except Exception as e:  # one bad image never publishes unlabelled and never stops the others
            bad += 1
            print("label-shot: skipped %s (%s)" % (name, e))
            try:
                os.unlink(name, dir_fd=raw)
            except OSError:
                pass
    return 1 if bad else 0


sys.exit(main())
