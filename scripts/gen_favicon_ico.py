#!/usr/bin/env python3
"""Regenera priv/static/favicon.ico desde priv/static/favicon.svg.

Rasteriza el SVG con el Chromium de Playwright (respetando filtros/degradados
SVG que los rasterizadores simples no soportan) y empaqueta los tamaños
clásicos con Pillow.

Uso: python3 scripts/gen_favicon_ico.py   (requiere playwright-core en
scripts/screenshot/node_modules y Pillow en el Python del sistema)
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "priv" / "static" / "favicon.svg"
TMP_PNG = Path("/tmp/dran_favicon_256.png")
ICO = ROOT / "priv" / "static" / "favicon.ico"
SIZES = [16, 32, 48, 64, 128, 256]

JS = f"""
const {{ chromium }} = require('playwright-core');
(async () => {{
  const b = await chromium.launch();
  const p = await b.newPage({{ viewport: {{ width: 300, height: 300 }} }});
  await p.setContent(
    '<img id=\\"i\\" src=\\"file://{SVG}\\" ' +
    'style=\\"width:256px;height:256px;display:block\\">'
  );
  await p.waitForSelector('#i');
  await p.locator('#i').screenshot({{ path: '{TMP_PNG}' }});
  await b.close();
  console.log('raster ok');
}})().catch(e => {{ console.error(e); process.exit(1); }});
"""

shot_dir = ROOT / "scripts" / "screenshot"
r = subprocess.run(["node", "-e", JS], cwd=shot_dir, capture_output=True, text=True)
if r.returncode != 0:
    sys.exit(r.stderr or "node/playwright failed")

src = Image.open(TMP_PNG).convert("RGBA")
src.save(ICO, format="ICO", sizes=[(s, s) for s in SIZES])
TMP_PNG.unlink(missing_ok=True)

img = Image.open(ICO)
print("ico ok:", ICO.stat().st_size, "bytes; sizes:", img.info.get("sizes"))

