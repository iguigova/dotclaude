#!/usr/bin/env python3
"""gist.py — render a one-page 16:9 executive summary as a PDF.

  gist.py CONTENT.json OUT.pdf
  gist.py --self-test        # renders into a temp dir

The page is fixed: a title and subtitle over an accent rule, a strip of
up to five headline metrics, three panels of bullets, and a dark
takeaway bar. CONTENT.json fills it:

  {"title": "...", "subtitle": "...",
   "metrics": [["12x", "daily merges"], ...],          # 1 to 5
   "columns": [{"title": "...", "bullets": ["..."]},   # exactly 3
               ...],
   "takeaway": "...", "note": "..."}                   # note optional

Bullets, the takeaway and the note take ReportLab inline markup: <b>,
<i>, <font color='#...'>; a literal & or < is written &amp; or &lt;.
The note follows the takeaway in a muted colour: sources, caveats.

Nothing shrinks to fit. A title, subtitle or metric wider than its
slot, a panel or takeaway that overflows, or a missing field exits 1
naming the part, and no file is written.
"""
import json
import sys
import tempfile
from pathlib import Path

from reportlab.lib.colors import HexColor
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen import canvas
from reportlab.platypus import Frame, Paragraph

from tap import Tap

W, H = 960, 540  # 16:9 at 72 pt/in
MARGIN = 40
GAP = 14
PANEL_TOP, PANEL_BOTTOM = H - 158, 92
METRIC_PAD = 8

INK = HexColor("#1F2328")
MUTED = HexColor("#57606A")
ACCENT = HexColor("#C15F3C")
PANEL = HexColor("#F6F4EF")
PAPER = HexColor("#FFFFFF")
NOTE_COLOR = "#C9CCD1"

HEAD = ParagraphStyle("head", fontName="Helvetica-Bold", fontSize=14,
                      textColor=ACCENT, leading=18, spaceAfter=8)
BODY = ParagraphStyle("body", fontName="Helvetica", fontSize=12,
                      textColor=INK, leading=16, leftIndent=10,
                      bulletIndent=0, spaceAfter=8)
TAKE = ParagraphStyle("take", fontName="Helvetica", fontSize=11,
                      textColor=PAPER, leading=14.5)


class SummaryError(Exception):
    """The content does not fit the page, or a field is missing."""


# ── Content ──────────────────────────────────────────────────────────

def load(path):
    content = json.loads(Path(path).read_text())
    check_shape(content)
    return content


def check_shape(content):
    for key in ("title", "subtitle", "metrics", "columns", "takeaway"):
        if not content.get(key):
            raise SummaryError(f"missing field: {key}")
    if not 1 <= len(content["metrics"]) <= 5:
        raise SummaryError("metrics: 1 to 5 entries")
    if len(content["columns"]) != 3:
        raise SummaryError("columns: exactly 3 entries")


# ── Drawing ──────────────────────────────────────────────────────────

def fit_line(text, font, size, width, part):
    if stringWidth(text, font, size) > width:
        raise SummaryError(f"{part} is wider than the page: {text!r}")


def fill(frame, story, c, part):
    frame.addFromList(story, c)
    if story:
        raise SummaryError(f"{part} overflowed")


def draw_title(c, title, subtitle):
    fit_line(title, "Helvetica-Bold", 25, W - 2 * MARGIN, "title")
    fit_line(subtitle, "Helvetica", 12, W - 2 * MARGIN, "subtitle")
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 25)
    c.drawString(MARGIN, H - 58, title)
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 12)
    c.drawString(MARGIN, H - 80, subtitle)
    c.setStrokeColor(ACCENT)
    c.setLineWidth(2)
    c.line(MARGIN, H - 94, W - MARGIN, H - 94)


def draw_metric(c, x, slot, value, label):
    fit_line(value, "Helvetica-Bold", 24, slot - METRIC_PAD, f"metric {value}")
    fit_line(label, "Helvetica", 9.5, slot - METRIC_PAD, f"metric label {label}")
    c.setFillColor(ACCENT)
    c.setFont("Helvetica-Bold", 24)
    c.drawString(x, H - 126, value)
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 9.5)
    c.drawString(x, H - 140, label)


def draw_metrics(c, metrics):
    slot = (W - 2 * MARGIN) / len(metrics)
    for i, (value, label) in enumerate(metrics):
        draw_metric(c, MARGIN + i * slot, slot, value, label)


def draw_column(c, x, width, column):
    height = PANEL_TOP - PANEL_BOTTOM
    c.setFillColor(PANEL)
    c.roundRect(x, PANEL_BOTTOM, width, height, 6, stroke=0, fill=1)
    story = [Paragraph(column["title"], HEAD)] + [
        Paragraph(b, BODY, bulletText="•") for b in column["bullets"]]
    frame = Frame(x + 12, PANEL_BOTTOM + 8, width - 24, height - 16,
                  leftPadding=0, rightPadding=0, topPadding=4,
                  bottomPadding=0)
    fill(frame, story, c, f"panel {column['title']!r}")


def draw_columns(c, columns):
    width = (W - 2 * MARGIN - 2 * GAP) / 3
    for i, column in enumerate(columns):
        draw_column(c, MARGIN + i * (width + GAP), width, column)


def takeaway_markup(takeaway, note):
    tail = f" <font color='{NOTE_COLOR}'>{note}</font>" if note else ""
    return f"{takeaway}{tail}"


def draw_takeaway(c, takeaway, note):
    c.setFillColor(INK)
    c.roundRect(MARGIN, 28, W - 2 * MARGIN, 52, 6, stroke=0, fill=1)
    frame = Frame(MARGIN + 14, 30, W - 2 * MARGIN - 28, 48,
                  leftPadding=0, rightPadding=0, topPadding=6,
                  bottomPadding=0)
    story = [Paragraph(takeaway_markup(takeaway, note), TAKE)]
    fill(frame, story, c, "takeaway")


def render(content, out):
    c = canvas.Canvas(str(out), pagesize=(W, H))
    c.setTitle(content["title"])
    c.setFillColor(PAPER)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    draw_title(c, content["title"], content["subtitle"])
    draw_metrics(c, content["metrics"])
    draw_columns(c, content["columns"])
    draw_takeaway(c, content["takeaway"], content.get("note"))
    c.showPage()
    c.save()


# ── Self-test ────────────────────────────────────────────────────────

SAMPLE = {
    "title": "A short title",
    "subtitle": "Executive summary of a sample source (1 Jan 2026)",
    "metrics": [["12x", "a ratio"], ["+25%", "a change"]],
    "columns": [{"title": f"Panel {n}", "bullets": ["<b>Bold</b>: text."]}
                for n in range(3)],
    "takeaway": "<b>Takeaway:</b> one line.",
    "note": "Figures are self-reported.",
}


def refused(content, out):
    try:
        check_shape(content)
        render(content, out)
    except SummaryError as e:
        return str(e)
    return "NOT REFUSED"


def self_test():
    t = Tap()

    def check(desc, ok):
        t.check(ok, desc)

    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "s.pdf"
        render(SAMPLE, out)
        check("the sample renders a PDF", out.read_bytes()[:4] == b"%PDF")

        bad = Path(d) / "bad.pdf"
        long = dict(SAMPLE, title="word " * 40)
        check("a long title is refused", "title" in refused(long, bad))
        full = dict(SAMPLE, columns=[
            {"title": "Full", "bullets": ["many words here " * 12] * 8}] * 3)
        check("an overflowing panel is named",
              "panel 'Full' overflowed" in refused(full, bad))
        two = dict(SAMPLE, columns=SAMPLE["columns"][:2])
        check("two panels are refused", "exactly 3" in refused(two, bad))
        none = {k: v for k, v in SAMPLE.items() if k != "takeaway"}
        check("a missing field is named",
              "missing field: takeaway" in refused(none, bad))
        check("a refused summary writes no file", not bad.exists())
    return t.end()


def main(args):
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if args[:1] == ["--self-test"]:
        return self_test()
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        render(load(args[0]), args[1])
    except SummaryError as e:
        print(f"gist: {e}", file=sys.stderr)
        return 1
    print(args[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
