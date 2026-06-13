//! Length-prefixed (AVCC / HVCC) NAL-unit iteration — a port of Swift `NALUnit`.
//!
//! `VideoToolbox` emits an encoded frame as one or more NAL units, each preceded by a
//! big-endian length prefix (4 bytes in the configs Aislopdesk ships). The host hands
//! this the raw block-buffer bytes; the client reconstructs the same AVCC layout from
//! reassembled fragments before feeding the decoder.

/// The length-prefix width, in bytes. AVCC/HVCC use 4 in the encoder configs.
pub const LENGTH_PREFIX_SIZE: usize = 4;

/// Splits an AVCC byte buffer into its individual NAL units (payloads only, length
/// prefixes stripped), returned as zero-copy borrows into `avcc`.
///
/// Parsing is defensive: a prefix that claims more bytes than remain, or a
/// non-positive length, terminates iteration without panicking (matching the Swift
/// `split` which simply `break`s on a bad prefix — a truncated tail is treated as "no
/// more whole NALUs", never a crash).
#[must_use]
pub fn split(avcc: &[u8]) -> Vec<&[u8]> {
    let mut units = Vec::new();
    let count = avcc.len();
    let mut offset = 0usize;
    while offset + LENGTH_PREFIX_SIZE <= count {
        let p = offset;
        let length = u32::from_be_bytes([avcc[p], avcc[p + 1], avcc[p + 2], avcc[p + 3]]) as usize;
        // guard length > 0 && offset + 4 + length <= count (checked so a crafted huge
        // length can never overflow the index arithmetic on a 32-bit target).
        let Some(end) = offset
            .checked_add(LENGTH_PREFIX_SIZE)
            .and_then(|s| s.checked_add(length))
        else {
            break;
        };
        if length == 0 || end > count {
            break;
        }
        let start = p + LENGTH_PREFIX_SIZE;
        units.push(&avcc[start..end]);
        offset = end;
    }
    units
}

/// Re-assembles NAL-unit payloads back into one AVCC byte buffer (each unit
/// re-prefixed with its 4-byte big-endian length). Inverse of [`split`].
#[must_use]
pub fn join<'a, I>(units: I) -> Vec<u8>
where
    I: IntoIterator<Item = &'a [u8]>,
{
    let mut out = Vec::new();
    for unit in units {
        // A single NAL unit never approaches 4 GiB (per-frame, MTU-reassembled), so the
        // u32 length prefix holds by construction; asserted in debug, panic-free in release.
        debug_assert!(
            u32::try_from(unit.len()).is_ok(),
            "NAL unit exceeds u32 length"
        );
        out.extend_from_slice(&(unit.len() as u32).to_be_bytes());
        out.extend_from_slice(unit);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Mirrors `NALUnitTests`: split/join round-trips, and defensive parsing of a
    /// truncated / zero-length / over-long prefix.
    #[test]
    fn split_join_round_trip() {
        let units: Vec<&[u8]> = vec![&[1, 2, 3], &[4, 5], &[6]];
        let avcc = join(units.iter().copied());
        let back = split(&avcc);
        assert_eq!(back, units);
    }

    #[test]
    fn join_prefixes_each_unit_with_be_length() {
        let avcc = join([&[0xAA, 0xBB][..]]);
        assert_eq!(avcc, vec![0, 0, 0, 2, 0xAA, 0xBB]);
    }

    #[test]
    fn split_empty_is_empty() {
        assert!(split(&[]).is_empty());
    }

    #[test]
    fn split_stops_on_truncated_tail() {
        // A valid unit followed by a length prefix promising more than is present.
        let mut avcc = vec![0, 0, 0, 1, 0x42];
        avcc.extend_from_slice(&[0, 0, 0, 9, 1, 2]); // claims 9, only 2 present
        let units = split(&avcc);
        assert_eq!(units, vec![&[0x42u8][..]]);
    }

    #[test]
    fn split_stops_on_zero_length_prefix() {
        let avcc = vec![0, 0, 0, 0, 1, 2, 3];
        assert!(split(&avcc).is_empty());
    }

    #[test]
    fn split_ignores_trailing_partial_prefix() {
        // Trailing 3 bytes cannot hold a 4-byte prefix → ignored.
        let mut avcc = join([&[9u8][..]]);
        avcc.extend_from_slice(&[1, 2, 3]);
        assert_eq!(split(&avcc), vec![&[9u8][..]]);
    }
}
