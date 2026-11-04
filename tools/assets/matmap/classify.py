"""SigLIP 2 image and text embeddings for the zero-shot material classes."""
import numpy as np, torch
from transformers import AutoModel, AutoProcessor, AutoTokenizer

CLASSES = ["metal", "cloth", "leather", "bone", "skin", "hair"]   # the classifier's columns (matmap.py turns them into the file's label ids)

class Embedder:
    def __init__(self, name, revision):
        self.model = AutoModel.from_pretrained(name, revision=revision).eval()
        self.proc = AutoProcessor.from_pretrained(name, revision=revision)
        self.tok = AutoTokenizer.from_pretrained(name, revision=revision)
        self.scale = self.model.logit_scale.exp().item()

    @torch.inference_mode()
    def text(self, texts):
        t = self.tok([x.lower() for x in texts], padding="max_length", max_length=64, truncation=True, return_tensors="pt")
        te = self.model.get_text_features(**t).pooler_output
        return torch.nn.functional.normalize(te.float(), dim=-1)

    @torch.inference_mode()
    def image(self, imgs, bs=16):
        out = []
        for i in range(0, len(imgs), bs):
            px = self.proc(images=imgs[i:i + bs], return_tensors="pt")["pixel_values"]
            f = self.model.get_image_features(pixel_values=px).pooler_output
            out.append(torch.nn.functional.normalize(f.float(), dim=-1))
        return torch.cat(out)

def class_embeddings(emb, prompts, template):
    """prompts: dict class -> list of descriptions. Mean of normalised prompt embeddings per class."""
    ce = []
    for c in CLASSES:
        te = emb.text([template.format(p) for p in prompts[c]])
        ce.append(torch.nn.functional.normalize(te.mean(0), dim=-1))
    return torch.stack(ce)

def softmax(x, T=1.0):
    x = x / T; x = x - x.max(-1, keepdims=True); e = np.exp(x); return e / e.sum(-1, keepdims=True)
