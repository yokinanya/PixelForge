//! 用真实滚动截图验证完整分析与合成链路。
//! 用法: cargo run -p stitch_core --example compose_real -- <a> <b> ... <out.png>

use std::path::PathBuf;

use stitch_core::{
    analyze_pair, compose_to_file, load_luma, ComposeConfig, ExportFormat, FixedOptions,
    OverlapOptions, SeamEntry,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("用法: compose_real <图A> <图B> ... <输出.png>");
        std::process::exit(1);
    }

    let output = PathBuf::from(args.last().expect("输出路径缺失"));
    let paths: Vec<PathBuf> = args[1..args.len() - 1].iter().map(PathBuf::from).collect();
    let pairs: Vec<_> = paths
        .windows(2)
        .map(|pair| {
            let top = load_luma(&pair[0]).expect("加载上图失败");
            let bottom = load_luma(&pair[1]).expect("加载下图失败");
            analyze_pair(
                &top,
                &bottom,
                &OverlapOptions::default(),
                &FixedOptions::default(),
            )
            .expect("分析接缝失败")
        })
        .collect();

    let seams = pairs
        .iter()
        .map(|(seam, _)| SeamEntry {
            dx: seam.best.dx,
            dy: seam.best.dy,
        })
        .collect();
    let top_bars = std::iter::once(pairs[0].1.top_bar.map_or(0, |r| r.h))
        .chain(
            pairs
                .iter()
                .map(|(_, fixed)| fixed.top_bar.map_or(0, |r| r.h)),
        )
        .collect();
    let mut bottom_bars: Vec<u32> = pairs
        .iter()
        .map(|(_, fixed)| fixed.bottom_bar.map_or(0, |r| r.h))
        .collect();
    let last_bottom_bar = pairs.last().unwrap().1.bottom_bar.map_or(0, |r| r.h);
    bottom_bars.push(last_bottom_bar);
    let last_bottom_whitespace = pairs.last().unwrap().1.bottom_whitespace.map_or(0, |r| r.h);
    let config = ComposeConfig {
        format: ExportFormat::Png,
        scale_percent: 100,
        seams,
        top_bars,
        bottom_bars,
        last_bottom_whitespace,
        remove_first_status_bar: false,
        trim_last_bottom_whitespace: true,
        retained_bottom_edge: 24,
    };

    compose_to_file(&paths, &config, &output, |done, total| {
        println!("导出进度: {done}/{total}");
    })
    .expect("合成失败");
    let info = stitch_core::load_info(&output).expect("读取输出尺寸失败");
    println!(
        "输出: {}x{} -> {}",
        info.width,
        info.height,
        output.display()
    );
}
