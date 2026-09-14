#!/usr/bin/env python3
"""Regenera priv/static/favicon.ico desde priv/static/favicon.svg.

Rasteriza el SVG con el Chromium de Playwright (respetando filtros/degradados
SVG que los rasterizadores simples no soportan) y empaqueta los tamaños
clásicos con Pillow. El fondo queda transparente, igual que el PNG.

Uso: python3 scripts/gen_favicon_ico.py   (requiere playwright-core en
scripts/screenshot/node_modules y Pillow en el Python del sistema)
"""
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "priv" / "static" / "favicon.svg"
TMP_PNG = Path("/tmp/dran_favicon_256.png")
ICO = ROOT / "priv" / "static" / "favicon.ico"
SIZES = [16, 32, 48, 64, 128, 256]
RENDER = 256

# Inline the SVG markup so the page has no file:// sub-resource to load.
svg_markup = SVG.read_text()
html = (
    '<!doctype html><html><head><meta charset="utf-8">'
    f'<style>html,body{{margin:0;padding:0;background:transparent}}#wrap{{width:{RENDER}px;height:{RENDER}px}}'
    f"#wrap svg{{width:{RENDER}px;height:{RENDER}px;display:block}}</style></head>"
    f'<body><div id="wrap">{svg_markup}</div></body></html>'
)

JS = """
const { chromium } = require('playwright-core');
const html = %s;
const out = %s;
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: %d, height: %d } });
  await p.setContent(html, { waitUntil: 'load' });
  await p.locator('#wrap').screenshot({ path: out, omitBackground: true });
  await b.close();
  console.log('raster ok');
})().catch(e => { console.error(e); process.exit(1); });
""" % (json.dumps(html), json.dumps(str(TMP_PNG)), RENDER, RENDER)

shot_dir = ROOT / "scripts" / "screenshot"
r = subprocess.run(["node", "-e", JS], cwd=shot_dir, capture_output=True, text=True)
if r.returncode != 0:
    sys.exit(r.stderr or "node/playwright failed")

src = Image.open(TMP_PNG).convert("RGBA")
src.save(ICO, format="ICO", sizes=[(s, s) for s in SIZES])
TMP_PNG.unlink(missing_ok=True)

img = Image.open(ICO)
print("ico ok:", ICO.stat().st_size, "bytes; sizes:", img.info.get("sizes"))