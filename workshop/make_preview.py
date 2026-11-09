"""Generate ModPreview.jpg for the StackFix workshop item.

Same visual language as the SaveFix preview (dark gradient, amber rule,
mono code panel) so the two tool items read as a family.

    python make_preview.py [out.jpg]

Needs Pillow - run it with the DSH python that has it:
    C:\\Users\\KYOUKA\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

W = H = 1024
BG_TOP = (14, 17, 22)
BG_BOTTOM = (22, 27, 34)
FG = (230, 237, 243)
MUTED = (125, 138, 152)
ACCENT = (255, 176, 0)      # XCOM-ish amber
GREEN = (63, 185, 80)
RED = (248, 81, 73)
PANEL = (13, 17, 23)

FONTS = r"C:\Windows\Fonts"


def font(name, size):
    for candidate in (name, "segoeui.ttf"):
        path = os.path.join(FONTS, candidate)
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "ModPreview.jpg"

    img = Image.new("RGB", (W, H), BG_TOP)
    d = ImageDraw.Draw(img)

    # Vertical gradient background.
    for y in range(H):
        t = y / (H - 1)
        c = tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
        d.line([(0, y), (W, y)], fill=c)

    # Amber rule at the very top.
    d.rectangle([0, 0, W, 6], fill=ACCENT)

    f_kicker = font("segoeuib.ttf", 26)
    f_title = font("segoeuib.ttf", 104)
    f_sub = font("segoeuib.ttf", 46)
    f_body = font("segoeui.ttf", 30)
    f_mono = font("consola.ttf", 27)
    f_mono_b = font("consolab.ttf", 27)
    f_small = font("segoeui.ttf", 24)

    def center(text, y, f, fill, x=W // 2):
        bbox = d.textbbox((0, 0), text, font=f)
        tw = bbox[2] - bbox[0]
        d.text((x - tw // 2, y), text, font=f, fill=fill)

    center("XCOM 2 · WAR OF THE CHOSEN", 79, f_kicker, MUTED)
    center("STACKFIX", 145, f_title, FG)
    center("Stop the 0xC00000FD crash", 290, f_sub, ACCENT)

    center("Heavily modded battle asks for 10 MB of stack at once;", 400, f_body, FG)
    center("the default thread stack is only ~4.77 MiB. It overflows.", 442, f_body, FG)

    # Two "game message" chips like the SaveFix preview.
    def chip(x, y, w, label):
        d.rounded_rectangle([x, y, x + w, y + 44], radius=8, fill=PANEL, outline=RED, width=2)
        bbox = d.textbbox((0, 0), label, font=f_small)
        tw = bbox[2] - bbox[0]
        d.text((x + w // 2 - tw // 2, y + 10), label, font=f_small, fill=RED)

    chip(288, 508, 230, "STACK OVERFLOW")
    chip(546, 508, 230, "0xC00000FD")

    # Code panel: the one field that changes.
    panel_y = 588
    d.rounded_rectangle([140, panel_y, 884, panel_y + 140], radius=10, fill=PANEL)
    d.text((170, panel_y + 18), "SizeOfStackReserve", font=f_mono_b, fill=MUTED)
    d.text((246, panel_y + 56), "4.77 MiB", font=f_mono, fill=RED)
    d.text((575, panel_y + 56), "->", font=f_mono, fill=MUTED)
    d.text((640, panel_y + 56), "32 MiB", font=f_mono, fill=GREEN)
    d.text((170, panel_y + 100), "8 bytes of the PE header. Commit untouched.", font=f_mono, fill=MUTED)

    center("1 field of XCom2.exe changes. The game itself is never touched.", 760, f_body, FG)

    center("Auto-detects your install · works on base game and WotC", 868, f_small, MUTED)
    center("Backs up the original · restore rewrites only those 8 bytes", 908, f_small, MUTED)

    center("Verified live: two full battles, zero crashes", 952, f_small, GREEN)

    img.save(out, "JPEG", quality=90)
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
