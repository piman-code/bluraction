#!/usr/bin/env python3
"""
blur_action.py — 빠른 검증용 자유형/사각형 블러 CLI.

입력 mp4/mov 한 개에 대해:
  - 사각형 모드: --rect x y w h
  - 자유형 모드: --polygon "x1,y1 x2,y2 x3,y3 ..." (픽셀 좌표)
Gaussian Blur 강도를 받아, 마스크 영역만 블러 처리해 *_blurred.<ext>로 저장한다.

원본은 절대 수정하지 않는다. 충돌 시 (1), (2) ... suffix로 저장.
의존성: opencv-python, numpy
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import cv2
import numpy as np


def parse_polygon(s: str) -> np.ndarray:
    """입력 한 점 = 'x,y' 또는 'x y' 또는 'x:y' 형식. 여러 점은 공백으로 구분.
    예: '80,60 540,60 540,220' 또는 '80 60 540 60 540 220'.
    홀수 인자(콤마 없이 공백만)도 페어로 묶어 해석."""
    # 1차: 콤마와 콜론을 모두 'x' 로 통일 → 'x'로 split하면 페어로 안전하게 분리
    normalized = s.replace(",", "x").replace(":", "x").replace(";", "x").replace("\t", " ").replace(",", " ")
    # 안전: 콤마가 두 번 치환되지 않게 이미 위에서 공백으로 만든 뒤 split
    tokens = [t for t in normalized.split() if t.strip()]
    pts: list[list[float]] = []
    for tok in tokens:
        if "x" in tok:
            parts = tok.split("x")
        else:
            # 공백으로만 분리된 단일 숫자 — 페어 단위로 묶기 위해 zip
            raise ValueError("use 'x,y' or 'x y' or 'x:y' separator inside each point")
        if len(parts) != 2:
            raise ValueError(f"polygon point must have one separator (got: {tok!r})")
        pts.append([float(parts[0]), float(parts[1])])
    arr = np.array(pts, dtype=np.float32)
    if arr.ndim != 2 or arr.shape[1] != 2 or arr.shape[0] < 3:
        raise ValueError(f"polygon points must be >=3, got shape {arr.shape}")
    return arr


def parse_rect(s: str) -> tuple[int, int, int, int]:
    parts = [float(p) for p in s.replace(",", " ").split()]
    if len(parts) != 4:
        raise ValueError(f"rect needs x y w h, got {parts}")
    return int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])


def build_mask(shape_hw: tuple[int, int], polygons: list[np.ndarray], rects: list[tuple[int, int, int, int]]) -> np.ndarray:
    h, w = shape_hw
    mask = np.zeros((h, w), dtype=np.uint8)
    for poly in polygons:
        cv2.fillPoly(mask, [np.round(poly).astype(np.int32)], 255)
    for x, y, rw, rh in rects:
        cv2.rectangle(mask, (x, y), (x + rw, y + rh), 255, thickness=-1)
    return mask


def next_available(out_path: Path) -> Path:
    if not out_path.exists():
        return out_path
    stem, suf = out_path.stem, out_path.suffix
    i = 1
    while True:
        cand = out_path.with_name(f"{stem}({i}){suf}")
        if not cand.exists():
            return cand
        i += 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Region blur CLI (proof-of-concept)")
    ap.add_argument("input", type=Path, help="입력 영상 경로 (.mp4 / .mov)")
    ap.add_argument("--polygon", action="append", default=[], help='자유형 폴리곤 "x1,y1 x2,y2 ..." (픽셀)')
    ap.add_argument("--rect", action="append", default=[], help='사각형 "x y w h" (픽셀)')
    ap.add_argument("--strength", type=int, default=35, help="Gaussian Blur 강도 (홀수, 기본 35)")
    ap.add_argument("--out", type=Path, default=None, help="출력 경로 (기본: 원본 옆 *_blurred.<ext>)")
    args = ap.parse_args()

    inp: Path = args.input.expanduser().resolve()
    if not inp.is_file():
        print(f"[ERROR] 입력 파일 없음: {inp}", file=sys.stderr)
        return 2

    polygons = [parse_polygon(p) for p in args.polygon]
    rects = [parse_rect(r) for r in args.rect]
    if not polygons and not rects:
        print("[ERROR] --polygon 또는 --rect 중 최소 1개 필요", file=sys.stderr)
        return 2

    strength = args.strength
    if strength < 1:
        strength = 1
    if strength % 2 == 0:
        strength += 1  # cv2.GaussianBlur는 홀수 커널 요구

    out_path = (args.out.expanduser().resolve() if args.out else inp.with_name(f"{inp.stem}_blurred{inp.suffix}"))
    if out_path == inp:
        print(f"[ERROR] 출력 경로가 원본과 동일: {out_path}", file=sys.stderr)
        return 2
    out_path = next_available(out_path)

    cap = cv2.VideoCapture(str(inp))
    if not cap.isOpened():
        print(f"[ERROR] 비디오 열기 실패: {inp}", file=sys.stderr)
        return 2

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(out_path), fourcc, fps, (w, h))
    if not writer.isOpened():
        print(f"[ERROR] 비디오 쓰기 실패: {out_path}", file=sys.stderr)
        cap.release()
        return 2

    mask = build_mask((h, w), polygons, rects)
    mask_f = (mask.astype(np.float32) / 255.0)[..., None]  # (h, w, 1) for broadcasting

    print(f"[INFO] 입력: {inp}")
    print(f"[INFO] 출력: {out_path}")
    print(f"[INFO] 해상도: {w}x{h}  fps: {fps:.2f}  프레임: {total}")
    print(f"[INFO] 영역: polygon {len(polygons)}개, rect {len(rects)}개, blur 강도 {strength}")

    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        blurred = cv2.GaussianBlur(frame, (strength, strength), 0)
        out_frame = (frame.astype(np.float32) * (1.0 - mask_f) + blurred.astype(np.float32) * mask_f)
        out_frame = np.clip(out_frame, 0, 255).astype(np.uint8)
        writer.write(out_frame)
        idx += 1
        if idx % 30 == 0 or idx == total:
            pct = (idx / total * 100.0) if total > 0 else 0.0
            print(f"\r[INFO] 진행 {idx}/{total} ({pct:.1f}%)", end="", flush=True)

    cap.release()
    writer.release()
    print("\n[OK] 완료")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())