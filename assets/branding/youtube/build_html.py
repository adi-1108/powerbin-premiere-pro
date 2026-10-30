#!/usr/bin/env python3
"""Emit the three thumbnail HTML files. Called by make-thumbnails.sh.

Edit HEADLINES to change the copy. The icon is inlined as a data URI so headless
Chrome never has to resolve a subresource.
"""
import base64, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / "assets/branding/youtube"
ICON_B64 = base64.b64encode((ROOT / "assets/branding/PowerBinIcon-1024.png").read_bytes()).decode()

# --- copy -------------------------------------------------------------------
HEADLINES = {
    "a": {"eyebrow": "For Premiere Pro",
          "l1": "STOP", "l2": "REBUILDING", "l3": "YOUR BINS",
          "mark": "PowerBin for Mac"},
    "b": {"l1": "PREMIERE'S", "l2": "MISSING FEATURE",
          "pill": "Save &middot; Reuse &middot; Paste", "mark": "PowerBin"},
    "c": {"eyebrow": "Premiere Pro &middot; macOS",
          "l1": "COPY ONCE.", "l2": "PASTE", "l3": "FOREVER.", "mark": "PowerBin"},
}

CSS = """
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  html,body{width:1280px;height:720px;overflow:hidden}
  body{font-family:"SF Pro Display","Helvetica Neue",Helvetica,Arial,sans-serif;
       -webkit-font-smoothing:antialiased;background:#0E0C14}
  .stage{position:relative;width:1280px;height:720px;overflow:hidden}
  .bg{position:absolute;inset:0;
    background:
      radial-gradient(900px 700px at 22% 45%, rgba(240,169,60,.30), transparent 62%),
      radial-gradient(760px 620px at 88% 88%, rgba(124,77,255,.22), transparent 65%),
      linear-gradient(155deg,#17131F 0%,#0E0C14 55%,#08070C 100%)}
  .grid{position:absolute;inset:0;opacity:.16;
    background-image:linear-gradient(rgba(255,255,255,.10) 1px,transparent 1px),
                     linear-gradient(90deg,rgba(255,255,255,.10) 1px,transparent 1px);
    background-size:64px 64px;
    -webkit-mask-image:radial-gradient(750px 520px at 50% 45%,#000 20%,transparent 78%)}
  .vig{position:absolute;inset:0;box-shadow:inset 0 0 190px 60px rgba(0,0,0,.72)}
  .icon{position:absolute;
    filter:drop-shadow(0 26px 60px rgba(0,0,0,.65)) drop-shadow(0 0 92px rgba(240,169,60,.42))}
  .eyebrow{font-size:27px;font-weight:800;letter-spacing:.24em;color:#F5B54B;text-transform:uppercase}
  h1{color:#fff;font-weight:900;letter-spacing:-.035em;line-height:.87;
     text-shadow:0 6px 34px rgba(0,0,0,.75)}
  .amber{color:#F7BC55}
  .bar{height:9px;border-radius:99px;background:linear-gradient(90deg,#FEDF9B,#F0A93C);
       box-shadow:0 0 34px rgba(240,169,60,.75)}
  .mark{position:absolute;display:flex;align-items:center;gap:14px;color:rgba(255,255,255,.70);
        font-size:25px;font-weight:700}
  .dot{width:15px;height:15px;border-radius:50%;
       background:linear-gradient(180deg,#FEDF9B,#F0A93C);box-shadow:0 0 20px rgba(240,169,60,.95)}
  .pill{display:inline-block;padding:11px 24px;border-radius:99px;background:rgba(240,169,60,.14);
        border:2px solid rgba(240,169,60,.55);color:#F7BC55;font-size:25px;font-weight:800;
        letter-spacing:.12em;text-transform:uppercase}
</style>"""

def icon(style):
    return f'<img class="icon" style="{style}" src="data:image/png;base64,{ICON_B64}">'

def stage(inner):
    return (CSS + '<div class="stage"><div class="bg"></div><div class="grid"></div>'
            + inner + '<div class="vig"></div></div>')

h = HEADLINES
A = stage(
    icon("left:64px;top:150px;width:420px") +
    f'''<div style="position:absolute;left:534px;top:156px;width:648px">
      <div class="eyebrow">{h["a"]["eyebrow"]}</div>
      <h1 style="font-size:104px;margin-top:20px">{h["a"]["l1"]}<br>{h["a"]["l2"]}<br>
        <span class="amber">{h["a"]["l3"]}</span></h1>
      <div class="bar" style="width:250px;margin-top:34px"></div></div>
    <div class="mark" style="left:70px;bottom:52px"><span class="dot"></span>{h["a"]["mark"]}</div>''')

B = stage(
    icon("left:50%;transform:translateX(-50%);top:56px;width:250px") +
    f'''<div style="position:absolute;left:0;right:0;top:326px;text-align:center">
      <h1 style="font-size:122px">{h["b"]["l1"]}<br><span class="amber">{h["b"]["l2"]}</span></h1>
      <div style="margin-top:38px"><span class="pill">{h["b"]["pill"]}</span></div></div>
    <div class="mark" style="left:50%;transform:translateX(-50%);bottom:62px">
      <span class="dot"></span>{h["b"]["mark"]}</div>''')

C = stage(
    '''<div style="position:absolute;right:-140px;top:-120px;width:820px;height:960px;
        background:linear-gradient(180deg,rgba(254,223,155,.16),rgba(240,169,60,.05));
        transform:rotate(14deg);border-radius:80px"></div>''' +
    icon("right:74px;top:196px;width:360px") +
    f'''<div style="position:absolute;left:74px;top:158px;width:700px">
      <div class="eyebrow">{h["c"]["eyebrow"]}</div>
      <h1 style="font-size:118px;margin-top:22px">{h["c"]["l1"]}<br>
        <span class="amber">{h["c"]["l2"]}<br>{h["c"]["l3"]}</span></h1>
      <div class="bar" style="width:300px;margin-top:34px"></div></div>
    <div class="mark" style="left:78px;bottom:44px"><span class="dot"></span>{h["c"]["mark"]}</div>''')

for name, html in (("a", A), ("b", B), ("c", C)):
    (OUT / f"_thumb-{name}.html").write_text(html)
