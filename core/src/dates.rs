//! Calendar dates in the device's own time zone, for `date:` searches and the
//! usage timeline. The C library does the zone arithmetic (it knows the
//! zone's daylight-saving rules); everything else here is day counting.

use std::sync::Once;

/// A calendar day, counted from 1970-01-01.
pub type Day = i32;

static TZ: Once = Once::new();

#[cfg(unix)]
extern "C" {
    // In every POSIX C library we build against, but not in the `libc`
    // crate's bindings for all of them.
    fn tzset();
}

#[cfg(windows)]
extern "C" {
    // Windows Universal CRT (ucrtbase) exposes `_tzset`, `localtime_s`
    // (with `(tm*, time_t*)` parameter order), and `_mktime64` instead of
    // POSIX `tzset`, `localtime_r`, and `mktime`.
    fn _tzset();
    fn localtime_s(tm: *mut libc::tm, time: *const libc::time_t) -> libc::c_int;
    fn _mktime64(tm: *mut libc::tm) -> libc::time_t;
}

#[cfg(unix)]
unsafe fn sys_mktime(tm: *mut libc::tm) -> libc::time_t {
    libc::mktime(tm)
}

#[cfg(windows)]
unsafe fn sys_mktime(tm: *mut libc::tm) -> libc::time_t {
    _mktime64(tm)
}

fn init_zone() {
    // SAFETY: `tzset` / `_tzset` only reads the environment and zone database.
    #[cfg(unix)]
    TZ.call_once(|| unsafe { tzset() });
    #[cfg(windows)]
    TZ.call_once(|| unsafe { _tzset() });
}

#[cfg(unix)]
fn local_tm(secs: libc::time_t) -> Option<libc::tm> {
    // SAFETY: `tm` is plain data, and `localtime_r` writes only to it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let ok = unsafe { !libc::localtime_r(&secs, &mut tm).is_null() };
    ok.then_some(tm)
}

#[cfg(windows)]
fn local_tm(secs: libc::time_t) -> Option<libc::tm> {
    // MSVC `localtime_s` rejects negative `time_t` values (pre-1970);
    // returning `None` lets callers fall back to civil day math.
    if secs < 0 {
        return None;
    }
    // SAFETY: `tm` is plain data, and `localtime_s` writes only to it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let ok = unsafe { localtime_s(&mut tm, &secs) == 0 };
    ok.then_some(tm)
}

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
pub fn days_from_civil(year: i32, month: u32, day: u32) -> Day {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (month as i32 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day as i32 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date of a day number: (year, month 1-12, day 1-31).
pub fn civil_from_days(day: Day) -> (i32, u32, u32) {
    let z = day + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    (y, m, d)
}

/// Monday = 0 ... Sunday = 6.
pub fn weekday(day: Day) -> u32 {
    // 1970-01-01 was a Thursday.
    (day + 3).rem_euclid(7) as u32
}

pub fn days_in_month(year: i32, month: u32) -> u32 {
    let (ny, nm) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
    (days_from_civil(ny, nm, 1) - days_from_civil(year, month, 1)) as u32
}

pub fn format_day(day: Day) -> String {
    let (y, m, d) = civil_from_days(day);
    format!("{y:04}-{m:02}-{d:02}")
}

/// The local calendar day an instant (milliseconds since the epoch) falls on.
pub fn local_day(ms: i64) -> Day {
    init_zone();
    let secs = ms.div_euclid(1000) as libc::time_t;
    let Some(tm) = local_tm(secs) else {
        return ms.div_euclid(86_400_000) as Day;
    };
    days_from_civil(tm.tm_year + 1900, (tm.tm_mon + 1) as u32, tm.tm_mday as u32)
}

/// The instant a local calendar day starts, in milliseconds since the epoch.
pub fn local_midnight_ms(day: Day) -> i64 {
    init_zone();
    let (y, m, d) = civil_from_days(day);
    #[cfg(windows)]
    if day < 0 || y < 1970 {
        return day as i64 * 86_400_000;
    }
    // SAFETY: as above; `mktime` / `_mktime64` normalises the fields it is given.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = y - 1900;
    tm.tm_mon = m as i32 - 1;
    tm.tm_mday = d as i32;
    tm.tm_isdst = -1;
    let secs = unsafe { sys_mktime(&mut tm) };
    if secs == -1 {
        return day as i64 * 86_400_000;
    }
    secs as i64 * 1000
}

/// `2026`, `2026-10` or `2026-10-09` as the days it covers: (first, one past
/// the last).
fn parse_span(text: &str) -> Option<(Day, Day)> {
    let mut parts = text.split('-');
    let year: i32 = parts.next()?.parse().ok()?;
    let month = parts.next().map(str::parse::<u32>);
    let day = parts.next().map(str::parse::<u32>);
    if parts.next().is_some() || !(1..=9999).contains(&year) {
        return None;
    }
    match (month, day) {
        (None, _) => Some((days_from_civil(year, 1, 1), days_from_civil(year + 1, 1, 1))),
        (Some(Ok(m)), None) if (1..=12).contains(&m) => {
            let first = days_from_civil(year, m, 1);
            Some((first, first + days_in_month(year, m) as Day))
        }
        (Some(Ok(m)), Some(Ok(d))) if (1..=12).contains(&m) && d >= 1 && d <= days_in_month(year, m) => {
            let first = days_from_civil(year, m, d);
            Some((first, first + 1))
        }
        _ => None,
    }
}

/// The instants a `date:` search covers, as [from, to) in milliseconds:
/// `2026`, `2026-10`, `2026-10-09`, or two of those joined by `..` for
/// everything from the start of the first to the end of the second.
pub fn parse_range(text: &str) -> Option<(i64, i64)> {
    let (first, last) = match text.split_once("..") {
        Some((a, b)) => (parse_span(a.trim())?.0, parse_span(b.trim())?.1),
        None => parse_span(text.trim())?,
    };
    if last <= first {
        return None;
    }
    Some((local_midnight_ms(first), local_midnight_ms(last)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn day_counting() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2000, 3, 1), 11_017);
        assert_eq!(civil_from_days(11_017), (2000, 3, 1));
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
        for day in [-800_000, -1, 0, 59, 60, 19_000, 20_737, 2_900_000] {
            let (y, m, d) = civil_from_days(day);
            assert_eq!(days_from_civil(y, m, d), day);
        }
        // 2026-10-11 was a Sunday, 2024-02 had 29 days.
        assert_eq!(weekday(days_from_civil(2026, 10, 11)), 6);
        assert_eq!(weekday(days_from_civil(1970, 1, 1)), 3);
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(days_in_month(2026, 2), 28);
        assert_eq!(days_in_month(2026, 12), 31);
        assert_eq!(format_day(days_from_civil(2026, 3, 7)), "2026-03-07");
    }

    #[test]
    fn local_days_and_ranges() {
        // Whatever the zone, midnight of a day is on that day, and so is the
        // last millisecond before the next midnight.
        for day in [days_from_civil(2026, 3, 8), days_from_civil(2026, 10, 11), days_from_civil(2026, 11, 1)] {
            let start = local_midnight_ms(day);
            let end = local_midnight_ms(day + 1);
            assert_eq!(local_day(start), day);
            assert_eq!(local_day(end - 1), day);
            // A day is 24 hours give or take a daylight-saving shift.
            assert!((23 * 3_600_000..=25 * 3_600_000).contains(&(end - start)), "{}", end - start);
        }

        let day = |text: &str| parse_range(text).map(|(a, b)| (local_day(a), local_day(b)));
        let d = days_from_civil;
        assert_eq!(day("2026-10-09"), Some((d(2026, 10, 9), d(2026, 10, 10))));
        assert_eq!(day("2026-10"), Some((d(2026, 10, 1), d(2026, 11, 1))));
        assert_eq!(day("2026"), Some((d(2026, 1, 1), d(2027, 1, 1))));
        assert_eq!(day("2026-10-05..2026-10-11"), Some((d(2026, 10, 5), d(2026, 10, 12))));
        assert_eq!(day("2025-12..2026-01"), Some((d(2025, 12, 1), d(2026, 2, 1))));
        for bad in ["", "soon", "2026-13", "2026-02-30", "2026-10-09-01", "2026-10-11..2026-10-05", "0"] {
            assert_eq!(parse_range(bad), None, "{bad}");
        }
    }

    #[test]
    fn pre_epoch_and_trimmed_ranges() {
        // Pre-1970 timestamps must not panic or fail under either POSIX `localtime_r`
        // or Windows `localtime_s` fallback logic.
        let pre_epoch_ms = -3 * 86_400_000;
        let d = local_day(pre_epoch_ms);
        assert!((-4..=-2).contains(&d), "unexpected pre-epoch day: {d}");

        // Ranges with surrounding whitespace parse identically.
        assert_eq!(
            parse_range("  2026-10-01 .. 2026-10-05  "),
            parse_range("2026-10-01..2026-10-05")
        );
    }
}
