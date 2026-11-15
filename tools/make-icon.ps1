# Turns a square artwork into the addon icon: crops a square, scales it down in
# halving steps and writes an uncompressed 32-bit TGA (what WoW expects).
# -Preview writes a PNG sheet with the icon at 64/32/20 px and as a round
# minimap button. Crop defaults fit the current 2000x2000 bottle artwork.
# Usage: powershell -File tools\make-icon.ps1 -Src art.jpg [-Preview preview.png]
param([Parameter(Mandatory = $true)][string]$Src,
      [string]$OutTga = (Join-Path (Split-Path $PSScriptRoot) "Media\Logo.tga"),
      [string]$Preview = "", [int]$Size = 64,
      [int]$CropX = 40, [int]$CropY = 0, [int]$CropSize = 1920)
$code = @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class IconTool {
    static Bitmap Scale(Bitmap src, int size) {
        Bitmap b = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            using (ImageAttributes ia = new ImageAttributes()) {
                ia.SetWrapMode(WrapMode.TileFlipXY); // no dark fringe at the edges
                g.DrawImage(src, new Rectangle(0, 0, size, size), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel, ia);
            }
        }
        return b;
    }

    // Crop a square and halve repeatedly down to the target size (sharper than one big jump).
    public static Bitmap Make(string src, int cx, int cy, int cs, int size) {
        using (Bitmap full = new Bitmap(src)) {
            Bitmap cur = full.Clone(new Rectangle(cx, cy, cs, cs), PixelFormat.Format32bppArgb);
            int s = cs;
            while (s / 2 >= size * 2) { s /= 2; Bitmap next = Scale(cur, s); cur.Dispose(); cur = next; }
            Bitmap result = Scale(cur, size);
            cur.Dispose();
            return result;
        }
    }

    // Uncompressed 32-bit TGA, bottom-up rows (what WoW expects).
    public static void SaveTga(Bitmap b, string path) {
        int w = b.Width, h = b.Height;
        using (FileStream fs = new FileStream(path, FileMode.Create))
        using (BinaryWriter bw = new BinaryWriter(fs)) {
            bw.Write((byte)0); bw.Write((byte)0); bw.Write((byte)2);
            bw.Write(new byte[5]);
            bw.Write((short)0); bw.Write((short)0);
            bw.Write((short)w); bw.Write((short)h);
            bw.Write((byte)32); bw.Write((byte)8);
            for (int y = h - 1; y >= 0; y--)
                for (int x = 0; x < w; x++) {
                    Color c = b.GetPixel(x, y);
                    bw.Write(c.B); bw.Write(c.G); bw.Write(c.R); bw.Write(c.A);
                }
        }
    }

    // full crop + the 64px icon at 64/32/20 and as a round minimap button (also 4x enlarged)
    public static void Preview(string src, int cx, int cy, int cs, Bitmap icon, string path) {
        using (Bitmap sheet = new Bitmap(600, 300, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(sheet)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.Clear(Color.FromArgb(255, 27, 27, 31));
            using (Bitmap full = new Bitmap(src))
                g.DrawImage(full, new Rectangle(10, 10, 280, 280), new Rectangle(cx, cy, cs, cs), GraphicsUnit.Pixel);
            g.DrawImage(icon, 310, 20, 64, 64);
            g.DrawImage(icon, 390, 36, 32, 32);
            g.DrawImage(icon, 440, 42, 20, 20);
            using (SolidBrush map = new SolidBrush(Color.FromArgb(255, 107, 90, 58))) g.FillRectangle(map, 480, 20, 64, 64);
            using (SolidBrush black = new SolidBrush(Color.Black)) g.FillEllipse(black, 496, 36, 31, 31);
            using (GraphicsPath circ = new GraphicsPath()) {
                circ.AddEllipse(501.5f, 41.5f, 20, 20); g.SetClip(circ);
                g.DrawImage(icon, 501.5f, 41.5f, 20, 20); g.ResetClip();
            }
            using (Pen ring = new Pen(Color.FromArgb(255, 184, 150, 62), 3f)) g.DrawEllipse(ring, 496, 36, 31, 31);
            using (SolidBrush map = new SolidBrush(Color.FromArgb(255, 107, 90, 58))) g.FillRectangle(map, 310, 110, 180, 180);
            using (SolidBrush black = new SolidBrush(Color.Black)) g.FillEllipse(black, 324, 124, 152, 152);
            using (Bitmap tiny = new Bitmap(20, 20, PixelFormat.Format32bppArgb)) {
                using (Graphics gt = Graphics.FromImage(tiny)) {
                    gt.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    gt.DrawImage(icon, 0, 0, 20, 20);
                }
                using (GraphicsPath circ = new GraphicsPath()) {
                    circ.AddEllipse(350, 150, 100, 100); g.SetClip(circ);
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.DrawImage(tiny, 350, 150, 100, 100);
                    g.ResetClip();
                }
            }
            using (Pen ring = new Pen(Color.FromArgb(255, 184, 150, 62), 14f)) g.DrawEllipse(ring, 324, 124, 152, 152);
            sheet.Save(path, ImageFormat.Png);
        }
    }
}
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Drawing
$icon = [IconTool]::Make($Src, $CropX, $CropY, $CropSize, $Size)
[IconTool]::SaveTga($icon, $OutTga)
if ($Preview) { [IconTool]::Preview($Src, $CropX, $CropY, $CropSize, $icon, $Preview) }
$icon.Dispose()
Get-Item (@($OutTga) + @($Preview | Where-Object { $_ })) | Select-Object Name, Length
