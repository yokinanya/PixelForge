#![allow(clippy::too_many_arguments)]
//! 临时诊断工具：分析相邻截图对，打印接缝与固定元素检测结果。
//! 用法: cargo run -p stitch_core --example diagnose -- <a> <b>

use stitch_core::{analyze_pair, load_luma, FixedOptions, OverlapOptions};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("用法: diagnose <图A> <图B>");
        std::process::exit(1);
    }
    let a = load_luma(std::path::Path::new(&args[1])).expect("加载 A 失败");
    let b = load_luma(std::path::Path::new(&args[2])).expect("加载 B 失败");
    println!("A: {}x{}  B: {}x{}", a.width, a.height, b.width, b.height);

    let mut fixed_opts = FixedOptions::default();
    if let Ok(value) = std::env::var("STITCH_FIXED_THRESHOLD") {
        fixed_opts.row_same_threshold = value.parse().expect("固定元素阈值必须是数字");
    }
    let (seam, fixed) =
        analyze_pair(&a, &b, &OverlapOptions::default(), &fixed_opts).expect("分析失败");

    println!("== 接缝 ==");
    println!(
        "best: dx={} dy={} cost={:.2} 可信={} 置信度={:.3}",
        seam.best.dx, seam.best.dy, seam.best.cost, seam.plausible, seam.confidence
    );
    for (i, c) in seam.candidates.iter().enumerate().take(seam.n_candidates) {
        println!("  候选[{i}]: dx={} dy={} cost={:.2}", c.dx, c.dy, c.cost);
    }
    println!(
        "重叠高度 = {}px (A高度 {} - dy {})",
        a.height - seam.best.dy,
        a.height,
        seam.best.dy
    );

    println!("== 固定元素 ==");
    println!("  顶部固定区域: {:?}", fixed.top_bar);
    println!("  底部固定区域: {:?}", fixed.bottom_bar);
    println!("  底部留白: {:?}", fixed.bottom_whitespace);

    // 行级固定掩码统计（诊断用）
    let mask = stitch_core::overlap::fixed_row_mask_debug(&a, &b);
    let fixed_count = mask.iter().filter(|x| **x).count();
    println!("== 固定行掩码 ==");
    println!(
        "  fixed 行: {}/{} ({:.0}%)",
        fixed_count,
        mask.len(),
        fixed_count as f64 * 100.0 / mask.len() as f64
    );
    // 打印顶部 300 行的 fixed 分布（每 10 行一组）
    let mut line = String::from("  顶部: ");
    for chunk in mask.iter().take(300).collect::<Vec<_>>().chunks(10) {
        let n = chunk.iter().filter(|x| ***x).count();
        line.push(if n > 5 {
            '#'
        } else if n > 0 {
            '+'
        } else {
            '.'
        });
    }
    println!("{line}");
    // 底部 300 行
    let mut line = String::from("  底部: ");
    for chunk in mask[mask.len() - 300..].chunks(10) {
        let n = chunk.iter().filter(|x| **x).count();
        line.push(if n > 5 {
            '#'
        } else if n > 0 {
            '+'
        } else {
            '.'
        });
    }
    println!("{line}");
    // 300-1100 行分布
    let mut line = String::from("  300-1100: ");
    for chunk in mask[300..1100.min(mask.len())].chunks(10) {
        let n = chunk.iter().filter(|x| **x).count();
        line.push(if n > 5 {
            '#'
        } else if n > 0 {
            '+'
        } else {
            '.'
        });
    }
    println!("{line}");
    // 顶部固定区高度（跳过算法）
    let skip = mask
        .iter()
        .enumerate()
        .scan(0usize, |gap, (i, f)| {
            if *f {
                *gap = 0;
                Some(Some(i + 1))
            } else {
                *gap += 1;
                if *gap > 5 {
                    None
                } else {
                    Some(None)
                }
            }
        })
        .flatten()
        .last()
        .unwrap_or(0);
    println!("  top_fixed_height ≈ {skip}px");

    // 成本分解：模拟粗搜索（scale4, strip 100, sy=2）与精修（strip 400, sy=1）
    println!("== 成本分解（含 fixed 掩码与行能量门控）==");
    let t4 = stitch_core::downsample(&a, 4);
    let b4 = stitch_core::downsample(&b, 4);
    let t4g = stitch_core::sobel(&t4);
    let b4g = stitch_core::sobel(&b4);
    // 扫描 dy ∈ [280, 420] 找最低成本
    let mut best_scan = (f64::INFINITY, 0u32);
    let mut dy = 280u32;
    while dy <= 420 {
        let c = probe_weighted(&t4, &t4g, &b4, &b4g, 0, dy, 100, 2, 2);
        if c.0 < best_scan.0 {
            best_scan = (c.0, dy);
        }
        dy += 4;
    }
    println!(
        "  scale4 扫描 [280,420]: 最低 cost={:.2} @ dy={} (原图 {})",
        best_scan.0,
        best_scan.1,
        best_scan.1 * 4
    );
    for dy in [best_scan.1, 310, 320, 330, 340, 350, 360] {
        let c = probe_weighted(&t4, &t4g, &b4, &b4g, 0, dy, 100, 2, 2);
        println!("    dy={dy} (原图 {}): cost={:.2}", dy * 4, c.0);
    }
    // 行签名粗搜索原型：每行压缩为 8 段梯度能量签名，全范围互相关
    println!("== 行签名粗搜索原型 ==");
    let tg_full = stitch_core::sobel(&a);
    let bg_full = stitch_core::sobel(&b);
    let sig_a = row_signatures(&tg_full, &a, 8);
    let sig_b = row_signatures(&bg_full, &b, 8);
    let mask_full = stitch_core::overlap::fixed_row_mask_debug(&a, &b);
    let mut best_sig = (f64::INFINITY, 0u32);
    let strip = 300usize;
    let max_dy = a.height - (a.height as f32 * 0.05) as u32;
    let mut dy = 0u32;
    while dy < max_dy {
        // B 顶部 strip 签名 vs A 行 dy 处
        let mut num = 0.0f64;
        let mut den = 0.0f64;
        for i in 0..strip {
            let by = i as u32;
            if mask_full.get(by as usize).copied().unwrap_or(false) {
                continue;
            }
            let ay = dy + by;
            if ay as usize >= sig_a.len() {
                break;
            }
            let (sa, sb) = (&sig_a[ay as usize], &sig_b[by as usize]);
            let mut d = 0.0f64;
            for k in 0..8 {
                d += (sa[k] - sb[k]).abs();
            }
            num += d;
            den += 1.0;
        }
        if den > 0.0 {
            let c = num / den;
            if c < best_sig.0 {
                best_sig = (c, dy);
            }
        }
        dy += 1;
    }
    println!(
        "  签名扫描 [0,{}]: 最低 cost={:.2} @ dy={} (原图 {})",
        max_dy, best_sig.0, best_sig.1, best_sig.1
    );
    // 打印候选 dy 的签名成本
    for dy in [0u32, 1248, 1350, 1390, 1400, 1512] {
        let mut num = 0.0f64;
        let mut den = 0.0f64;
        for i in 0..strip {
            let by = i as u32;
            if mask_full.get(by as usize).copied().unwrap_or(false) {
                continue;
            }
            let ay = dy + by;
            if ay as usize >= sig_a.len() {
                break;
            }
            let (sa, sb) = (&sig_a[ay as usize], &sig_b[by as usize]);
            let mut d = 0.0f64;
            for k in 0..8 {
                d += (sa[k] - sb[k]).abs();
            }
            num += d;
            den += 1.0;
        }
        if den > 0.0 {
            println!("    dy={dy}: 签名成本={:.2}", num / den);
        }
    }
}

/// 行签名：每行按列分成 `segments` 段，每段取梯度能量均值。
fn row_signatures(
    grad: &stitch_core::LumaImage,
    luma: &stitch_core::LumaImage,
    segments: usize,
) -> Vec<Vec<f64>> {
    let w = luma.width;
    let seg_w = (w as usize).div_ceil(segments).max(1);
    let mut out = Vec::with_capacity(luma.height as usize);
    for row in 0..luma.height {
        let mut sig = vec![0.0f64; segments];
        for (seg, v) in sig.iter_mut().enumerate() {
            let x0 = seg * seg_w;
            let x1 = ((seg + 1) * seg_w).min(w as usize);
            let mut sum = 0u64;
            let mut n = 0u64;
            for x in x0..x1 {
                sum += grad.get(x as u32, row).unwrap_or(0) as u64;
                n += 1;
            }
            *v = if n > 0 { sum as f64 / n as f64 } else { 0.0 };
        }
        out.push(sig);
    }
    out
}

/// 复刻 weighted_band_cost：加权 + fixed 掩码 + 行能量门控。
fn probe_weighted(
    top: &stitch_core::LumaImage,
    tg: &stitch_core::LumaImage,
    bottom: &stitch_core::LumaImage,
    bg: &stitch_core::LumaImage,
    dx: i32,
    dy: u32,
    strip_h: u32,
    sx: u32,
    sy: u32,
) -> (f64, u32) {
    let band = (top.height - dy).min(strip_h);
    let mask = stitch_core::overlap::fixed_row_mask_debug(top, bottom);
    let mut num = 0.0f64;
    let mut den = 0.0f64;
    let mut rows_used = 0u32;
    let mut y = 0u32;
    while y < band {
        if mask.get(y as usize).copied().unwrap_or(false) {
            y += sy;
            continue;
        }
        let e_b = row_energy(bg, y, sx);
        let e_a = row_energy(tg, dy + y, sx);
        if e_a < 120 && e_b < 120 {
            y += sy;
            continue;
        }
        rows_used += 1;
        let mut x = 0u32;
        while x < top.width {
            let bx = x as i64 + dx as i64;
            if bx >= 0 && (bx as u32) < bottom.width {
                let va = top.get(x, dy + y).unwrap_or(0) as i32;
                let vb = bottom.get(bx as u32, y).unwrap_or(0) as i32;
                let d = (va - vb).abs();
                let e = tg
                    .get(x, dy + y)
                    .unwrap_or(0)
                    .max(bg.get(bx as u32, y).unwrap_or(0));
                let w = 1.0 + (e as f64 / 255.0) * (e as f64 / 255.0) * 19.0;
                den += w;
                if d > 12 {
                    num += w * (d - 12) as f64;
                }
            }
            x += sx;
        }
        y += sy;
    }
    (
        if den == 0.0 { f64::INFINITY } else { num / den },
        rows_used,
    )
}

fn row_energy(grad: &stitch_core::LumaImage, row: u32, sx: u32) -> u32 {
    let mut sum = 0u32;
    let mut x = 0u32;
    while x < grad.width {
        sum += grad.get(x, row).unwrap_or(0) as u32;
        x += sx;
    }
    sum
}
