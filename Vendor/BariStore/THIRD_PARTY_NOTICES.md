# Third-party notices

BariStore's code is MIT and written for this project. No third-party source
code is copied into it.

## Libraries in the binary

All are permissive. Generated with
`cargo tree -e normal --target aarch64-unknown-linux-musl --format '{p} {l}'`
(194 crates on 2026-11-24):

| Licence | Crates |
|---|---|
| MIT and/or Apache-2.0 (incl. 0BSD/Zlib/BSL-1.0/Unlicense alternatives) | 166 |
| Unicode-3.0 (ICU data via `url`/`idna`) | 18 |
| BSD-3-Clause | 4 |
| ISC / Apache-2.0 AND ISC (`ring`) | 3 |
| Zlib (`zlib-rs`, flate2's deflate) | 1 |
| CDLA-Permissive-2.0 (`webpki-roots` certificate data) | 2 |

Main ones: `tokio`, `reqwest`, `rustls`, `ring`, `webpki-roots`,
`tokio-tungstenite`, `plist`, `serde`, `zip`, `image` (icon and screenshot thumbnails, app icons the
user picks), `flate2` with `zlib-rs` (the IPA's entries, the CgBI icons Xcode puts in apps), RustCrypto (`sha1`, `sha2`, `hmac`,
`hkdf`, `pbkdf2`, `aes`, `cbc`, `aes-gcm`, `chacha20poly1305`, `rsa`),
dalek (`ed25519-dalek`, `x25519-dalek`), `num-bigint`, `uuid`, `libc` (signals
for the supervisor). Each crate's
licence text is in its source package on crates.io.

Test-only (not in the binary): `idevice-srp` (MIT OR Apache-2.0, an SRP oracle)
and `smoltcp` (0BSD, a TCP peer).

## Apple certificates (`assets/certs/`)

Apple Root CA, Apple Root CA - G3 and the Apple Worldwide Developer Relations
intermediates G2-G6: Apple's public CA certificates. Each intermediate verifies
against one of the two roots; Apple Root CA matches the fingerprint Apple
publishes. Used to trust gsa.apple.com and to complete code-signing chains.

## Protocol references (read, not copied)

| Project | Licence | Used for |
|---|---|---|
| [jkcoxson/idevice](https://github.com/jkcoxson/idevice) | MIT | RemotePairing, TLS-PSK tunnel, RemoteXPC (file transfers, flow control), services, misagent, cryptexd, TSS, CoreDevice app service, debugserver; its TCP stack `jktcp` for MSS/window choices |
| [nab138/isideload](https://github.com/nab138/isideload) | MIT | anisette v3, GrandSlam, developer services, app groups, Increased Memory Limit, ALTCertificate.p12 placement |
| [nab138/iloader](https://github.com/nab138/iloader) | MIT | the advertised client info fallback (2.4.2) |
| [SideStore/SideStore](https://github.com/SideStore/SideStore) | AGPL-3.0 | behaviour only: how it finds its signing certificate (ALTCertificateID, ALTCertificate.p12), its refresh (new profiles through misagent), its source format's beta tracks (`releaseChannels`) |
| [FrizzleM/siboot](https://github.com/FrizzleM/siboot) | MIT (stated in Cargo.toml; no LICENSE file) | how Open Minis keeps a pairing alive (minis-bonjour, apple-player) |
| [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis) | GPL-3.0 | documented interface of the `minis-*` / `apple-*` commands (`apple-open` included); behaviour of the player sheet, of `apple-speak`'s audio session, of its browser (only http(s)/about/blob/minis navigations) and of where `/var/minis/shared` is mounted |
| [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer) | AGPL-3.0 | behaviour only: its `livecontainer://certificate?cert=…&password=…` import, its `livecontainer://install?url=…` (downloads an IPA into LiveContainer; plain HTTP allowed by its ATS settings) and `livecontainer://source?url=…` (adds an AltSource to its Sources tab) links, where it keeps its sources (`LCAltStoreSourceURLs`), that plain LiveContainer reads no pairing file, and that its ZSign opens a .p12 with OpenSSL 3 |
| [OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64) | GPL-3.0 | behaviour only: the HWCAP its kernel reports (kernel/exec.c), that its emulator runs the SHA-1/SHA-256/SHA-512 and CRC32 instructions natively (asbestos crypto.S), its uname release ("-ish") |
| [RustCrypto/hashes](https://github.com/RustCrypto/hashes) | MIT OR Apache-2.0 | how its aarch64 backends drive the SHA-256/SHA-512 instructions (src/hash.rs has its own) |
| [nanofuxion/Whetstone](https://github.com/nanofuxion/Whetstone) | MIT | what its JITProbe tests (RWX, RW→RX, MAP_JIT), to explain its result after JIT |
| FrizzleM/SideInstaller | non-commercial | documented behaviour only: where SideStore / LiveContainer / AltStore read a pairing file; which client info Apple accepts (Oct–Nov 2026) |
| StikDebug/StikDebug | AGPL-3.0 | behaviour only: pairing-file destination, which DDI and where from, the JIT flow and what universal.js / legacy.js do (reimplemented, not copied) |
| [doronz88/DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) | Apple's images | downloaded at use time, not redistributed |

The apps BariStore offers (AltStore, SideStore, LiveContainer and every app in a
user's AltSources) are downloaded from their publishers at install time; none
is redistributed here.

## Logo and screenshots

`assets/baristore.svg`: BariStore's logo, provided by the project owner;
`docs/logo.png` is rendered from it.

`docs/screens/`: screenshots of BariStore's own page. The app icons and app
screenshots inside them come from the apps' public sources and belong to
their publishers.

Featured shows SideStore's and AltStore's app icons by linking to them in
their projects' GitHub repositories; they are not copied here.
