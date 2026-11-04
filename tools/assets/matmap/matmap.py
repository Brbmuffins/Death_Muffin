#!/usr/bin/env python
"""python matmap.py <picture.png> <labels.png> [--overlay <file.jpg>] [--report <file.json>]

Material label map for a character concept picture (the figure on a flat light background): which material is each pixel. CPU only, automatic,
no per-picture tuning. <labels.png> is an 8-bit greyscale picture of the same size, each pixel its material id (0 background), so a reader that
takes the red channel as the id (tools/blender/comfy/materials.py) gets it. --overlay: the picture with the labels tinted over it and a legend
(to look at). --report: the ids, each material's share, the models with their revisions and the timing, as JSON.

Label ids, the order of materials.py CLASSES: 1 metal, 2 leather, 3 cloth, 4 skin, 5 hair, 6 bone. (7 wood, 8 stone and 9 gem exist there; this
tool never labels them.) Inside the tool the labels are the classifier's column + 1 (classify.py CLASSES); they become these ids when written.

Method:
  1. foreground = everything that is not the flat background colour (median of the border).
  2. SAM 2.1 (Hiera-small) is prompted with a grid of single points on the foreground; the multi-mask outputs are de-duplicated into
     ~100-200 overlapping part/whole region proposals.
  3. Each region is cut out (outside greyed) and also cropped with context; SigLIP 2 scores both against material text prompts (zero-shot)
     -> class probabilities per region. Low-confidence mixed regions are split by colour and the parts classified the same way.
  4. Per pixel, all regions covering it vote (smaller / more confident regions weigh more).
  5. Left-over foreground takes the label of its most similar neighbour; small specks are merged.
  6. A face detector (YuNet) marks the face ellipse as skin (shadowed eyes/forehead are otherwise read as hair).

Runtime and memory: about 4 minutes and 3.6 GB peak on this VPS (4 threads, nice 15) for an 896x1200 picture. Home: ~/.cache/dm-ops/matmap, or
the env DM_MATMAP_HOME: the Python venv (.venv) and the model cache (hf), both made by setup.sh. The models are pinned to the revisions below.
Licences: SAM 2.1 code and weights Apache-2.0, SigLIP 2 weights Apache-2.0, YuNet (code and weights) MIT.
"""
import os, sys, time, json, argparse, resource

HOME = os.environ.get("DM_MATMAP_HOME") or os.path.expanduser("~/.cache/dm-ops/matmap")
for _v in ("OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "4")
os.environ.setdefault("HF_HOME", os.path.join(HOME, "hf"))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
try:                                    # be gentle on the shared machine even if the caller forgot `nice`
    if os.nice(0) < 15:
        os.nice(15 - os.nice(0))
except OSError:
    pass

import warnings
warnings.filterwarnings("ignore")
import numpy as np, cv2, torch
from PIL import Image, ImageDraw, ImageFont
from huggingface_hub import hf_hub_download, snapshot_download

torch.set_num_threads(int(os.environ["OMP_NUM_THREADS"]))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regions import foreground_mask, sam_files, load_sam, sam_raw, select_regions
from classify import Embedder, class_embeddings, softmax, CLASSES

# the models, each at the commit it was tested at (a model repo's main can change)
SAM_MODEL, SAM_REV = "facebook/sam2.1-hiera-small", "ee5bba1d82bb8749febdf90f45e84b687142ba03"
CLIP_MODEL, CLIP_REV = "google/siglip2-base-patch16-224", "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"
YUNET_MODEL, YUNET_FILE, YUNET_REV = "opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx", "3cc26e7f1014a5ee5d74a42acee58bafc9d0a310"

NAMES = ["background", "metal", "leather", "cloth", "skin", "hair", "bone"]      # the written label ids (materials.py CLASSES order)
TO_ID = np.array([0] + [NAMES.index(c) for c in CLASSES], np.uint8)              # inside label (class column + 1) -> written id
SKIN = CLASSES.index("skin") + 1
N = len(CLASSES)
TINT = {"background": (0, 0, 0), "metal": (0, 200, 255), "leather": (255, 140, 0), "cloth": (150, 80, 255),
        "skin": (255, 70, 160), "hair": (30, 220, 90), "bone": (255, 235, 40)}  # a material keeps its colour whatever its id
COLORS = np.array([TINT[n] for n in NAMES], np.uint8)
N_SPLIT = 60                            # most low-confidence regions tried for a colour split

TEMPLATE = "a close-up of {} in a dark fantasy character painting."
TEMP = 3.0                              # softmax temperature of the region scores
MODES = ("iso", "ctx")                  # each region as a cut-out and as a crop with its surroundings
PROMPTS = {
    "metal": ["metal armor plating", "an iron buckle", "a steel chain", "iron armor with a skull", "a brass bell"],
    "cloth": ["fabric robe", "torn cloth", "a fabric sash with embroidery", "a hooded cloak"],
    "leather": ["a leather belt", "leather straps", "leather boots", "a leather pouch", "a leather bracer on a forearm"],
    "bone": ["bones", "a femur bone", "bone ornaments"],
    "skin": ["a person's face", "bare skin", "a human hand with fingers", "a pale grey hand", "a human neck"],
    "hair": ["a person's hair", "long hair"],
}

def log(*a):
    print(*a, file=sys.stderr, flush=True)

def yunet_file():
    return hf_hub_download(YUNET_MODEL, YUNET_FILE, revision=YUNET_REV)

def fetch_models():
    """Downloads what is missing of the three pinned models into HF_HOME (setup.sh); a run fetches it too. Returns where each is."""
    return {"sam": sam_files(SAM_MODEL, SAM_REV)[1],
            "siglip": snapshot_download(CLIP_MODEL, revision=CLIP_REV, allow_patterns=["*.json", "model.safetensors"]),
            "yunet": yunet_file()}

# ---------------------------------------------------------------- region crops
def crop_region(img, mask, mode, pad=0.2, minside=48, outside=(128, 128, 128)):
    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    cy, cx = (y0 + y1) / 2, (x0 + x1) / 2
    side = max(max(y1 - y0, x1 - x0) * (1 + 2 * pad), minside)
    ya, yb, xa, xb = int(round(cy - side / 2)), int(round(cy + side / 2)), int(round(cx - side / 2)), int(round(cx + side / 2))
    P = int(side) + 2
    ip = cv2.copyMakeBorder(img, P, P, P, P, cv2.BORDER_CONSTANT, value=outside)
    mp = cv2.copyMakeBorder(mask.astype(np.uint8), P, P, P, P, cv2.BORDER_CONSTANT, value=0)
    c = ip[ya + P:yb + P, xa + P:xb + P].copy()
    m = mp[ya + P:yb + P, xa + P:xb + P] > 0
    if mode == "iso":
        c[~m] = outside
    return Image.fromarray(c)

class Classifier:
    def __init__(self):
        self.e = Embedder(CLIP_MODEL, CLIP_REV)
        self.ce = class_embeddings(self.e, PROMPTS, TEMPLATE)

    def probs(self, img, masks):
        if not masks:
            return np.zeros((0, N), np.float32)
        lg = 0
        for mode in MODES:
            f = self.e.image([crop_region(img, m, mode) for m in masks])
            lg = lg + (f @ self.ce.T).numpy() * self.e.scale
        return softmax(lg / len(MODES), TEMP).astype(np.float32)

# ---------------------------------------------------------------- colour split of mixed regions
def split_region(lab_s, mask, min_child=120, min_frac=0.12, min_de=20.0):
    """2-means on smoothed Lab inside the region; returns child masks (empty list if not a clear split)."""
    ys, xs = np.where(mask)
    X = lab_s[ys, xs].astype(np.float32)
    if len(X) < 300:
        return []
    sub = X[np.random.RandomState(0).choice(len(X), min(len(X), 4000), replace=False)]
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 0.5)
    _, _, cen = cv2.kmeans(sub, 2, None, crit, 3, cv2.KMEANS_PP_CENTERS)
    if np.linalg.norm(cen[0] - cen[1]) < min_de:
        return []
    d = ((X[:, None, :] - cen[None]) ** 2).sum(2)
    a = d.argmin(1)
    out = []
    k3 = np.ones((3, 3), np.uint8)
    for c in (0, 1):
        m = np.zeros(mask.shape, np.uint8)
        m[ys[a == c], xs[a == c]] = 1
        m = cv2.morphologyEx(m, cv2.MORPH_OPEN, k3)
        n, cc, st, _ = cv2.connectedComponentsWithStats(m, connectivity=8)
        for i in range(1, n):
            if st[i, cv2.CC_STAT_AREA] >= max(min_child, min_frac * mask.sum()):
                out.append(cc == i)
    return out if len(out) >= 2 else []

# ---------------------------------------------------------------- aggregation
def bbox_of(r):
    if "bbox" not in r:
        ys = np.where(r["mask"].any(1))[0]; xs = np.where(r["mask"].any(0))[0]
        r["bbox"] = (ys[0], ys[-1] + 1, xs[0], xs[-1] + 1)
    return r["bbox"]

def vote(regs, P, shape, beta=0.5, gamma=1.0, kid_w=1.0, n_parent=None):
    """Per-pixel weighted vote of all regions covering the pixel. Weight = area^-beta (smaller, more specific
    regions weigh more) x (0.15 + margin)^gamma (confident regions weigh more); colour-split parts x kid_w."""
    H, W = shape
    S = np.zeros((H, W, N), np.float32)
    for j, (r, p) in enumerate(zip(regs, P)):
        s = np.sort(p)
        margin = float(s[-1] - s[-2])
        w = (r["area"] / 1e4) ** (-beta) * (0.15 + margin) ** gamma
        if n_parent is not None and j >= n_parent:
            w *= kid_w
        y0, y1, x0, x1 = bbox_of(r)
        sub = S[y0:y1, x0:x1]
        sub[r["mask"][y0:y1, x0:x1]] += w * p
    return S

def fill_unlabelled(L, fg, img):
    """Foreground pixels without a label take the label of the most similar neighbouring labelled region."""
    todo = fg & (L == 0)
    if not todo.any():
        return L
    lab = cv2.cvtColor(img, cv2.COLOR_RGB2LAB).astype(np.float32)
    n, cc, st, _ = cv2.connectedComponentsWithStats(todo.astype(np.uint8), connectivity=8)
    L = L.copy()
    k = np.ones((3, 3), np.uint8)
    for i in range(1, n):
        comp = cc == i
        ring = cv2.dilate(comp.astype(np.uint8), k, iterations=3).astype(bool) & ~comp & (L > 0)
        if not ring.any():
            continue
        mc = lab[comp].mean(0)
        best, bd = None, 1e9
        for l in np.unique(L[ring]):
            sel = ring & (L == l)
            d = np.linalg.norm(lab[sel].mean(0) - mc)
            if d < bd:
                best, bd = l, d
        L[comp] = best
    rest = fg & (L == 0)
    if rest.any():                      # enclosed leftovers: nearest labelled pixel
        _, idx = cv2.distanceTransformWithLabels((L > 0).astype(np.uint8) ^ 1, cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
        ys, xs = np.where(L > 0)
        lut = np.zeros(idx.max() + 1, np.uint8)
        lut[idx[ys, xs]] = L[ys, xs]
        L[rest] = lut[idx[rest]]
    return L

def clean(L, fg, min_px=40):
    """Merge tiny label specks into the surrounding label."""
    L = L.copy()
    for l in range(1, N + 1):
        m = (L == l).astype(np.uint8)
        n, cc, st, _ = cv2.connectedComponentsWithStats(m, connectivity=8)
        for i in range(1, n):
            if st[i, cv2.CC_STAT_AREA] < min_px:
                comp = cc == i
                ring = cv2.dilate(comp.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=2).astype(bool) & ~comp & (L > 0) & (L != l)
                if ring.any():
                    L[comp] = np.bincount(L[ring], minlength=N + 1).argmax()
    L[~fg] = 0
    return L

# ---------------------------------------------------------------- face detector (MIT, OpenCV Zoo YuNet)
def detect_faces(img, min_score=0.6):
    """Frontal face boxes (x, y, w, h, score). The painted faces are detected reliably; false hits on skulls
    are dropped by requiring a size comparable to the largest detection."""
    try:
        H, W = img.shape[:2]
        det = cv2.FaceDetectorYN.create(yunet_file(), "", (W, H), 0.5, 0.3, 50)
        _, f = det.detect(cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
    except Exception as ex:             # detector is an optional refinement
        log("  face detector unavailable:", ex)
        return []
    if f is None:
        return []
    f = f[f[:, 14] >= min_score]
    if not len(f):
        return []
    big = (f[:, 2] * f[:, 3]).max()
    return [tuple(float(v) for v in r[:4]) + (float(r[14]),) for r in f if r[2] * r[3] >= 0.5 * big]

def apply_faces(L, fg, faces, sx=0.48, sy=0.50, dy=0.0):
    """Face region (ellipse around each detected face) is skin: shadowed eyes/forehead are otherwise read as hair or hood."""
    out = L.copy()
    for x, y, w, h, _ in faces:
        m = np.zeros(L.shape, np.uint8)
        cv2.ellipse(m, (int(x + w / 2), int(y + h / 2 + dy * h)), (int(w * sx), int(h * sy)), 0, 0, 360, 1, -1)
        out[(m > 0) & fg] = SKIN
    return out

# ---------------------------------------------------------------- overlay
def make_overlay(img, L, alpha=0.55):
    """L holds the written ids."""
    out = img.astype(np.float32).copy()
    col = COLORS[L].astype(np.float32)
    m = (L > 0)[..., None]
    out = np.where(m, (1 - alpha) * out + alpha * col, out)
    # thin outlines between labels
    edge = np.zeros(L.shape, bool)
    edge[:-1] |= L[:-1] != L[1:]
    edge[:, :-1] |= L[:, :-1] != L[:, 1:]
    out[edge & (L > 0)] *= 0.55
    im = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(im)
    try:
        font = ImageFont.load_default(size=18)
    except TypeError:
        font = ImageFont.load_default()
    share = np.bincount(L.ravel(), minlength=N + 1) / L.size
    x0, y0 = 12, 12
    d.rectangle([x0 - 6, y0 - 6, x0 + 190, y0 + (N + 1) * 24 + 6], fill=(20, 20, 20))
    for i in range(1, N + 1):
        y = y0 + (i - 1) * 24
        d.rectangle([x0, y + 2, x0 + 16, y + 18], fill=tuple(int(c) for c in COLORS[i]))
        d.text((x0 + 24, y), f"{i} {NAMES[i]}  {100*share[i]:.1f}%", fill=(240, 240, 240), font=font)
    return im

# ---------------------------------------------------------------- main
def run(path, labels_png, overlay_jpg=None, report_json=None):
    T0 = time.time()
    img = np.array(Image.open(path).convert("RGB"))
    H, W = img.shape[:2]
    timing = {}
    fg, bg = foreground_mask(img)
    log(f"foreground {fg.mean()*100:.1f}% of image, background colour {bg}")

    # --- SAM 2 region proposals
    t = time.time()
    pred = load_sam(SAM_MODEL, SAM_REV)
    raw = sam_raw(img, fg, pred, log=log)
    del pred
    regs = select_regions(raw, (H, W), fg, log=log)
    del raw
    timing["sam_s"] = round(time.time() - t, 1)

    # --- zero-shot material classification of regions
    t = time.time()
    clf = Classifier()
    P = clf.probs(img, [r["mask"] for r in regs])
    timing["classify_s"] = round(time.time() - t, 1)
    log(f"classified {len(regs)} regions in {timing['classify_s']}s")

    # --- split low-confidence mixed regions by colour, classify the parts too
    t = time.time()
    lab_s = cv2.cvtColor(cv2.GaussianBlur(img, (0, 0), 1.5), cv2.COLOR_RGB2LAB)
    marg = np.sort(P, 1)[:, -1] - np.sort(P, 1)[:, -2]
    cand = [i for i in np.argsort(marg) if 400 <= regs[i]["area"] <= 60000 and marg[i] < 0.5][:N_SPLIT]
    kids = []
    for i in cand:
        for m in split_region(lab_s, regs[i]["mask"]):
            kids.append(dict(mask=m, area=int(m.sum()), parent=int(i)))
    if kids:
        Pk = clf.probs(img, [k["mask"] for k in kids])
        regs = regs + kids
        P = np.concatenate([P, Pk])
    timing["split_s"] = round(time.time() - t, 1)
    log(f"{len(kids)} colour-split parts from {len(cand)} low-confidence regions in {timing['split_s']}s")

    # --- vote, fill, clean
    S = vote(regs, P, (H, W), n_parent=len(regs) - len(kids))
    L = np.where(S.sum(2) > 0, S.argmax(2) + 1, 0).astype(np.uint8)
    L[~fg] = 0
    L = fill_unlabelled(L, fg, img)
    L = clean(L, fg)
    faces = detect_faces(img)
    L = apply_faces(L, fg, faces)
    log(f"{len(faces)} face(s) detected")

    L = TO_ID[L]
    Image.fromarray(L).save(labels_png)
    if overlay_jpg:
        make_overlay(img, L).save(overlay_jpg, quality=90)
    seconds, peak_mb = round(time.time() - T0, 1), round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    if report_json:
        share = np.bincount(L.ravel(), minlength=N + 1) / L.size
        fgshare = np.bincount(L[fg].ravel(), minlength=N + 1)[1:] / max(1, fg.sum())
        info = dict(
            picture=os.path.abspath(path), size=[W, H],
            label_ids={str(i): NAMES[i] for i in range(N + 1)},
            pixel_share={NAMES[i]: round(float(share[i]), 5) for i in range(N + 1)},
            foreground_share={NAMES[i + 1]: round(float(fgshare[i]), 5) for i in range(N)},
            models={"sam": f"{SAM_MODEL}@{SAM_REV}", "classifier": f"{CLIP_MODEL}@{CLIP_REV}", "face": f"{YUNET_MODEL}/{YUNET_FILE}@{YUNET_REV}"},
            licences={"sam2 code": "Apache-2.0", "sam2.1 weights": "Apache-2.0", "siglip2 weights": "Apache-2.0", "transformers": "Apache-2.0", "yunet code+weights": "MIT"},
            regions=len(regs), split_parts=len(kids), timing=timing, seconds=seconds, peak_ram_mb=peak_mb,
        )
        json.dump(info, open(report_json, "w"), indent=2)
    log(f"done in {seconds}s, peak RAM {peak_mb} MB")

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Material label map of a character concept picture.")
    ap.add_argument("picture"); ap.add_argument("labels")
    ap.add_argument("--overlay", help="the picture with the labels tinted over it, a .jpg")
    ap.add_argument("--report", help="ids, shares, models and timing, a .json")
    a = ap.parse_args()
    for f in (a.labels, a.overlay, a.report):
        if f:
            os.makedirs(os.path.dirname(os.path.abspath(f)), exist_ok=True)
    run(a.picture, a.labels, a.overlay, a.report)
