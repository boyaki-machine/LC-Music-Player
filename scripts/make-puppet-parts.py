"""教育番組（パペット）の絵を部品（髪・目のシール・胴・左右の腕など）に切り分け、アプリのリソースに書き出す。

使い方: uv run --with pillow --with numpy python -I scripts/make-puppet-parts.py
入力は assets/puppet-show/puppets.png（1934×596、生成AIの原画）。座標はすべてこの絵の画素で書く。
出力は Sources/PlayerUI/Players/Kyouiku_Bangumi/Art/<キャラクタ>/*.png と characters.json。
"""
import json
import pathlib

import numpy as np
from PIL import Image, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/puppet-show/puppets.png"
OUTPUT = ROOT / "Sources/PlayerUI/Players/Kyouiku_Bangumi/Art"

# 眼鏡の男の子（3番目）。境界はすべてこの子の絵に合わせて目で測った値。
BOY = dict(
    box=(982, 0, 1396, 596),
    head_cx=1187, head_chin_cy=300, head_chin_rx=134, head_chin_ry=79,
    # 絵の唇（上の線と下の線の放物線）。肌で塗りつぶし、球に水平の切れ込みを入れる
    mouth_cx=1186, mouth_top=309, mouth_bottom=339, mouth_corner_y=324, mouth_corner_dx=108,
    cut_y=322,
    # 袖ごと腕にする（袖と胴の縫い目の線）
    arm_l=((1090, 398), (1095, 497)),
    arm_r=((1281, 400), (1276, 497)),
    pivot_arm_l=(1090, 425), pivot_arm_r=(1281, 427),
    pivot_neck=(1187, 372),
    head_center=(1187, 238), head_radius=(127, 137, 124), hair_scale=1.1, sideburn_y=262,
    decal_box=(1068, 200, 1308, 292),
    eyes=((1121, 250), (1248, 250)),
)


# ほかの3人。頭の楕円・目・切れ込みは自動の測定（肌の連結成分と黒目）から、袖の縫い目は目で測った値。
# hair_ymax：髪とみなす下端。tail：顔の横から下へ垂れる髪（ツインテール・ポニーテール）の範囲
OTHERS = {
    "spiky": dict(
        box=(19, 0, 379, 596), head_center=(200, 207), head_radius=(120, 130, 117), hair_scale=1.1,
        sideburn_y=240, cut_y=284, eyes=((131, 219), (257, 221)), cap_ymax=205, strand_ymax=246, hair_ymax=300, tail=None,
        arm_l=((106, 328), (81, 404)), arm_r=((294, 328), (319, 406)),
        pivot_arm_l=(96, 350), pivot_arm_r=(304, 352), pivot_neck=(200, 345), hip_y=560),
    "twin": dict(
        box=(487, 0, 829, 596), head_center=(657, 258), head_radius=(110, 119, 108), hair_scale=1.1,
        sideburn_y=290, cut_y=332, eyes=((594, 269), (710, 271)), cap_ymax=246, hair_ymax=352,
        tail=(0, 2000, 352),
        arm_l=((568, 375), (553, 440)), arm_r=((746, 375), (762, 441)),
        pivot_arm_l=(560, 395), pivot_arm_r=(752, 398), pivot_neck=(657, 400), hip_y=560),
    "pony": dict(
        box=(1484, 0, 1846, 596), head_center=(1651, 218), head_radius=(108, 117, 106), hair_scale=1.1,
        sideburn_y=262, cut_y=290, eyes=((1588, 228), (1705, 231)), cap_ymax=205, hair_ymax=300,
        tail=(1740, 1846, 425),
        arm_l=((1559, 325), (1550, 425)), arm_r=((1759, 325), (1768, 400)),
        pivot_arm_l=(1553, 355), pivot_arm_r=(1764, 355), pivot_neck=(1651, 355), hip_y=560),
}


def build_other(sheet, p):
    """肌の球に貼る目のシール、髪の球の前面の絵、球からはみ出す髪の板、胴、左右の腕を作る。"""
    x0, y0, x1, y1 = p["box"]
    img = np.array(sheet.crop(p["box"]).convert("RGBA")).astype(np.float32)
    h, w = img.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w]
    X = xs + x0
    Y = ys + y0
    a8 = img[:, :, 3]
    alpha = a8 > 8
    r, g, b = img[:, :, 0], img[:, :, 1], img[:, :, 2]
    lum = (r + g + b) / 3
    sat = img[:, :, :3].max(axis=2) - img[:, :, :3].min(axis=2)
    # ピンクのリボンは肌に近い色なので、青が緑より強いことで肌と見分け、髪の側に入れる
    ribbon = (b - g > 8) & (r - g > 30) & (Y < p["head_center"][1] - p["head_radius"][1] * 0.6)
    skinlike = (r - b > 30) & (r > 140) & (r - g > 15) & ~ribbon
    (hcx, hcy), (hrx, hry, _) = p["head_center"], p["head_radius"]
    (exl, eyl), (exr, eyr) = p["eyes"]

    # 頭の跡（胴から外す範囲）：顔の楕円を少し広げ、顎の下まで
    ex_ = (X - hcx) / (hrx * 1.07)
    head2d = alpha & ((ex_ * ex_ + ((Y - hcy) / (hry * 1.16)) ** 2) < 1)

    # 目のシール：両目を囲む箱（縁をぼかす）。まつげも入る
    gx0, gy0, gx1, gy1 = exl - 24, min(eyl, eyr) - 22, exr + 24, max(eyl, eyr) + 18
    u = np.clip(np.minimum(X - gx0, gx1 - X) / 10.0, 0, 1)
    v = np.clip(np.minimum(Y - gy0, gy1 - Y) / 9.0, 0, 1)
    in_decal = (u > 0) & (v > 0)

    # 髪：肌でも白いシャツでもない画素（暗い髪とリボン）。下端は hair_ymax、垂れる髪は tail の範囲まで
    not_shirt = (lum < 150) | ((sat > 45) & ~skinlike)
    lim = Y < p["hair_ymax"]
    if p["tail"]:
        tx0, tx1, tymax = p["tail"]
        lim |= (X >= tx0) & (X <= tx1) & (Y < tymax) & (np.abs(X - hcx) > hrx * 0.8)
    hair = alpha & ~skinlike & not_shirt & lim & ~(in_decal & (Y > gy0 + 6))
    hm = Image.fromarray((hair * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(5))
    hair = (np.array(hm) > 128) & alpha
    skin_px = alpha & skinlike & (np.abs(X - hcx) < hrx * 0.6) & (Y > max(eyl, eyr) + 15) & (Y < p["cut_y"] - 30)
    skin = np.median(img[skin_px][:, :3], axis=0)
    hair_col = np.median(img[hair & (lum < 110)][:, :3], axis=0)

    # 髪の球の前面：前髪の下端（cap_ymax まで）、横はもみあげの高さまで
    s_hair = p["hair_scale"]
    ex = (X - hcx) / (hrx * s_hair)
    ell = ex * ex + ((Y - hcy) / (hry * s_hair)) ** 2 < 1.12
    # 前髪は cap_ymax まで、横（縁に近い列）はもみあげの高さまで、実際の髪の下端に合わせる
    rim = np.abs((X - hcx) / (hrx * s_hair))
    k = np.clip((rim - 0.7) / 0.25, 0, 1)
    ylim = p["cap_ymax"] + (p["sideburn_y"] - p["cap_ymax"]) * k * k * (3 - 2 * k)   # 縁へ向かってなだらかに下げる
    capped = hair & (Y <= ylim)
    fringe = np.full(w, -1.0)
    for xx in range(w):
        col = np.where(capped[:, xx])[0]
        if len(col):
            fringe[xx] = col.max() + y0
    # 前髪の毛先：下端より下へ垂れる房も、髪の画素だけを残す（切れて見えないように）
    cap = ell & ((Y <= fringe[None, :]) | (hair & (Y <= p.get("strand_ymax", p["cap_ymax"])) & (rim < 0.78)))
    cap_img = np.zeros_like(img)
    cap_img[:, :, :3] = hair_col
    solid = hair & (a8 > 200)
    cap_img[solid, :3] = img[solid, :3]
    soft = np.array(Image.fromarray((cap * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))).astype(np.float32)
    cap_img[:, :, 3] = np.maximum(soft, np.where(cap & ((Y <= fringe[None, :] - 3) | hair), 255, 0))

    # 球からはみ出す髪（とがった毛先・ツインテール・ポニーテール・リボン）は板にする
    # 顔の輪郭線や口の線は入れない：顔の楕円の内側を外し、細い線は開閉の処理で消す
    face = ((X - hcx) / (hrx * 1.04)) ** 2 + ((Y - hcy) / (hry * 1.06)) ** 2 < 1
    # 球の縁と板のあいだにすき間ができないよう、球の内側へ少し重ねる
    inner = ex * ex + ((Y - hcy) / (hry * s_hair)) ** 2 < 0.9
    extra = hair & ~(cap & inner) & ~face
    em = Image.fromarray((extra * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(7))
    extra = (np.array(em) > 128) & hair & ~(cap & inner) & ~face
    below_ok = Y < p["cut_y"]
    if p["tail"]:
        below_ok |= (X >= tx0) & (X <= tx1) & (Y < tymax)
    extra &= below_ok
    # 縁の半透明の画素は白が混ざっているので、髪の色に置き換える（拡大や回転で白い縁が出ないように）
    extra_img = img.copy()
    extra_img[(a8 < 230) | ~extra, :3] = hair_col
    extra_img[:, :, 3] = np.where(extra & (a8 > 60), np.maximum(a8, 200), 0)

    # 目のシールは黒目とまつげだけ。まわりの肌（影の入った元の絵）は貼らない
    eye_px = in_decal & alpha & (lum < 120) & ~cap
    soft_e = np.array(Image.fromarray((eye_px * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.8))).astype(np.float32)
    decal = img.copy()
    decal[~eye_px, :3] = np.array([40, 28, 26], np.float32)
    decal[:, :, 3] = soft_e

    # 腕：袖と胴の縫い目より外側（袖を含む）
    def arm_mask(seg, left):
        lo, hi = sorted((seg[0][1], seg[1][1]))
        lx = line_x(seg, np.clip(Y, lo, hi))
        side = (X < lx) if left else (X > lx)
        return alpha & ~head2d & ~hair & (Y < hi + 10) & side

    arm_l = arm_mask(p["arm_l"], True)
    arm_r = arm_mask(p["arm_r"], False)
    near = np.array(Image.fromarray((head2d * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(17))) > 128
    residue = near & (((lum < 170) & (Y > hcy)) | (skinlike & (Y < p["pivot_neck"][1] + 30)) | (a8 < 230))
    body = alpha & ~head2d & ~arm_l & ~arm_r & ~hair & ~residue
    arm_l &= ~residue
    arm_r &= ~residue

    def layer(mask):
        out = img.copy()
        out[:, :, 3] = np.where(mask, a8, 0)
        out[:, :, :3] *= (out[:, :, 3:4] > 0)
        return out

    parts = {"hair_cap": cap_img, "hair_extra": extra_img, "decal": decal, "body": layer(body),
             "arm_l": layer(arm_l), "arm_r": layer(arm_r)}
    meta = {k: v for k, v in p.items() if k not in ("arm_l", "arm_r", "tail")}
    meta["size"] = (w, h)
    meta["head_cx"] = hcx
    meta["pivot_neck"] = (hcx, round(hcy + 0.98 * hry))   # 眼鏡の子と同じ割合で、顎の少し上
    meta["skin"] = [round(float(v) / 255, 3) for v in skin]
    meta["hair"] = [round(float(v) / 255, 3) for v in hair_col]
    return {k: Image.fromarray(np.clip(v, 0, 255).astype(np.uint8), "RGBA") for k, v in parts.items()}, meta


def line_x(seg, y):
    (x0, y0), (x1, y1) = seg
    t = (y - y0) / (y1 - y0)
    return x0 + (x1 - x0) * t


def build(sheet, p):
    x0, y0, x1, y1 = p["box"]
    img = np.array(sheet.crop(p["box"]).convert("RGBA")).astype(np.float32)
    h, w = img.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w]
    X = xs + x0
    Y = ys + y0
    alpha = img[:, :, 3] > 8

    # 頭：髪を含む上側と、顎の下の楕円の内側
    dx = (X - p["head_cx"]) / p["head_chin_rx"]
    chin = p["head_chin_cy"] + p["head_chin_ry"] * np.sqrt(np.clip(1 - dx * dx, 0, 1))
    head = alpha & ((Y < p["head_chin_cy"]) | ((np.abs(dx) < 1) & (Y < chin)))

    # 髪：おでこより上の暗い部分（眼鏡を除く）
    lum = img[:, :, :3].mean(axis=2)
    glasses = (X > 1078) & (X < 1300) & (Y > 205)
    sides = (X < 1084) | (X > 1292)
    hair = alpha & (lum < 110) & ((Y < 228) | (sides & (Y < 262))) & ~glasses
    hm = Image.fromarray((hair * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(5))
    hair = (np.array(hm) > 128) & alpha
    skin_px = alpha & ~hair & (Y > 284) & (Y < 300) & (np.abs(X - p["head_cx"]) < 90) & (lum > 120)
    skin = np.median(img[skin_px][:, :3], axis=0)
    hair_col = np.median(img[hair][:, :3], axis=0)

    # 髪の球に貼る絵：前髪の下端までを髪の範囲とし、球の縁（横）はもみあげの高さまで下ろす。
    # 絵のない所は髪の色で埋める（球の後ろ側と同じ色でつながる）
    (hcx, hcy), (hrx, hry, _) = p["head_center"], p["head_radius"]
    s_hair = p["hair_scale"]
    ex = (X - hcx) / (hrx * s_hair)
    # 球の縁を少し越えるまで髪にしておく（うつむいて頭頂が見えても、縁で途切れないように）
    ell = ex * ex + ((Y - hcy) / (hry * s_hair)) ** 2 < 1.12
    fringe = np.full(w, -1.0)
    for xx in range(w):
        col = np.where(hair[:, xx])[0]
        if len(col):
            fringe[xx] = col.max() + y0
    fringe = np.array(Image.fromarray(fringe.astype(np.float32)[None, :]).filter(ImageFilter.MedianFilter(5)))[0] if False else fringe
    side_line = p["sideburn_y"]
    rim = np.abs((np.arange(w) + x0 - hcx) / (hrx * s_hair))
    fringe = np.where(rim > 0.8, np.maximum(fringe, side_line), fringe)
    cap = ell & (Y <= fringe[None, :])
    cap_img = np.zeros_like(img)
    cap_img[:, :, :3] = hair_col
    solid = hair & (img[:, :, 3] > 200)   # 縁の半透明の画素は色が濁るので、髪の色で埋める
    cap_img[solid, :3] = img[solid, :3]
    cap_img[:, :, 3] = np.where(cap, 255, 0)
    soft = np.array(Image.fromarray((cap * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))).astype(np.float32)
    # ぼかすのは前髪の下端だけ。縁は不透明のまま
    cap_img[:, :, 3] = np.maximum(soft, np.where(cap & (Y <= fringe[None, :] - 3), 255, 0))

    # 顔のシール：眼鏡と目のまわりだけを、縁をぼかして肌の球に貼る
    gx0, gy0, gx1, gy1 = p["decal_box"]
    u = np.clip(np.minimum(X - gx0, gx1 - X) / 14.0, 0, 1)
    v = np.clip(np.minimum(Y - gy0, gy1 - Y) / 12.0, 0, 1)
    decal = img.copy()
    decal[:, :, 3] = 255 * (u * v) * alpha * ~hair
    # 腕：袖と胴の縫い目より外側（袖を含む）
    def arm_mask(seg, left):
        lo, hi = sorted((seg[0][1], seg[1][1]))
        lx = line_x(seg, np.clip(Y, lo, hi))
        side = (X < lx) if left else (X > lx)
        return alpha & ~head & (Y > 345) & (Y < hi + 10) & side

    arm_l = arm_mask(p["arm_l"], True)
    arm_r = arm_mask(p["arm_r"], False)
    # 元の絵の顎の輪郭線と影は、頭の範囲のすぐ外にある。頭を少し広げた範囲の暗い画素も胴から外す
    near_head = np.array(Image.fromarray((head * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(17))) > 128
    chin_line = near_head & (img[:, :, :3].mean(axis=2) < 170) & (Y > 300)
    # 襟の上に残る元の首の肌と縁の色（彩度のある画素）も外す。シャツの白と線（灰色）は残す
    sat = img[:, :, :3].max(axis=2) - img[:, :, :3].min(axis=2)
    above_collar = (Y < 398) & (np.abs(X - p["head_cx"]) < 120) & (sat > 25)
    near_wide = np.array(Image.fromarray((head * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(31))) > 128
    halo = near_wide & ((img[:, :, 3] < 230) | (Y < 372))   # 縁の半透明のにじみと、肩の上のかけら
    body = alpha & ~head & ~arm_l & ~arm_r & ~chin_line & ~above_collar & ~halo
    arm_l &= ~chin_line & ~halo
    arm_r &= ~chin_line & ~halo

    def layer(mask):
        out = img.copy()
        out[:, :, 3] = np.where(mask, img[:, :, 3], 0)
        out[:, :, :3] *= (out[:, :, 3:4] > 0)
        return out

    parts = {"hair_cap": cap_img, "decal": decal, "body": layer(body),
             "arm_l": layer(arm_l), "arm_r": layer(arm_r)}

    # 胴：袖の下に隠れる肩を、胴の端の色で外へ少し延ばす（腕を動かしたときに隙間が見えないように）
    b = parts["body"]
    for yy in range(h):
        Yv = yy + y0
        for seg, left in ((p["arm_l"], True), (p["arm_r"], False)):
            lo, hi = sorted((seg[0][1], seg[1][1]))
            if Yv < lo or Yv > hi:
                continue
            cols = np.where(b[yy, :, 3] > 200)[0]
            if len(cols) == 0:
                continue
            e = cols.min() if left else cols.max()
            src = b[yy, e + 4 if left else e - 4].copy()
            for xx in (range(e - 1, max(0, e - 8), -1) if left else range(e + 1, min(w, e + 8))):
                if b[yy, xx, 3] < 200:
                    b[yy, xx] = src

    # 首は 3D の円柱で描くので、胴の頭の跡は透明のままにする

    meta = {k: v for k, v in p.items() if k not in ("arm_l", "arm_r")}
    meta["size"] = (w, h)
    meta["skin"] = [round(float(v) / 255, 3) for v in skin]
    meta["hair"] = [round(float(v) / 255, 3) for v in hair_col]
    return {k: Image.fromarray(np.clip(v, 0, 255).astype(np.uint8), "RGBA") for k, v in parts.items()}, meta


def main():
    sheet = Image.open(SOURCE)
    chars = {}
    built = {"glasses": build(sheet, BOY), **{k: build_other(sheet, v) for k, v in OTHERS.items()}}
    for name, (parts, meta) in built.items():
        out_dir = OUTPUT / name
        out_dir.mkdir(exist_ok=True)
        for k, im in parts.items():
            # 書き出す PNG には、作成日時などの付加情報を入れない
            im.save(out_dir / f"{k}.png", optimize=True)
        meta.setdefault("hip_y", 560)
        chars[name] = {k: list(v) if isinstance(v, tuple) else v for k, v in meta.items()}
    (OUTPUT / "characters.json").write_text(json.dumps(chars, indent=1, sort_keys=True) + "\n")
    print("characters.json", ", ".join(chars))


if __name__ == "__main__":
    main()
