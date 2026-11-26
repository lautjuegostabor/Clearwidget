//! App icons and screenshots, served from BariStore's own cache: each one is
//! fetched once, shrunk (PNG/JPEG; other formats are kept as they are) and
//! kept in ~/.baristore/icons. Sources link images of up to several
//! megabytes on slow hosts; the page then loads small copies from the
//! iPhone itself. Screenshots must be shrunk: a 1290×2796 one takes 14 MB
//! once decoded, and a page of them would take the web view's memory. The
//! icon of an app added as an IPA comes from inside the IPA ("ipa:<file>");
//! a picture the user chose as an app's icon from app-icons/ ("custom:<file>").

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::{logf, state};

/// Icons fit 120 px, screenshots 1100 px (an app's page; Featured's tiles
/// show none since 1.1.0). The page asks only for these.
pub const ICON: u32 = 120;
pub const SIZES: [u32; 2] = [ICON, 1100];
const MAX_BYTES: usize = 8 << 20;
/// The cache's size at most: the oldest pictures go first.
const CAP: u64 = 80 << 20;

fn path(url: &str, size: u32) -> PathBuf {
    let key = if size == ICON { url.to_string() } else { format!("{url}@{size}") };
    state::path("icons").join(hex::encode(&Sha256::digest(key.as_bytes())[..12]))
}

/// One icon and two screenshots are decoded at a time (two of the iPhone's
/// cores; Minis's shell has little memory); icons never wait behind a
/// screenshot.
static ICON_TURN: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);
static SHOT_TURN: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

/// A picture being made: who asks for it meanwhile waits for it instead of
/// making it again (the page and the prefetch after a catalog refresh ask
/// for the same icons at the same time).
type Making = Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>;
static MAKING: std::sync::LazyLock<Making> = std::sync::LazyLock::new(Default::default);

/// The MIME type of image bytes, from their magic number.
pub fn kind(bytes: &[u8]) -> &'static str {
    match bytes {
        [0x89, b'P', b'N', b'G', ..] => "image/png",
        [0xFF, 0xD8, ..] => "image/jpeg",
        [b'G', b'I', b'F', ..] => "image/gif",
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "image/webp",
        _ if bytes.windows(4).take(256).any(|w| w == b"<svg") => "image/svg+xml",
        _ => "application/octet-stream",
    }
}

/// What shrinking found: a smaller copy, an image already small enough, or
/// one that could not be decoded within the limits.
#[derive(Debug)]
enum Shrunk {
    Smaller(Vec<u8>),
    Fits,
    Unreadable,
}

/// Whether PNG bytes are Apple's "CgBI" variant (see `uncrush`).
fn crushed(bytes: &[u8]) -> bool {
    bytes.len() > 16 && bytes.starts_with(b"\x89PNG") && &bytes[12..16] == b"CgBI"
}

/// Apple's "CgBI" PNG, as Xcode stores the icons in an app: a CgBI chunk
/// first, the image data deflated without zlib's wrapper, pixels as BGRA
/// with premultiplied alpha. Only Apple's own decoder reads it as it is.
/// 8-bit, not interlaced, RGB or RGBA (what Xcode writes).
fn uncrush(png: &[u8]) -> Option<image::DynamicImage> {
    use std::io::Read;
    let (mut at, mut width, mut height, mut channels) = (8, 0usize, 0usize, 0usize);
    let mut deflated = Vec::new();
    while at + 8 <= png.len() {
        let len = u32::from_be_bytes(png[at..at + 4].try_into().ok()?) as usize;
        let body = png.get(at + 8..at + 8 + len)?;
        match &png[at + 4..at + 8] {
            b"IHDR" if len == 13 => {
                width = u32::from_be_bytes(body[0..4].try_into().ok()?) as usize;
                height = u32::from_be_bytes(body[4..8].try_into().ok()?) as usize;
                if body[8] != 8 || body[12] != 0 {
                    return None;
                }
                channels = match body[9] { 6 => 4, 2 => 3, _ => return None };
            }
            b"IDAT" => deflated.extend_from_slice(body),
            b"IEND" => break,
            _ => {}
        }
        at += 12 + len;
    }
    if width == 0 || height == 0 || width > 2048 || height > 2048 {
        return None;
    }
    let stride = width * channels;
    let mut filtered = Vec::new();
    flate2::read::DeflateDecoder::new(&deflated[..]).take(((stride + 1) * height) as u64)
        .read_to_end(&mut filtered).ok()?;
    if filtered.len() != (stride + 1) * height {
        return None;
    }
    let mut pixels = vec![0u8; stride * height];
    for y in 0..height {
        let line = &filtered[y * (stride + 1)..(y + 1) * (stride + 1)];
        let (above, row) = pixels.split_at_mut(y * stride);
        let up = &above[above.len().saturating_sub(stride)..];
        for x in 0..stride {
            let a = if x >= channels { row[x - channels] } else { 0 };
            let (b, c) = if y > 0 { (up[x], if x >= channels { up[x - channels] } else { 0 }) } else { (0, 0) };
            let predicted = match line[0] {
                0 => 0,
                1 => a,
                2 => b,
                3 => ((u16::from(a) + u16::from(b)) / 2) as u8,
                4 => {
                    let p = i16::from(a) + i16::from(b) - i16::from(c);
                    let (pa, pb, pc) = ((p - i16::from(a)).abs(), (p - i16::from(b)).abs(), (p - i16::from(c)).abs());
                    if pa <= pb && pa <= pc { a } else if pb <= pc { b } else { c }
                }
                _ => return None,
            };
            row[x] = line[1 + x].wrapping_add(predicted);
        }
    }
    let mut rgba = Vec::with_capacity(width * height * 4);
    for p in pixels.chunks_exact(channels) {
        let alpha = if channels == 4 { p[3] } else { 255 };
        let straight = |v: u8| match alpha {
            0 => 0,
            a => ((u32::from(v) * 255 + u32::from(a) / 2) / u32::from(a)).min(255) as u8,
        };
        rgba.extend_from_slice(&[straight(p[2]), straight(p[1]), straight(p[0]), alpha]);
    }
    image::RgbaImage::from_raw(width as u32, height as u32, rgba).map(image::DynamicImage::ImageRgba8)
}

/// Fits the image into `size`×`size`: PNG for icons (transparency), JPEG
/// for screenshots (a tenth of the bytes). A CgBI PNG always becomes a
/// plain one.
fn shrink(bytes: &[u8], size: u32) -> Shrunk {
    let apple = crushed(bytes);
    let img = if apple {
        uncrush(bytes)
    } else {
        // Bounded: Minis's shell has little memory, and iOS takes some back
        // in the background.
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(3000);
        limits.max_image_height = Some(3000);
        limits.max_alloc = Some(40 << 20);
        image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().ok()
            .and_then(|mut reader| {
                reader.limits(limits);
                reader.decode().ok()
            })
    };
    let Some(img) = img else { return Shrunk::Unreadable };
    let fits = img.width() <= size && img.height() <= size;
    if fits && !apple {
        return Shrunk::Fits;
    }
    let small = if fits { img } else { img.thumbnail(size, size) };
    let mut out = std::io::Cursor::new(Vec::new());
    let written = if size == ICON {
        small.write_to(&mut out, image::ImageFormat::Png)
    } else {
        image::DynamicImage::ImageRgb8(small.into_rgb8()).write_to(&mut out, image::ImageFormat::Jpeg)
    };
    match written {
        Ok(()) => Shrunk::Smaller(out.into_inner()),
        Err(_) => Shrunk::Unreadable,
    }
}

pub fn cached(url: &str, size: u32) -> Option<Vec<u8>> {
    std::fs::read(path(url, size)).ok().filter(|b| !b.is_empty())
}

/// The icon address of an app added as the IPA at `path` (in ipas/).
pub fn ipa_icon_url(path: &Path) -> String {
    format!("ipa:{}", path.file_name().unwrap_or_default().to_string_lossy())
}

/// Where the pictures the user chose as app icons are kept (the page sends
/// them square, 512 px): an app signed again later (an update) keeps its icon.
pub fn custom_dir() -> PathBuf {
    state::path("app-icons")
}

/// The picture called `name` in app-icons/ (names BariStore made only).
pub fn custom_icon(name: &str) -> Option<Vec<u8>> {
    let ours = name.len() == 28 && name.ends_with(".png") && name[..24].bytes().all(|b| b.is_ascii_hexdigit());
    ours.then(|| std::fs::read(custom_dir().join(name)).ok()).flatten()
}

pub fn custom_icon_url(name: &str) -> String {
    format!("custom:{name}")
}

/// Keeps a picture the page sent as an app's icon, once it is known to be
/// a PNG or JPEG of at most 2048 px; its name in app-icons/.
pub fn save_custom_icon(bytes: &[u8]) -> Result<String, String> {
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(2048);
    limits.max_image_height = Some(2048);
    limits.max_alloc = Some(40 << 20);
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().map_err(|e| e.to_string())?;
    reader.limits(limits);
    reader.decode().map_err(|_| "That picture cannot be read: choose a PNG or JPEG.".to_string())?;
    let name = format!("{}.png", hex::encode(rand::random::<[u8; 12]>()));
    std::fs::create_dir_all(custom_dir()).map_err(|e| e.to_string())?;
    std::fs::write(custom_dir().join(&name), bytes).map_err(|e| e.to_string())?;
    Ok(name)
}

/// The picture's bytes as they are: from the web, or the app icon inside
/// an IPA BariStore keeps ("ipa:<file name in ipas/>").
async fn original(http: &reqwest::Client, url: &str) -> Result<Vec<u8>, String> {
    if let Some(name) = url.strip_prefix("ipa:") {
        if name.contains('/') || !name.ends_with(".ipa") {
            return Err("not an IPA BariStore keeps".into());
        }
        let ipa = state::path("ipas").join(name);
        return tokio::task::spawn_blocking(move || crate::sign::bundle::icon(&ipa)).await.map_err(|e| e.to_string())?;
    }
    if let Some(name) = url.strip_prefix("custom:") {
        return custom_icon(name).ok_or_else(|| "no such icon".into());
    }
    if !url.starts_with("https://") && !url.starts_with("http://") {
        return Err("not a web address".into());
    }
    let resp = http.get(url).timeout(Duration::from_secs(30)).send().await
        .and_then(|r| r.error_for_status()).map_err(|e| e.to_string())?;
    Ok(resp.bytes().await.map_err(|e| e.to_string())?.to_vec())
}

/// The image at `url` fitted into `size` (one of SIZES), from the cache or
/// made (and cached) now. An icon that cannot be decoded is kept as it is
/// (SVG, WebP); a screenshot is not, it would be too big.
pub async fn get(http: &reqwest::Client, url: &str, size: u32) -> Result<Vec<u8>, String> {
    if !SIZES.contains(&size) {
        return Err("no such size".into());
    }
    if let Some(bytes) = cached(url, size) {
        return Ok(bytes);
    }
    let file = path(url, size);
    let making = MAKING.lock().unwrap_or_else(|e| e.into_inner()).entry(file.clone()).or_default().clone();
    let result = {
        let _turn = making.lock().await;
        match cached(url, size) {
            Some(bytes) => Ok(bytes),
            None => make(http, url, size, &file).await,
        }
    };
    MAKING.lock().unwrap_or_else(|e| e.into_inner()).remove(&file);
    result
}

async fn make(http: &reqwest::Client, url: &str, size: u32, file: &Path) -> Result<Vec<u8>, String> {
    let bytes = original(http, url).await?;
    if bytes.len() > MAX_BYTES || kind(&bytes) == "application/octet-stream" {
        return Err("not an image".into());
    }
    let shrunk = {
        let _turn = if size == ICON { &ICON_TURN } else { &SHOT_TURN }.acquire().await.map_err(|e| e.to_string())?;
        let original = bytes.clone();
        tokio::task::spawn_blocking(move || shrink(&original, size)).await.map_err(|e| e.to_string())?
    };
    let stored = match shrunk {
        Shrunk::Smaller(small) => small,
        Shrunk::Fits => bytes,
        Shrunk::Unreadable if size == ICON => bytes,
        Shrunk::Unreadable => return Err("the screenshot is too big or not readable".into()),
    };
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(file, &stored);
    Ok(stored)
}

/// Makes the images not cached yet at `size` (`at_once` at a time), so
/// opening the store later shows them at once.
pub async fn prefetch(urls: Vec<String>, size: u32, at_once: usize) {
    use futures_util::StreamExt;
    let http = crate::store::client();
    let missing: Vec<String> = urls.into_iter().filter(|u| !u.is_empty() && cached(u, size).is_none()).collect();
    if missing.is_empty() {
        return;
    }
    let started = std::time::Instant::now();
    let count = missing.len();
    futures_util::stream::iter(missing)
        .for_each_concurrent(at_once, |url| {
            let http = http.clone();
            async move {
                if let Err(e) = get(&http, &url, size).await {
                    logf!("icons: {url}: {e}");
                }
            }
        })
        .await;
    logf!("icons: {count} at {size} px made in {:.1} s", started.elapsed().as_secs_f64());
}

/// Keeps the pictures of `keep` (every picture the page may still show, at
/// any size) and drops the rest (apps no source lists any more, their old
/// screenshots); then the oldest while the cache is bigger than CAP.
pub fn prune(keep: &[String]) {
    let wanted: std::collections::HashSet<std::ffi::OsString> = keep.iter()
        .flat_map(|u| SIZES.iter().filter_map(move |s| path(u, *s).file_name().map(|n| n.to_owned()))).collect();
    let Ok(dir) = std::fs::read_dir(state::path("icons")) else { return };
    let (mut freed, mut kept) = (0u64, Vec::new());
    for e in dir.flatten() {
        let Ok(meta) = e.metadata() else { continue };
        if wanted.contains(&e.file_name()) {
            kept.push((meta.modified().unwrap_or(std::time::UNIX_EPOCH), meta.len(), e.path()));
        } else if std::fs::remove_file(e.path()).is_ok() {
            freed += meta.len();
        }
    }
    let mut total: u64 = kept.iter().map(|k| k.1).sum();
    kept.sort();
    for (_, len, file) in kept {
        if total <= CAP {
            break;
        }
        if std::fs::remove_file(file).is_ok() {
            total -= len;
            freed += len;
        }
    }
    if freed > 0 {
        logf!("icons: {} KB of pictures no longer shown removed", freed / 1000);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn big_png_is_shrunk_and_small_one_kept() {
        let mut big = std::io::Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(512, 512, image::Rgba([20, 60, 200, 255]))
            .write_to(&mut big, image::ImageFormat::Png).unwrap();
        let Shrunk::Smaller(small) = shrink(big.get_ref(), ICON) else { panic!("not shrunk") };
        assert_eq!(kind(&small), "image/png");
        let img = image::load_from_memory(&small).unwrap();
        assert_eq!((img.width(), img.height()), (ICON, ICON));
        let mut tiny = std::io::Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(64, 64, image::Rgba([0, 0, 0, 255]))
            .write_to(&mut tiny, image::ImageFormat::Png).unwrap();
        assert!(matches!(shrink(tiny.get_ref(), ICON), Shrunk::Fits));
        assert!(matches!(shrink(b"not an image", ICON), Shrunk::Unreadable));
    }

    /// An Xcode-style CgBI PNG, made from a plain one: its filtered rows
    /// with red and blue swapped (PNG filters work channel by channel),
    /// deflated without zlib's wrapper, behind a CgBI chunk.
    fn crush(img: &image::RgbaImage) -> Vec<u8> {
        use std::io::{Read, Write};
        let mut plain = std::io::Cursor::new(Vec::new());
        img.write_to(&mut plain, image::ImageFormat::Png).unwrap();
        let plain = plain.into_inner();
        let (mut at, mut ihdr, mut zlib) = (8, Vec::new(), Vec::new());
        while at < plain.len() {
            let len = u32::from_be_bytes(plain[at..at + 4].try_into().unwrap()) as usize;
            match &plain[at + 4..at + 8] {
                b"IHDR" => ihdr = plain[at..at + 12 + len].to_vec(),
                b"IDAT" => zlib.extend_from_slice(&plain[at + 8..at + 8 + len]),
                _ => {}
            }
            at += 12 + len;
        }
        let mut rows = Vec::new();
        flate2::read::ZlibDecoder::new(&zlib[..]).read_to_end(&mut rows).unwrap();
        let stride = img.width() as usize * 4 + 1;
        for row in rows.chunks_mut(stride) {
            for px in row[1..].chunks_mut(4) {
                px.swap(0, 2);
            }
        }
        let mut raw = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
        raw.write_all(&rows).unwrap();
        let raw = raw.finish().unwrap();
        let chunk = |kind: &[u8], body: &[u8]| [&(body.len() as u32).to_be_bytes()[..], kind, body, &[0; 4]].concat();
        [&plain[..8], &chunk(b"CgBI", &[0x50, 0, 0x20, 2]), &ihdr, &chunk(b"IDAT", &raw), &chunk(b"IEND", b"")].concat()
    }

    #[test]
    fn apple_crushed_icons_are_read() {
        let img = image::RgbaImage::from_fn(180, 180, |x, y| image::Rgba([(x * 7 % 256) as u8, (y * 3 % 256) as u8,
                                                                         ((x ^ y) % 256) as u8, 255]));
        let crushed_png = crush(&img);
        assert!(crushed(&crushed_png));
        assert!(image::load_from_memory(&crushed_png).is_err(), "a plain decoder cannot read CgBI");
        assert_eq!(uncrush(&crushed_png).unwrap().to_rgba8(), img);
        // Premultiplied alpha comes back straight.
        let half = image::RgbaImage::from_pixel(4, 1, image::Rgba([100, 50, 200, 128]));
        let mut stored = half.clone();
        for p in stored.pixels_mut() {
            for c in 0..3 {
                p[c] = (u32::from(p[c]) * 128 / 255) as u8;
            }
        }
        let back = uncrush(&crush(&stored)).unwrap().to_rgba8();
        for (a, b) in back.pixels().zip(half.pixels()) {
            assert!(a.0.iter().zip(b.0).all(|(x, y)| x.abs_diff(y) <= 2), "{a:?} vs {b:?}");
        }
        // Small enough already, but still made a plain PNG.
        let Shrunk::Smaller(icon) = shrink(&crushed_png, ICON) else { panic!("not converted") };
        assert_eq!(image::load_from_memory(&icon).unwrap().width(), ICON);
        let Shrunk::Smaller(icon) = shrink(&crush(&half), ICON) else { panic!("not converted") };
        assert_eq!(image::load_from_memory(&icon).unwrap().width(), 4);
    }

    #[test]
    fn screenshot_becomes_a_small_jpeg() {
        let mut shot = std::io::Cursor::new(Vec::new());
        image::RgbImage::from_pixel(1290, 2796, image::Rgb([240, 240, 245]))
            .write_to(&mut shot, image::ImageFormat::Png).unwrap();
        let Shrunk::Smaller(small) = shrink(shot.get_ref(), 640) else { panic!("not shrunk") };
        assert_eq!(kind(&small), "image/jpeg");
        let img = image::load_from_memory(&small).unwrap();
        assert_eq!((img.width(), img.height()), (295, 640));
    }
}
