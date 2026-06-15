//! Behavioural + characterization tests for the host output sniffer (cross-checked against
//! the Swift shell's `HostOutputSnifferTests` / `…CharacterizationTests` suites).

use super::*;
use crate::terminal::{CommandStatus, WireMessage};

// Control bytes used in the test harness.
const ESC: u8 = 0x1B;
const BEL: u8 = 0x07;

/// Concatenates byte fragments into one stream (Swift tests build streams with `+`).
fn cat(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for p in parts {
        out.extend_from_slice(p);
    }
    out
}

/// `ESC ] 133 ; <mark> BEL` — matches the Swift shell's `osc133(_:)` helper.
fn osc133(mark: &str) -> Vec<u8> {
    cat(&[b"\x1b]133;", mark.as_bytes(), &[BEL]])
}

/// Feeds `bytes` to a fresh sniffer in one shot at `now_ms = 0`.
fn observe_whole(bytes: &[u8]) -> Vec<WireMessage> {
    HostOutputSniffer::new().observe(bytes, 0)
}

/// Feeds `bytes` to a fresh sniffer split into chunks of `size`, at `now_ms = 0`.
fn observe_chunked(bytes: &[u8], size: usize) -> Vec<WireMessage> {
    let mut s = HostOutputSniffer::new();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let end = (i + size).min(bytes.len());
        out.extend(s.observe(&bytes[i..end], 0));
        i = end;
    }
    out
}

fn title(s: &str) -> WireMessage {
    WireMessage::Title(s.to_owned())
}

fn idle(exit_code: Option<i32>, duration_ms: u32) -> WireMessage {
    WireMessage::CommandStatus(CommandStatus::Idle {
        exit_code,
        duration_ms,
    })
}

fn running() -> WireMessage {
    WireMessage::CommandStatus(CommandStatus::Running)
}

fn notif(t: &str, b: &str) -> WireMessage {
    WireMessage::Notification {
        title: t.to_owned(),
        body: b.to_owned(),
    }
}

fn command_only(messages: &[WireMessage]) -> Vec<WireMessage> {
    messages
        .iter()
        .filter(|m| matches!(m, WireMessage::CommandStatus(_)))
        .cloned()
        .collect()
}

fn notifications_only(messages: &[WireMessage]) -> Vec<WireMessage> {
    messages
        .iter()
        .filter(|m| matches!(m, WireMessage::Notification { .. }))
        .cloned()
        .collect()
}

// =====================================================================================
// Title / bell cases (the Swift `HostOutputSnifferTests` suite cross-checks the same).
// =====================================================================================

#[test]
fn osc0_with_bel_terminator_emits_title() {
    assert_eq!(observe_whole(b"\x1b]0;hello\x07"), vec![title("hello")]);
}

#[test]
fn osc2_with_st_terminator_emits_title() {
    assert_eq!(
        observe_whole(b"\x1b]2;my window\x1b\\"),
        vec![title("my window")]
    );
}

#[test]
fn osc0_with_st_terminator_emits_title() {
    assert_eq!(observe_whole(b"\x1b]0;both\x1b\\"), vec![title("both")]);
}

#[test]
fn osc2_with_bel_terminator_emits_title() {
    assert_eq!(observe_whole(b"\x1b]2;winbel\x07"), vec![title("winbel")]);
}

#[test]
fn osc_split_across_two_chunks() {
    let bytes = b"\x1b]0;split title\x07";
    for cut in 1..bytes.len() {
        let mut s = HostOutputSniffer::new();
        let mut out = s.observe(&bytes[..cut], 0);
        out.extend(s.observe(&bytes[cut..], 0));
        assert_eq!(out, vec![title("split title")], "split at {cut} diverged");
    }
}

#[test]
fn osc_split_every_chunk_size_equivalence() {
    let bytes = "\u{1b}]2;Claude Code — repo\u{07}".as_bytes();
    let expected = vec![title("Claude Code — repo")];
    for size in 1..=bytes.len() {
        assert_eq!(observe_chunked(bytes, size), expected, "chunk size {size}");
    }
}

#[test]
fn standalone_bel_emits_bell() {
    assert_eq!(observe_whole(&[BEL]), vec![WireMessage::Bell]);
}

#[test]
fn bel_amid_content_emits_bell() {
    assert_eq!(observe_whole(b"abc\x07def"), vec![WireMessage::Bell]);
}

#[test]
fn multiple_standalone_bels_emit_multiple_bells() {
    assert_eq!(
        observe_whole(&[BEL, BEL, BEL]),
        vec![WireMessage::Bell, WireMessage::Bell, WireMessage::Bell]
    );
}

#[test]
fn bel_terminating_osc_is_not_a_bell() {
    let msgs = observe_whole(b"\x1b]0;title via bel\x07");
    assert_eq!(msgs, vec![title("title via bel")]);
    assert!(!msgs.contains(&WireMessage::Bell));
}

#[test]
fn title_then_real_bell_are_distinguished() {
    assert_eq!(
        observe_whole(b"\x1b]0;t\x07\x07"),
        vec![title("t"), WireMessage::Bell]
    );
}

#[test]
fn unterminated_osc_then_valid_title_not_lost() {
    let bytes = cat(&[b"\x1b]0;abc", b"\x1b]2;real\x07"]);
    let msgs = observe_whole(&bytes);
    assert_eq!(msgs, vec![title("abc"), title("real")]);
    assert!(msgs.contains(&title("real")));
}

#[test]
fn unterminated_osc_then_valid_title_split_consistent() {
    let bytes = cat(&[b"\x1b]0;abc", b"\x1b]2;real\x07"]);
    let expected = vec![title("abc"), title("real")];
    for size in 1..=bytes.len() {
        assert_eq!(observe_chunked(&bytes, size), expected, "chunk size {size}");
    }
}

#[test]
fn stray_esc_in_osc_then_bel_is_not_a_bell() {
    // `ESC]0;abc` then `ESC X` (SOS introducer) then BEL (= the SOS terminator).
    let bytes = cat(&[b"\x1b]0;abc", b"\x1bX", &[BEL]]);
    assert_eq!(observe_whole(&bytes), vec![title("abc")]);
}

#[test]
fn string_sequences_swallow_embedded_bell_and_title() {
    // DCS with an embedded BEL → swallowed (no phantom bell).
    assert_eq!(observe_whole(b"\x1bPq\x07"), vec![]);
    // APC with an embedded OSC-2 title → swallowed (no title spoof).
    let apc_spoof = cat(&[b"\x1b_\x1b]2;pwned\x07", b"\x1b\\"]);
    assert_eq!(observe_whole(&apc_spoof), vec![]);
    // A REAL OSC 2 after a swallowed PM string still fires.
    let pm_then_real = cat(&[b"\x1b^junk\x07", b"\x1b]2;real\x07"]);
    assert_eq!(observe_whole(&pm_then_real), vec![title("real")]);
}

#[test]
fn double_esc_then_backslash_terminates_st() {
    let bytes = cat(&[b"\x1b]2;x", b"\x1b\x1b\\"]);
    assert_eq!(observe_whole(&bytes), vec![title("x")]);
}

#[test]
fn overlong_unterminated_osc_bounded_then_resync() {
    let junk = vec![b'x'; 10000];
    let bytes = cat(&[b"\x1b]2;", &junk, b"\x1b]0;after\x07"]);
    assert_eq!(observe_whole(&bytes), vec![title("after")]);
}

#[test]
fn overlong_osc_bounded_split_consistent() {
    let junk = vec![b'y'; 9000];
    let bytes = cat(&[b"\x1b]0;", &junk, b"\x1b]2;done\x07"]);
    let expected = vec![title("done")];
    for size in [1usize, 2, 7, 64, 128, 4096, bytes.len()] {
        assert_eq!(observe_chunked(&bytes, size), expected, "chunk size {size}");
    }
}

#[test]
fn overlong_osc_terminator_bel_is_not_a_phantom_bell() {
    let junk = vec![b'x'; 5000]; // > 4096 cap
    let bytes = cat(&[b"\x1b]2;", &junk, &[BEL], b"\x1b]0;real\x07"]);
    let msgs = observe_whole(&bytes);
    assert!(!msgs.contains(&WireMessage::Bell));
    assert_eq!(msgs, vec![title("real")]);
    for size in [1usize, 3, 64, 4096, bytes.len()] {
        assert_eq!(
            observe_chunked(&bytes, size),
            vec![title("real")],
            "chunk size {size}"
        );
    }
}

#[test]
fn overlong_osc_terminated_by_st_resyncs() {
    let junk = vec![b'x'; 5000];
    let bytes = cat(&[b"\x1b]2;", &junk, b"\x1b\\", b"\x1b]0;real\x07"]);
    let msgs = observe_whole(&bytes);
    assert!(!msgs.contains(&WireMessage::Bell));
    assert_eq!(msgs, vec![title("real")]);
}

#[test]
fn osc1_icon_name_ignored() {
    assert_eq!(observe_whole(b"\x1b]1;iconname\x07"), vec![]);
}

#[test]
fn unrelated_osc_ignored() {
    let bytes = cat(&[
        b"\x1b]8;;https://example.com\x07",
        b"\x1b]52;c;BASE64==\x07",
        b"\x1b]133;A\x07",
        b"\x1b]4;1;rgb:00/00/00\x07",
    ]);
    assert_eq!(observe_whole(&bytes), vec![]);
}

#[test]
fn osc_without_semicolon_ignored() {
    assert_eq!(observe_whole(b"\x1b]0\x07"), vec![]);
}

#[test]
fn empty_title_is_emitted_once() {
    assert_eq!(observe_whole(b"\x1b]2;\x07"), vec![title("")]);
}

#[test]
fn title_with_semicolons_in_text() {
    assert_eq!(observe_whole(b"\x1b]0;a;b;c\x07"), vec![title("a;b;c")]);
}

#[test]
fn identical_consecutive_titles_deduped() {
    let bytes = cat(&[b"\x1b]0;same\x07", b"\x1b]2;same\x07", b"\x1b]0;same\x07"]);
    assert_eq!(observe_whole(&bytes), vec![title("same")]);
}

#[test]
fn different_titles_not_deduped() {
    let bytes = cat(&[b"\x1b]0;one\x07", b"\x1b]2;two\x07", b"\x1b]0;one\x07"]);
    assert_eq!(
        observe_whole(&bytes),
        vec![title("one"), title("two"), title("one")]
    );
}

#[test]
fn interleaved_real_world_stream() {
    let stream = "welcome\n".to_owned()
        + "\u{1b}]0;Claude Code\u{07}"
        + "$ ls\n"
        + "\u{1b}[?1049h"
        + "drawing\u{1b}[2J"
        + "\u{1b}]2;vim — file.txt\u{1b}\\"
        + "\u{07}"
        + "\u{1b}[?1049l"
        + "\u{1b}]2;vim — file.txt\u{1b}\\"
        + "bye\n";
    let bytes = stream.as_bytes();
    let expected = vec![
        title("Claude Code"),
        title("vim — file.txt"),
        WireMessage::Bell,
    ];
    assert_eq!(observe_whole(bytes), expected);
    for size in 1..=bytes.len() {
        assert_eq!(observe_chunked(bytes, size), expected, "chunk size {size}");
    }
}

#[test]
fn utf8_title_and_content_pass_through() {
    let mut bytes = "café 🚀\n".as_bytes().to_vec();
    bytes.extend_from_slice(&[0xFF, 0x80, 0xC0]); // raw high-bit content
    bytes.extend_from_slice("\u{1b}]0;日本語\u{07}".as_bytes());
    assert_eq!(observe_whole(&bytes), vec![title("日本語")]);
}

#[test]
fn partial_sequence_at_end_never_misfires() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(b"\x1b]0;par", 0), vec![]);
    assert_eq!(s.observe(b"tial\x07", 0), vec![title("partial")]);
}

// =====================================================================================
// Command-status cases (the Swift `HostOutputSnifferTests` suite cross-checks the same).
// =====================================================================================

#[test]
fn c_started_then_d_finished_with_exit_and_duration() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
    // 12 seconds elapse → now_ms advances by 12_000.
    assert_eq!(
        s.observe(&osc133("D;0"), 12_000),
        vec![idle(Some(0), 12_000)]
    );
}

#[test]
fn quick_command_sub_second_duration() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
    assert_eq!(s.observe(&osc133("D;0"), 300), vec![idle(Some(0), 300)]);
}

#[test]
fn non_zero_exit_code_parsed() {
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(
        s.observe(&osc133("D;130"), 1000),
        vec![idle(Some(130), 1000)]
    );
}

#[test]
fn d_without_exit_code_yields_nil_exit() {
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(s.observe(&osc133("D"), 2000), vec![idle(None, 2000)]);
}

#[test]
fn d_extra_key_value_fields_tolerated() {
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(
        s.observe(&osc133("D;0;aid=123"), 1000),
        vec![idle(Some(0), 1000)]
    );
}

#[test]
fn d_without_preceding_c_is_ignored() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(&osc133("D;0"), 0), vec![]);
}

#[test]
fn a_and_b_marks_are_not_surfaced() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(&osc133("A"), 0), vec![]);
    assert_eq!(s.observe(&osc133("B"), 0), vec![]);
}

#[test]
fn full_prompt_cycle_yields_running_then_idle() {
    let mut s = HostOutputSniffer::new();
    let mut out = Vec::new();
    out.extend(s.observe(&osc133("D;0"), 0)); // phantom precmd D (ignored)
    out.extend(s.observe(&osc133("A"), 0)); // prompt A (ignored)
    out.extend(s.observe(&osc133("C"), 0)); // preexec C
    out.extend(s.observe(&osc133("D;0"), 11_000)); // precmd D (11s later)
    out.extend(s.observe(&osc133("A"), 11_000)); // prompt A (ignored)
    assert_eq!(out, vec![running(), idle(Some(0), 11_000)]);
}

#[test]
fn split_at_every_byte_boundary_produces_identical_events() {
    let c_bytes = osc133("C");
    let d_bytes = osc133("D;7");

    // Whole-chunk reference: C at now_ms=0, advance 5s, D at now_ms=5000.
    let mut reference = HostOutputSniffer::new();
    let mut want = reference.observe(&c_bytes, 0);
    want.extend(reference.observe(&d_bytes, 5000));

    // One byte at a time, with the SAME single advance between the two marks.
    let mut split = HostOutputSniffer::new();
    let mut got = Vec::new();
    for &b in &c_bytes {
        got.extend(split.observe(&[b], 0));
    }
    for &b in &d_bytes {
        got.extend(split.observe(&[b], 5000));
    }

    assert_eq!(got, want);
    assert_eq!(got, vec![running(), idle(Some(7), 5000)]);
}

#[test]
fn st_terminator_recognized() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(b"\x1b]133;C\x1b\\", 0), vec![running()]);
    assert_eq!(
        s.observe(b"\x1b]133;D;0\x1b\\", 1000),
        vec![idle(Some(0), 1000)]
    );
}

#[test]
fn ignores_non_133_osc_and_plain_content() {
    let mut s = HostOutputSniffer::new();
    let on_preamble = s.observe(b"\x1b]0;my title\x07user@host % ", 0);
    assert_eq!(command_only(&on_preamble), vec![]);
    assert_eq!(on_preamble, vec![title("my title")]);
    assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
}

#[test]
fn two_sequential_commands_each_measured_independently() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
    assert_eq!(s.observe(&osc133("D;0"), 3000), vec![idle(Some(0), 3000)]);
    // Second command: now_ms restarts from the D at 3000 → C at 3000, D at 10000 → 7000ms.
    assert_eq!(s.observe(&osc133("C"), 3000), vec![running()]);
    assert_eq!(s.observe(&osc133("D;1"), 10_000), vec![idle(Some(1), 7000)]);
}

// =====================================================================================
// OSC 9 / OSC 777 notification cases (the Swift `HostOutputSnifferTests` suite cross-checks the same).
// =====================================================================================

#[test]
fn osc9_emits_notification_with_empty_title() {
    assert_eq!(
        observe_whole(b"\x1b]9;build done\x07"),
        vec![notif("", "build done")]
    );
}

#[test]
fn osc9_with_st_terminator() {
    assert_eq!(
        observe_whole(b"\x1b]9;tests passed\x1b\\"),
        vec![notif("", "tests passed")]
    );
}

#[test]
fn osc777_notify_subcommand_emits_title_and_body() {
    assert_eq!(
        observe_whole(b"\x1b]777;notify;CI;all green\x07"),
        vec![notif("CI", "all green")]
    );
}

#[test]
fn osc777_body_may_contain_semicolons() {
    assert_eq!(
        observe_whole(b"\x1b]777;notify;Deploy;step 1;step 2 done\x07"),
        vec![notif("Deploy", "step 1;step 2 done")]
    );
}

#[test]
fn osc777_non_notify_subcommand_ignored() {
    assert_eq!(
        notifications_only(&observe_whole(b"\x1b]777;precmd;something\x07")),
        vec![]
    );
}

#[test]
fn osc9_empty_body_ignored() {
    assert_eq!(notifications_only(&observe_whole(b"\x1b]9;\x07")), vec![]);
}

#[test]
fn osc9_progress_bar_subtype_is_not_a_notification() {
    assert_eq!(
        notifications_only(&observe_whole(b"\x1b]9;4;1;50\x07")),
        vec![]
    );
    assert_eq!(notifications_only(&observe_whole(b"\x1b]9;4\x07")), vec![]);
    // A free-text body that only STARTS with '4' (not the `4;` subtype) still fires.
    assert_eq!(
        observe_whole(b"\x1b]9;42 tests passed\x07"),
        vec![notif("", "42 tests passed")]
    );
}

#[test]
fn notification_split_across_chunks_equivalence() {
    let raw = "\u{1b}]777;notify;Title;Body text 🚀\u{07}".as_bytes();
    let whole = observe_whole(raw);
    for size in 1..=raw.len() {
        assert_eq!(
            observe_chunked(raw, size),
            whole,
            "diverged at chunk size {size}"
        );
    }
}

#[test]
fn string_sequence_swallows_embedded_notification() {
    let dcs_spoof = b"\x1bP\x1b]9;spoofed\x07\x1b\\";
    assert_eq!(notifications_only(&observe_whole(dcs_spoof)), vec![]);
    assert_eq!(observe_whole(b"\x1b]9;real\x07"), vec![notif("", "real")]);
}

#[test]
fn string_sequences_swallow_embedded_command_status() {
    let mut s = HostOutputSniffer::new();
    let dcs_spoof = b"\x1bP\x1b]133;C\x07\x1b\\";
    assert_eq!(s.observe(dcs_spoof, 0), vec![]);
    assert_eq!(s.observe(&osc133("C"), 0), vec![running()]);
}

// =====================================================================================
// Characterization cases — expected-value asserts (the Swift `HostOutputSnifferCharacterizationTests` suite cross-checks the same).
// =====================================================================================

#[test]
fn malformed_ps_payloads() {
    assert_eq!(observe_whole(b"\x1b]133\x07"), vec![]); // bare 133, no ';'
    assert_eq!(observe_whole(b"\x1b];x\x07"), vec![]); // leading-empty Ps
    assert_eq!(observe_whole(b"\x1b]1330;C\x07"), vec![]); // Ps is "1330", not "133"
}

#[test]
fn first_prompt_phantom_d_is_ignored() {
    assert_eq!(observe_whole(b"\x1b]133;D;0\x07"), vec![]);
    // A D after the phantom + a real C measures from the REAL C (same call → 0ms).
    let cycle = b"\x1b]133;D;0\x07\x1b]133;C\x07\x1b]133;D;7\x07";
    assert_eq!(observe_whole(cycle), vec![running(), idle(Some(7), 0)]);
}

#[test]
fn stray_esc_ends_osc_then_next_osc_parses() {
    // Title flavor.
    let titles = cat(&[b"\x1b]0;abc", b"\x1b]2;real\x07"]);
    assert_eq!(observe_whole(&titles), vec![title("abc"), title("real")]);

    // Cmd flavor: stray ESC fires C, the following D emits idle (same call → 0ms).
    let marks = cat(&[b"\x1b]133;C", b"\x1b]133;D;0\x07"]);
    assert_eq!(observe_whole(&marks), vec![running(), idle(Some(0), 0)]);

    // Cross flavor: a title OSC ended by the stray ESC of a 133 mark.
    let cross = cat(&[b"\x1b]2;t", b"\x1b]133;C\x07"]);
    assert_eq!(observe_whole(&cross), vec![title("t"), running()]);
}

#[test]
fn interleaved_cross_type_stream() {
    let stream = "welcome\n".to_owned()
        + "\u{1b}]0;Claude Code\u{07}"
        + "\u{1b}]133;A\u{07}"
        + "$ make\n"
        + "\u{1b}]133;C\u{07}"
        + "\u{07}building\u{1b}[2J"
        + "\u{1b}]2;make — repo\u{1b}\\"
        + "\u{1b}]133;D;2\u{07}"
        + "\u{07}";
    let bytes = stream.as_bytes();
    let expected = vec![
        title("Claude Code"),
        running(),
        WireMessage::Bell,
        title("make — repo"),
        idle(Some(2), 0),
        WireMessage::Bell,
    ];
    assert_eq!(observe_whole(bytes), expected);
}

#[test]
fn title_dedup_across_an_interleaved_mark() {
    let bytes = cat(&[
        b"\x1b]0;same\x07",
        b"\x1b]2;same\x07", // deduped
        b"\x1b]133;C\x07",  // a mark between the dupes must not break dedup
        b"\x1b]0;same\x07", // still deduped
        b"\x1b]0;other\x07",
    ]);
    assert_eq!(
        observe_whole(&bytes),
        vec![title("same"), running(), title("other")]
    );
}

#[test]
fn double_esc_sequences() {
    // ESC ESC ]2;x BEL — the second ESC re-classifies; the OSC still parses.
    assert_eq!(observe_whole(b"\x1b\x1b]2;x\x07"), vec![title("x")]);
    // ESC ]2;x ESC ESC \ — oscEscape sees a second ESC: OSC ends, `\` is a lone final.
    assert_eq!(observe_whole(b"\x1b]2;x\x1b\x1b\\"), vec![title("x")]);
    // Same shape through the 133 path.
    assert_eq!(observe_whole(b"\x1b]133;C\x1b\x1b\\"), vec![running()]);
}

// =====================================================================================
// Cap-boundary characterization (OSC_CAP 4096 / CMD_OSC_CAP 256)
// =====================================================================================

#[test]
fn title_payload_length_boundaries() {
    for length in [255usize, 256, 257, 4095, 4096, 4097] {
        let pad = vec![b'x'; length - 2]; // "0;" + pad == `length` bytes
        for term in [vec![BEL], cat(&[&[ESC], b"\\"])] {
            let bytes = cat(&[b"\x1b]0;", &pad, &term]);
            let expected = if length <= 4096 {
                vec![title(std::str::from_utf8(&pad).unwrap())]
            } else {
                vec![]
            };
            assert_eq!(observe_whole(&bytes), expected, "title L={length}");
        }
    }
}

#[test]
fn command_payload_length_boundaries() {
    let c_prefix = b"\x1b]133;C\x07"; // → running
    for length in [255usize, 256, 257, 4095, 4096, 4097] {
        let pad = vec![b'x'; length - 8]; // "133;D;0;" + pad == `length`
        for term in [vec![BEL], cat(&[&[ESC], b"\\"])] {
            let bytes = cat(&[c_prefix, b"\x1b]133;D;0;", &pad, &term]);
            let mut expected = vec![running()];
            if length <= 256 {
                expected.push(idle(Some(0), 0));
            }
            assert_eq!(observe_whole(&bytes), expected, "cmd L={length}");
        }
    }
}

// =====================================================================================
// Permanent chunking-invariance oracle (whole == byte-at-a-time == every chunk size)
// =====================================================================================

#[test]
fn chunking_invariance_oracle() {
    let esc = "\u{1b}";
    let bel = "\u{07}";
    let st = "\u{1b}\\";
    let streams: Vec<String> = vec![
        "plain text, no sequences at all".to_owned(),
        format!("{bel}a{bel}{bel}b"),
        format!("{esc}]0;one{bel}{esc}]2;one{bel}{esc}]0;two{st}{esc}]2;{bel}{esc}]0;a;b;c{bel}"),
        format!("{esc}]133;D;0{bel}{esc}]133;A{bel}{esc}]133;C{bel}out{esc}]133;D;1{st}"),
        format!(
            "{esc}P{esc}]2;spoof{bel}{esc}X9{bel}{esc}_{esc}]133;C{bel}{esc}]2;real{bel}{esc}]133;C{bel}"
        ),
        format!("{esc}]0;abc{esc}]2;next{bel}{esc}{esc}]0;dbl{bel}"),
        format!("{esc}]2;{}{bel}{bel}{esc}]0;after{bel}", "x".repeat(5000)),
        format!("{esc}]133;{}{st}{esc}]133;C{bel}", "y".repeat(700)),
        format!("tail{esc}]0;par"),
    ];
    for stream in &streams {
        let raw = stream.as_bytes();
        let whole = observe_whole(raw);
        // Byte-at-a-time on a single machine, fixed clock (no advance → 0ms durations).
        let mut per_byte = HostOutputSniffer::new();
        let mut concatenated = Vec::new();
        for &b in raw {
            concatenated.extend(per_byte.observe(&[b], 0));
        }
        assert_eq!(whole, concatenated, "byte-at-a-time diverged on {stream:?}");
        for size in [2usize, 3, 7, 64] {
            assert_eq!(
                observe_chunked(raw, size),
                whole,
                "chunk size {size} on {stream:?}"
            );
        }
    }
}

// =====================================================================================
// Edge cases beyond the Swift shell's test suite.
// =====================================================================================

#[test]
fn duration_saturates_on_non_monotonic_clock() {
    // D's now_ms is BEFORE C's → saturating_sub yields 0 (Swift's `guard ms > 0`).
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 1000);
    assert_eq!(s.observe(&osc133("D;0"), 500), vec![idle(Some(0), 0)]);
}

#[test]
fn duration_clamps_to_u32_max() {
    // A huge gap clamps to u32::MAX; the Swift shell's `ms >= UInt32.max` branch does the same.
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(
        s.observe(&osc133("D;0"), u64::MAX),
        vec![idle(Some(0), u32::MAX)]
    );
}

#[test]
fn duration_just_below_and_at_u32_max_boundary() {
    // Exactly u32::MAX ms → clamped to u32::MAX (Swift's `>=`).
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(
        s.observe(&osc133("D;0"), u64::from(u32::MAX)),
        vec![idle(Some(0), u32::MAX)]
    );
    // One below → passes through unclamped.
    let mut s2 = HostOutputSniffer::new();
    let _ = s2.observe(&osc133("C"), 0);
    assert_eq!(
        s2.observe(&osc133("D;0"), u64::from(u32::MAX) - 1),
        vec![idle(Some(0), u32::MAX - 1)]
    );
}

#[test]
fn negative_exit_code_parsed() {
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(s.observe(&osc133("D;-1"), 0), vec![idle(Some(-1), 0)]);
}

#[test]
fn exit_code_truncated_to_i32() {
    // 2^32 truncates to 0 (Swift Int32(truncatingIfNeeded: 4294967296) == 0).
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(
        s.observe(&osc133("D;4294967296"), 0),
        vec![idle(Some(0), 0)]
    );
}

#[test]
fn exit_code_unparsable_yields_none() {
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(s.observe(&osc133("D;abc"), 0), vec![idle(None, 0)]);
}

#[test]
fn exit_code_equals_prefix_tolerated() {
    // `=5` → first non-empty `=`-segment is "5".
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(s.observe(&osc133("D;=5"), 0), vec![idle(Some(5), 0)]);
}

#[test]
fn exit_code_lone_equals_yields_none() {
    // `=` → no non-empty segment, falls back to "=", which is not an Int → None.
    let mut s = HostOutputSniffer::new();
    let _ = s.observe(&osc133("C"), 0);
    assert_eq!(s.observe(&osc133("D;="), 0), vec![idle(None, 0)]);
}

#[test]
fn invalid_utf8_title_decodes_to_empty_string() {
    // Valid Ps "0", invalid title bytes → String(bytes:encoding:.utf8) ?? "" → "".
    let bytes = cat(&[b"\x1b]0;", &[0xFF, 0xFE], &[BEL]]);
    assert_eq!(observe_whole(&bytes), vec![title("")]);
}

#[test]
fn invalid_utf8_ps_is_ignored() {
    // Invalid Ps bytes → ps decodes to "" → default branch → nothing.
    let bytes = cat(&[b"\x1b]", &[0xFF], b";x", &[BEL]]);
    assert_eq!(observe_whole(&bytes), vec![]);
}

#[test]
fn osc777_notify_title_only_no_body() {
    assert_eq!(
        observe_whole(b"\x1b]777;notify;OnlyTitle\x07"),
        vec![notif("OnlyTitle", "")]
    );
}

#[test]
fn osc777_notify_empty_title_and_body_ignored() {
    assert_eq!(
        notifications_only(&observe_whole(b"\x1b]777;notify;\x07")),
        vec![]
    );
}

#[test]
fn osc777_notify_empty_title_with_body_emits() {
    assert_eq!(
        observe_whole(b"\x1b]777;notify;;body\x07"),
        vec![notif("", "body")]
    );
}

#[test]
fn determinism_two_instances_same_output() {
    let stream = b"\x1b]0;t\x07\x07\x1b]133;C\x07\x1b]9;done\x07";
    assert_eq!(observe_whole(stream), observe_whole(stream));
}

#[test]
fn default_equals_new() {
    let stream = b"\x1b]0;x\x07";
    assert_eq!(
        HostOutputSniffer::default().observe(stream, 0),
        HostOutputSniffer::new().observe(stream, 0)
    );
}

#[test]
fn empty_chunk_emits_nothing_and_preserves_state() {
    let mut s = HostOutputSniffer::new();
    assert_eq!(s.observe(b"\x1b]0;par", 0), vec![]);
    assert_eq!(s.observe(&[], 0), vec![]); // empty chunk is a no-op
    assert_eq!(s.observe(b"t\x07", 0), vec![title("part")]);
}
