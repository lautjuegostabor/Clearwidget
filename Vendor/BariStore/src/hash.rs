//! SHA-1, SHA-256 and SHA-384 for what hashes a lot: signing (every file of
//! an IPA, every page of its binaries), checking a download, and the
//! tunnel's record MACs. On aarch64 they use the ARMv8 SHA instructions:
//! Minis's emulator (OpenMinis/ish-arm64, asbestos crypto.S) runs those
//! natively, but the HWCAP it reports (0x11f) leaves them out, so the
//! RustCrypto crates took their software path there, at emulated speed.
//! SHA-1 and SHA-256 are enabled at build time (.cargo/config.toml); SHA-512
//! is chosen at run time, in Minis or where HWCAP reports it, so the rest of
//! the program is never built for its extension. Same digests as the sha1
//! and sha2 crates (tests); other CPUs use those crates.

#[cfg(not(target_arch = "aarch64"))]
pub use sha1::Sha1;
#[cfg(not(target_arch = "aarch64"))]
pub use sha2::{Sha256, Sha384};

#[cfg(target_arch = "aarch64")]
pub use armv8::{Sha1, Sha256, Sha384};

#[cfg(target_arch = "aarch64")]
mod armv8 {
    use core::arch::aarch64::*;
    use sha2::digest::block_buffer::Eager;
    use sha2::digest::core_api::{Block, BlockSizeUser, Buffer, BufferKindUser, CoreWrapper, FixedOutputCore,
                                 OutputSizeUser, Reset, UpdateCore};
    use sha2::digest::typenum::{U128, U20, U32, U48, U64};
    use sha2::digest::{HashMarker, Output};

    pub type Sha1 = CoreWrapper<Sha1Core>;
    pub type Sha256 = CoreWrapper<Sha256Core>;
    pub type Sha384 = CoreWrapper<Sha384Core>;

    /// SHA-1 and SHA-256 instructions (FEAT_SHA1, FEAT_SHA256).
    fn sha2_instructions() -> bool {
        std::arch::is_aarch64_feature_detected!("sha2")
    }

    /// SHA-512 instructions (FEAT_SHA512): reported by HWCAP, or Minis,
    /// whose emulator runs them (natively, or in its own C on hosts without
    /// them).
    fn sha512_instructions() -> bool {
        static FOUND: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        *FOUND.get_or_init(|| std::arch::is_aarch64_feature_detected!("sha3") || in_minis())
    }

    /// Minis's kernel names itself "…-ish" (OpenMinis/ish-arm64 kernel/uname.c).
    fn in_minis() -> bool {
        // SAFETY: uname fills the zeroed struct; release is NUL-terminated.
        unsafe {
            let mut name: libc::utsname = std::mem::zeroed();
            libc::uname(&mut name) == 0 && std::ffi::CStr::from_ptr(name.release.as_ptr()).to_bytes().ends_with(b"-ish")
        }
    }

    fn blocks64<T: BlockSizeUser<BlockSize = U64>>(blocks: &[Block<T>]) -> &[[u8; 64]] {
        // SAFETY: GenericArray<u8, U64> has the layout of [u8; 64].
        unsafe { std::slice::from_raw_parts(blocks.as_ptr().cast(), blocks.len()) }
    }

    fn be_out<const N: usize>(words: &[u32; N], out: &mut [u8]) {
        for (chunk, w) in out.chunks_exact_mut(4).zip(words) {
            chunk.copy_from_slice(&w.to_be_bytes());
        }
    }

    // --- SHA-1 -----------------------------------------------------------

    #[derive(Clone)]
    pub struct Sha1Core {
        state: [u32; 5],
        blocks: u64,
    }

    impl HashMarker for Sha1Core {}
    impl BlockSizeUser for Sha1Core { type BlockSize = U64; }
    impl BufferKindUser for Sha1Core { type BufferKind = Eager; }
    impl OutputSizeUser for Sha1Core { type OutputSize = U20; }

    impl Default for Sha1Core {
        fn default() -> Self {
            Sha1Core { state: [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0], blocks: 0 }
        }
    }

    impl Reset for Sha1Core {
        fn reset(&mut self) {
            *self = Self::default();
        }
    }

    impl UpdateCore for Sha1Core {
        fn update_blocks(&mut self, blocks: &[Block<Self>]) {
            self.blocks += blocks.len() as u64;
            sha1_compress(&mut self.state, blocks);
        }
    }

    impl FixedOutputCore for Sha1Core {
        fn finalize_fixed_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>) {
            let bits = (self.blocks * 64 + buffer.get_pos() as u64) * 8;
            let mut state = self.state;
            buffer.len64_padding_be(bits, |b| sha1_compress(&mut state, std::slice::from_ref(b)));
            be_out(&state, out);
        }
    }

    fn sha1_compress(state: &mut [u32; 5], blocks: &[Block<Sha1Core>]) {
        if sha2_instructions() {
            // SAFETY: the CPU runs the SHA-1 instructions.
            unsafe { sha1_blocks(state, blocks64::<Sha1Core>(blocks)) }
        } else {
            sha1::compress(state, blocks);
        }
    }

    /// Four rounds per instruction; W[t] four at a time with SHA1SU0/SU1.
    #[target_feature(enable = "sha2")]
    unsafe fn sha1_blocks(state: &mut [u32; 5], blocks: &[[u8; 64]]) {
        const K: [u32; 4] = [0x5A82_7999, 0x6ED9_EBA1, 0x8F1B_BCDC, 0xCA62_C1D6];
        let mut abcd = vld1q_u32(state.as_ptr());
        let mut e = state[4];
        for block in blocks {
            let (abcd0, e0) = (abcd, e);
            let mut w = [vdupq_n_u32(0); 4];
            for (i, v) in w.iter_mut().enumerate() {
                *v = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(block[16 * i..].as_ptr())));
            }
            for i in 0..20 {
                if i >= 4 {
                    w[i % 4] = vsha1su1q_u32(vsha1su0q_u32(w[i % 4], w[(i + 1) % 4], w[(i + 2) % 4]), w[(i + 3) % 4]);
                }
                let wk = vaddq_u32(w[i % 4], vdupq_n_u32(K[i / 5]));
                let next = vsha1h_u32(vgetq_lane_u32(abcd, 0));
                abcd = match i / 5 {
                    0 => vsha1cq_u32(abcd, e, wk),
                    2 => vsha1mq_u32(abcd, e, wk),
                    _ => vsha1pq_u32(abcd, e, wk),
                };
                e = next;
            }
            abcd = vaddq_u32(abcd, abcd0);
            e = e.wrapping_add(e0);
        }
        vst1q_u32(state.as_mut_ptr(), abcd);
        state[4] = e;
    }

    // --- SHA-256 ---------------------------------------------------------

    const K256: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    #[derive(Clone)]
    pub struct Sha256Core {
        state: [u32; 8],
        blocks: u64,
    }

    impl HashMarker for Sha256Core {}
    impl BlockSizeUser for Sha256Core { type BlockSize = U64; }
    impl BufferKindUser for Sha256Core { type BufferKind = Eager; }
    impl OutputSizeUser for Sha256Core { type OutputSize = U32; }

    impl Default for Sha256Core {
        fn default() -> Self {
            Sha256Core { state: [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                                 0x5be0cd19], blocks: 0 }
        }
    }

    impl Reset for Sha256Core {
        fn reset(&mut self) {
            *self = Self::default();
        }
    }

    impl UpdateCore for Sha256Core {
        fn update_blocks(&mut self, blocks: &[Block<Self>]) {
            self.blocks += blocks.len() as u64;
            sha256_compress(&mut self.state, blocks);
        }
    }

    impl FixedOutputCore for Sha256Core {
        fn finalize_fixed_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>) {
            let bits = (self.blocks * 64 + buffer.get_pos() as u64) * 8;
            let mut state = self.state;
            buffer.len64_padding_be(bits, |b| sha256_compress(&mut state, std::slice::from_ref(b)));
            be_out(&state, out);
        }
    }

    fn sha256_compress(state: &mut [u32; 8], blocks: &[Block<Sha256Core>]) {
        if sha2_instructions() {
            // SAFETY: the CPU runs the SHA-256 instructions.
            unsafe { sha256_blocks(state, blocks64::<Sha256Core>(blocks)) }
        } else {
            sha2::compress256(state, blocks);
        }
    }

    /// Four rounds per SHA256H/H2 pair; W[t] four at a time with SU0/SU1.
    #[target_feature(enable = "sha2")]
    unsafe fn sha256_blocks(state: &mut [u32; 8], blocks: &[[u8; 64]]) {
        let mut abcd = vld1q_u32(state.as_ptr());
        let mut efgh = vld1q_u32(state[4..].as_ptr());
        for block in blocks {
            let (abcd0, efgh0) = (abcd, efgh);
            let mut w = [vdupq_n_u32(0); 4];
            for (i, v) in w.iter_mut().enumerate() {
                *v = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(block[16 * i..].as_ptr())));
            }
            for i in 0..16 {
                if i >= 4 {
                    w[i % 4] = vsha256su1q_u32(vsha256su0q_u32(w[i % 4], w[(i + 1) % 4]), w[(i + 2) % 4], w[(i + 3) % 4]);
                }
                let wk = vaddq_u32(w[i % 4], vld1q_u32(K256[4 * i..].as_ptr()));
                let before = abcd;
                abcd = vsha256hq_u32(abcd, efgh, wk);
                efgh = vsha256h2q_u32(efgh, before, wk);
            }
            abcd = vaddq_u32(abcd, abcd0);
            efgh = vaddq_u32(efgh, efgh0);
        }
        vst1q_u32(state.as_mut_ptr(), abcd);
        vst1q_u32(state[4..].as_mut_ptr(), efgh);
    }

    // --- SHA-384 (SHA-512's rounds) ------------------------------------------

    const K512: [u64; 80] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538,
        0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe,
        0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
        0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5, 0x983e5152ee66dfab,
        0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
        0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
        0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53,
        0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
        0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c,
        0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6,
        0x113f9804bef90dae, 0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
        0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ];

    #[derive(Clone)]
    pub struct Sha384Core {
        state: [u64; 8],
        blocks: u128,
    }

    impl HashMarker for Sha384Core {}
    impl BlockSizeUser for Sha384Core { type BlockSize = U128; }
    impl BufferKindUser for Sha384Core { type BufferKind = Eager; }
    impl OutputSizeUser for Sha384Core { type OutputSize = U48; }

    impl Default for Sha384Core {
        fn default() -> Self {
            Sha384Core { state: [0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
                                 0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4],
                         blocks: 0 }
        }
    }

    impl Reset for Sha384Core {
        fn reset(&mut self) {
            *self = Self::default();
        }
    }

    impl UpdateCore for Sha384Core {
        fn update_blocks(&mut self, blocks: &[Block<Self>]) {
            self.blocks += blocks.len() as u128;
            sha512_compress(&mut self.state, blocks);
        }
    }

    impl FixedOutputCore for Sha384Core {
        fn finalize_fixed_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>) {
            let bits = (self.blocks * 128 + buffer.get_pos() as u128) * 8;
            let mut state = self.state;
            buffer.len128_padding_be(bits, |b| sha512_compress(&mut state, std::slice::from_ref(b)));
            for (chunk, w) in out.chunks_exact_mut(8).zip(state) {
                chunk.copy_from_slice(&w.to_be_bytes());
            }
        }
    }

    fn sha512_compress(state: &mut [u64; 8], blocks: &[Block<Sha384Core>]) {
        if sha512_instructions() {
            // SAFETY: GenericArray<u8, U128> has the layout of [u8; 128], and
            // the CPU runs the SHA-512 instructions.
            unsafe {
                let raw = std::slice::from_raw_parts(blocks.as_ptr().cast::<[u8; 128]>(), blocks.len());
                sha512_blocks(state, raw);
            }
        } else {
            sha2::compress512(state, blocks);
        }
    }

    /// Two rounds per SHA512H/H2 pair. The four state pairs (ab, cd, ef,
    /// gh) change roles every step and come back after four; W[t] two at a
    /// time with SU0/SU1.
    #[target_feature(enable = "sha3")]
    unsafe fn sha512_blocks(state: &mut [u64; 8], blocks: &[[u8; 128]]) {
        let mut v = [vdupq_n_u64(0); 4];
        for (i, x) in v.iter_mut().enumerate() {
            *x = vld1q_u64(state[2 * i..].as_ptr());
        }
        for block in blocks {
            let start = v;
            let mut w = [vdupq_n_u64(0); 8];
            for (i, x) in w.iter_mut().enumerate() {
                *x = vreinterpretq_u64_u8(vrev64q_u8(vld1q_u8(block[16 * i..].as_ptr())));
            }
            for k in 0..40 {
                if k >= 8 {
                    w[k % 8] = vsha512su1q_u64(vsha512su0q_u64(w[k % 8], w[(k + 1) % 8]), w[(k + 7) % 8],
                                               vextq_u64(w[(k + 4) % 8], w[(k + 5) % 8], 1));
                }
                let x = 3 - k % 4;
                let (x1, x2, x3) = ((x + 3) % 4, (x + 2) % 4, (x + 1) % 4);
                let wk = vaddq_u64(w[k % 8], vld1q_u64(K512[2 * k..].as_ptr()));
                let sum = vaddq_u64(vextq_u64(wk, wk, 1), v[x]);
                let mid = vsha512hq_u64(sum, vextq_u64(v[x1], v[x], 1), vextq_u64(v[x2], v[x1], 1));
                v[x] = vsha512h2q_u64(mid, v[x2], v[x3]);
                v[x2] = vaddq_u64(v[x2], mid);
            }
            for (x, s) in v.iter_mut().zip(start) {
                *x = vaddq_u64(*x, s);
            }
        }
        for (i, x) in v.iter().enumerate() {
            vst1q_u64(state[2 * i..].as_mut_ptr(), *x);
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use sha2::digest::generic_array::GenericArray;

        /// The instructions and the software give the same state, block by
        /// block (qemu-aarch64 runs both).
        #[test]
        fn instructions_match_software() {
            let data: Vec<u8> = (0..128 * 9).map(|i| (i * 7 + i / 13) as u8).collect();
            let b64: Vec<GenericArray<u8, U64>> = data.chunks(64).map(|c| GenericArray::clone_from_slice(c)).collect();
            let b128: Vec<GenericArray<u8, U128>> = data.chunks(128).map(|c| GenericArray::clone_from_slice(c)).collect();
            let raw64: Vec<[u8; 64]> = data.chunks(64).map(|c| c.try_into().unwrap()).collect();
            let raw128: Vec<[u8; 128]> = data.chunks(128).map(|c| c.try_into().unwrap()).collect();
            if sha2_instructions() {
                let (mut a, mut b) = (Sha1Core::default().state, Sha1Core::default().state);
                unsafe { sha1_blocks(&mut a, &raw64) };
                sha1::compress(&mut b, &b64);
                assert_eq!(a, b);
                let (mut a, mut b) = (Sha256Core::default().state, Sha256Core::default().state);
                unsafe { sha256_blocks(&mut a, &raw64) };
                sha2::compress256(&mut b, &b64);
                assert_eq!(a, b);
            }
            if sha512_instructions() {
                let (mut a, mut b) = (Sha384Core::default().state, Sha384Core::default().state);
                unsafe { sha512_blocks(&mut a, &raw128) };
                sha2::compress512(&mut b, &b128);
                assert_eq!(a, b);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use sha2::Digest;

    /// Every length around the block boundaries, against the RustCrypto
    /// crates (on aarch64 these are BariStore's own; elsewhere the same).
    #[test]
    fn digests_match_rustcrypto() {
        let data: Vec<u8> = (0..1100u32).map(|i| (i * 31 + 7) as u8).collect();
        for len in (0..300).chain([511, 512, 1000, 1100]) {
            let part = &data[..len];
            assert_eq!(super::Sha1::digest(part)[..], sha1::Sha1::digest(part)[..], "SHA-1 of {len} bytes");
            assert_eq!(super::Sha256::digest(part)[..], sha2::Sha256::digest(part)[..], "SHA-256 of {len} bytes");
            assert_eq!(super::Sha384::digest(part)[..], sha2::Sha384::digest(part)[..], "SHA-384 of {len} bytes");
        }
        // Fed in pieces, as the readers do.
        let mut h = super::Sha256::new();
        for piece in data.chunks(37) {
            h.update(piece);
        }
        assert_eq!(h.finalize()[..], sha2::Sha256::digest(&data)[..]);
        use hmac::Mac;
        let mut mac = <hmac::Hmac<super::Sha384> as Mac>::new_from_slice(b"key").unwrap();
        mac.update(&data);
        let mut theirs = <hmac::Hmac<sha2::Sha384> as Mac>::new_from_slice(b"key").unwrap();
        theirs.update(&data);
        assert_eq!(mac.finalize().into_bytes()[..], theirs.finalize().into_bytes()[..]);
    }
}
