"""Foreground + SAM2 region proposals (fast automatic mask generator on low-res logits)."""
import numpy as np, torch, cv2, time
import torch.nn.functional as F

STEP = 22                               # the prompt grid's spacing in pixels (a 896x1200 picture with the figure on 42% of it gets ~890 points)

def foreground_mask(img, thr=7, min_bg=60):
    """Flat-background removal. img uint8 HxWx3. Returns bool fg mask."""
    H, W = img.shape[:2]
    b = np.concatenate([img[:4].reshape(-1, 3), img[-4:].reshape(-1, 3),
                        img[:, :4].reshape(-1, 3), img[:, -4:].reshape(-1, 3)]).astype(np.int16)
    bg = np.median(b, 0)
    d = np.abs(img.astype(np.int16) - bg).max(2)
    bgm = (d <= thr).astype(np.uint8)
    n, cc, st, _ = cv2.connectedComponentsWithStats(bgm, connectivity=4)
    keep = np.zeros(n, bool)
    for i in range(1, n):
        x, y, w, h, a = st[i]
        touches = x == 0 or y == 0 or x + w == W or y + h == H
        if touches or a >= min_bg:
            keep[i] = True
    bgm = keep[cc]
    # one-pixel anti-aliased halo: blended pixels next to bg that are still very close to bg colour
    halo = (d <= thr * 2) & cv2.dilate(bgm.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    bgm = bgm | halo
    return ~bgm, bg


def sam_files(model, revision):
    """(config name, checkpoint path) of a SAM 2 model at one pinned revision. sam2's own from_pretrained cannot pin one (it downloads main)."""
    from huggingface_hub import hf_hub_download
    from sam2.build_sam import HF_MODEL_ID_TO_FILENAMES
    config, ckpt = HF_MODEL_ID_TO_FILENAMES[model]
    return config, hf_hub_download(model, ckpt, revision=revision)


def load_sam(model, revision):
    from sam2.build_sam import build_sam2
    from sam2.sam2_image_predictor import SAM2ImagePredictor
    config, ckpt = sam_files(model, revision)
    return SAM2ImagePredictor(build_sam2(config, ckpt, device="cpu"))


def _stability(logits, thr=0.0, off=1.0):
    inter = (logits > thr + off).flatten(-2).sum(-1).float()
    union = (logits > thr - off).flatten(-2).sum(-1).float()
    return inter / union.clamp(min=1)


def sam_raw(img, fg, predictor, batch=48, log=print):
    """Prompt SAM2 with a grid of single positive points on the foreground.
    Returns (points, low-res logits [N*3,256,256] float16, predicted ious [N*3])."""
    H, W = img.shape[:2]
    t0 = time.time()
    predictor.set_image(img)
    log(f"  sam encode {time.time()-t0:.1f}s")
    ys, xs = np.mgrid[STEP // 2:H:STEP, STEP // 2:W:STEP]
    pts = np.stack([xs.ravel(), ys.ravel()], 1)
    erode = cv2.erode(fg.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)
    pts = pts[erode[pts[:, 1], pts[:, 0]]]
    log(f"  {len(pts)} prompt points")
    model = predictor.model
    feats = predictor._features
    hr = [f[-1].unsqueeze(0) for f in feats["high_res_feats"]]
    emb = feats["image_embed"][-1].unsqueeze(0)
    pe = model.sam_prompt_encoder.get_dense_pe()
    low, ious = [], []
    with torch.inference_mode():
        for i in range(0, len(pts), batch):
            p = torch.tensor(pts[i:i + batch, None, :], dtype=torch.float32)
            p = predictor._transforms.transform_coords(p, normalize=True, orig_hw=(H, W))
            lab = torch.ones(p.shape[0], 1, dtype=torch.int)
            sp, de = model.sam_prompt_encoder(points=(p, lab), boxes=None, masks=None)
            lr, io, _, _ = model.sam_mask_decoder(image_embeddings=emb, image_pe=pe, sparse_prompt_embeddings=sp,
                                                 dense_prompt_embeddings=de, multimask_output=True,
                                                 repeat_image=True, high_res_features=hr)
            low.append(lr.clamp(-32, 32).half()); ious.append(io)
    log(f"  sam decode {time.time()-t0:.1f}s total")
    return pts, torch.cat(low).flatten(0, 1), torch.cat(ious).flatten(0, 1)


def select_regions(raw, img_hw, fg, iou_thr=0.25, stab_thr=0.5, nms_thr=0.75, min_area=60, max_regions=400, log=print):
    """Filter, de-duplicate (greedy NMS) and clean SAM2 masks. Loose thresholds on purpose: SAM2's own
    quality score is low for dark painterly parts (belts, gorget) although the masks are good."""
    H, W = img_hw
    pts, low, ious = raw
    low = low.float()
    stab = _stability(low)
    ok = (ious >= iou_thr) & (stab >= stab_thr)
    low, ious, stab = low[ok], ious[ok], stab[ok]
    m = low > 0
    area = m.flatten(1).sum(1)
    fg_lr = torch.from_numpy(cv2.resize(fg.astype(np.uint8), (256, 256), interpolation=cv2.INTER_AREA) > 0)
    infg = (m & fg_lr).flatten(1).sum(1).float() / area.clamp(min=1)
    keep = (area >= max(3, min_area * 256 * 256 // (H * W))) & (infg > 0.75)
    low, ious, stab, m, area = low[keep], ious[keep], stab[keep], m[keep], area[keep]
    log(f"  {len(m)} masks after quality filter")
    sc = (ious.clamp(min=0.05) * stab)
    order = torch.argsort(-sc)
    m128 = F.interpolate(m[order][:, None].float(), size=(128, 128), mode="area")[:, 0] > 0.5
    flat = m128.flatten(1).float()
    a = flat.sum(1)
    sel = []
    selflat = torch.zeros(len(flat), flat.shape[1]); ns = 0; sela = torch.zeros(len(flat))
    for j in range(len(flat)):
        if a[j] < 1: continue
        if ns:
            inter = selflat[:ns] @ flat[j]
            iou = inter / (sela[:ns] + a[j] - inter)
            if iou.max() > nms_thr: continue
        selflat[ns] = flat[j]; sela[ns] = a[j]; ns += 1
        sel.append(j)
        if ns >= max_regions: break
    idx = order[torch.tensor(sel)]
    log(f"  {len(idx)} masks after NMS")
    out = []
    k3 = np.ones((3, 3), np.uint8)
    for k in idx.tolist():
        up = F.interpolate(low[k][None, None], size=(H, W), mode="bilinear", align_corners=False)[0, 0].numpy()
        mk = ((up > 0) & fg).astype(np.uint8)
        mk = cv2.morphologyEx(mk, cv2.MORPH_OPEN, k3)
        n, cc, st, _ = cv2.connectedComponentsWithStats(mk, connectivity=8)
        if n > 1:
            big = np.zeros(n, bool); big[1:] = st[1:, cv2.CC_STAT_AREA] >= max(25, 0.04 * st[1:, cv2.CC_STAT_AREA].max())
            mk = big[cc]
        mk = mk.astype(bool)
        ar = int(mk.sum())
        if ar < min_area: continue
        out.append(dict(mask=mk, score=float(sc[k]), iou=float(ious[k]), stab=float(stab[k]), area=ar))
    log(f"  {len(out)} regions final")
    return out
