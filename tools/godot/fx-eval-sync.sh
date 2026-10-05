#!/usr/bin/env bash
# copy the eval harness into every generated eval project
cd "$(dirname "$0")/../../godot"
for d in vendor_eval/*/; do cp fx/eval/eval_fx.gd "$d/eval_fx.gd"; done
