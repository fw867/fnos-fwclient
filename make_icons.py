"""生成内网穿透应用图标（fnOS 圆角矩形风格）。

产出：
    ICON.PNG                 64x64   包图标
    ICON_256.PNG             256x256 包图标
    app/ui/images/icon_64.png   64x64   入口图标
    app/ui/images/icon_256.png 256x256 入口图标
"""
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "fwclient-app")

BLUE_TOP = (86, 150, 250)
BLUE_BOTTOM = (37, 99, 226)
WHITE = (255, 255, 255, 255)


def font(size):
    """找一个可用的中文字体，找不到就退回默认字体。"""
    candidates = [
        r"C:\Windows\Fonts\msyhbd.ttc",
        r"C:\Windows\Fonts\msyh.ttc",
        r"C:\Windows\Fonts\simhei.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size), top)
    for y in range(size):
        t = y / max(size - 1, 1)
        grad.putpixel(
            (0, y),
            (
                round(top[0] + (bottom[0] - top[0]) * t),
                round(top[1] + (bottom[1] - top[1]) * t),
                round(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    return grad.resize((size, size))


def draw_icon(size, with_glyph=True, supersample=8):
    """返回一张 size x size 的 RGBA 图标。"""
    s = size * supersample
    base = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    radius = round(s * 0.235)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=radius, fill=255)

    gradient = vertical_gradient(s, BLUE_TOP, BLUE_BOTTOM).convert("RGBA")
    base.paste(gradient, (0, 0), mask)

    if with_glyph:
        draw = ImageDraw.Draw(base)
        cx = cy = s / 2

        # 带缺口的圆环：表示被穿透的边界（缺口朝上，正好让箭头穿过）
        ring_r = s * 0.268
        width = max(2, round(s * 0.055))
        box = [cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r]
        draw.arc(box, start=133, end=407, fill=WHITE, width=width)

        # 由内向外的箭头
        aw = max(2, round(s * 0.068))
        top = cy - s * 0.215
        bottom = cy + s * 0.135
        draw.line([(cx, bottom), (cx, top + s * 0.05)], fill=WHITE, width=aw)

        head = s * 0.090
        draw.polygon(
            [
                (cx, top),
                (cx - head * 0.62, top + head * 0.66),
                (cx + head * 0.62, top + head * 0.66),
            ],
            fill=WHITE,
        )

    # 64px 包图标额外加一行小字不合适，这里保持纯图形，保证小尺寸可辨识
    return base.resize((size, size), Image.LANCZOS)


def main():
    outputs = [
        (os.path.join(APP, "ICON.PNG"), 64, True),
        (os.path.join(APP, "ICON_256.PNG"), 256, True),
        (os.path.join(APP, "app", "ui", "images", "icon_64.png"), 64, True),
        (os.path.join(APP, "app", "ui", "images", "icon_256.png"), 256, True),
    ]
    for path, size, glyph in outputs:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img = draw_icon(size, glyph)
        img.save(path, "PNG", optimize=True)
        print(f"{path}  {size}x{size}  {os.path.getsize(path)} bytes")


if __name__ == "__main__":
    main()
