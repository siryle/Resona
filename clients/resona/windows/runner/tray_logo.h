#ifndef RUNNER_TRAY_LOGO_H_
#define RUNNER_TRAY_LOGO_H_

#include <windows.h>
#include <gdiplus.h>

// The same R, record and wave geometry as macOS MenuBarLogo.swift.
inline HICON CreateTrayLogo(int size, bool light) {
  using namespace Gdiplus;
  Bitmap image(size, size, PixelFormat32bppPARGB);
  Graphics g(&image);
  g.SetSmoothingMode(SmoothingModeAntiAlias);
  g.Clear(Color(0, 0, 0, 0));
  g.TranslateTransform(static_cast<REAL>(size) * 0.05f,
                       static_cast<REAL>(size) * 0.12f);
  g.ScaleTransform(static_cast<REAL>(size) * 0.9f / 977,
                   static_cast<REAL>(size) * 0.9f / 977);
  g.TranslateTransform(-136, -207);
  GraphicsPath mark(FillModeAlternate);
  PointF at(487, 1023);
  auto line = [&](REAL x, REAL y) {
    mark.AddLine(at, PointF(x, y));
    at = PointF(x, y);
  };
  auto curve = [&](REAL x1, REAL y1, REAL x2, REAL y2, REAL x, REAL y) {
    mark.AddBezier(at, PointF(x1, y1), PointF(x2, y2), PointF(x, y));
    at = PointF(x, y);
  };
  auto quad = [&](REAL cx, REAL cy, REAL x, REAL y) {
    curve(at.X + (cx - at.X) * 2 / 3, at.Y + (cy - at.Y) * 2 / 3,
          x + (cx - x) * 2 / 3, y + (cy - y) * 2 / 3, x, y);
  };
  line(487, 977);
  quad(487, 966, 479, 966);
  curve(305, 966, 162, 826, 162, 638);
  curve(162, 456, 309, 308, 493, 308);
  curve(638, 308, 740, 417, 740, 548);
  curve(740, 667, 694, 755, 495, 769);
  quad(487, 771, 487, 779);
  line(487, 942);
  curve(314, 928, 185, 798, 185, 641);
  curve(185, 482, 288, 339, 469, 339);
  curve(591, 339, 689, 438, 689, 569);
  curve(689, 680, 623, 749, 520, 780);
  quad(511, 783, 517, 792);
  line(685, 1001);
  quad(708, 1032, 744, 1032);
  line(909, 1032);
  quad(921, 1032, 916, 1021);
  line(804, 870);
  curve(772, 830, 745, 808, 704, 789);
  curve(821, 770, 885, 678, 885, 551);
  curve(885, 374, 734, 235, 538, 235);
  curve(319, 235, 136, 405, 136, 628);
  curve(136, 836, 285, 1001, 480, 1030);
  quad(487, 1031, 487, 1023);
  mark.CloseFigure();
  mark.AddEllipse(365.0f, 537.0f, 214.0f, 214.0f);
  mark.AddEllipse(451.0f, 623.0f, 42.0f, 42.0f);
  for (REAL x : {224.0f, 272.0f, 320.0f}) {
    GraphicsPath groove;
    const REAL cy = 470 + (x - 224), end_x = x + 168 - (x - 224) / 1.6f;
    const REAL end_y = 407 + (x - 224);
    groove.AddBezier(x, 619.0f, x + 20 * 2 / 3, 619 + (cy - 619) * 2 / 3,
                     end_x + (x + 20 - end_x) * 2 / 3,
                     end_y + (cy - end_y) * 2 / 3, end_x, end_y);
    Pen pen(Color(255, 0, 0, 0), 24);
    pen.SetStartCap(LineCapRound);
    pen.SetEndCap(LineCapRound);
    groove.Widen(&pen);
    mark.AddPath(&groove, FALSE);
  }
  const Color foreground = light ? Color(255, 0, 0, 0) : Color(255, 255, 255, 255);
  SolidBrush brush(foreground);
  g.FillPath(&brush, &mark);
  Pen wave(foreground, 66);
  wave.SetStartCap(LineCapRound);
  wave.SetEndCap(LineCapRound);
  const PointF starts[] = {{826, 240}, {980, 270}};
  const PointF ends[] = {{850, 815}, {920, 874}};
  const PointF controls[] = {{1110, 496}, {1230, 570}};
  for (int i = 0; i < 2; ++i) {
    GraphicsPath path;
    const auto a = starts[i], b = ends[i], c = controls[i];
    path.AddBezier(a, PointF(a.X + (c.X - a.X) * 2 / 3,
                            a.Y + (c.Y - a.Y) * 2 / 3),
                   PointF(b.X + (c.X - b.X) * 2 / 3,
                          b.Y + (c.Y - b.Y) * 2 / 3), b);
    g.DrawPath(&wave, &path);
  }
  HICON icon = nullptr;
  image.GetHICON(&icon);
  return icon;
}

#endif
