#!/usr/bin/env python3
"""Regenera priv/static/logo.png desde priv/static/favicon.svg.

Rasteriza el SVG con el Chromium de Playwright (respeta filtros y degradados
SVG que los rasterizadores simples no soportan) y guarda un PNG cuadrado.

El PNG se usa como favicon en la app y como logo en el README, para no
depender del render de SVG (que GitHub y algunos navegadores no muestran).

Uso: python3 scripts/gen_logo_png.py   (requiere playwright-core en
scripts/screenshot/node_modules)
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "priv" / "static" / "favicon.svg"
PNG = ROOT / "priv" / "static" / "logo.png"
SIZE = 512

# Inline the SVG markup so the page has no file:// sub-resource to load.
svg_markup = SVG.read_text()
html = (
    '<!doctype html><html><head><meta charset="utf-8">'
    f'<style>html,body{{margin:0;padding:0;background:transparent}}#wrap{{width:{SIZE}px;height:{SIZE}px}}'
    f"#wrap svg{{width:{SIZE}px;height:{SIZE}px;display:block}}</style></head>"
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
""" % (json.dumps(html), json.dumps(str(PNG)), SIZE, SIZE)

shot_dir = ROOT / "scripts" / "screenshot"
r = subprocess.run(["node", "-e", JS], cwd=shot_dir, capture_output=True, text=True)
if r.returncode != 0:
    sys.exit(r.stderr or "node/playwright failed")

print("png ok:", PNG.stat().st_size, "bytes")