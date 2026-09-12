//! Глобальное состояние времени жизни процесса.

pub var started_at: i64 = 0;

/// Единая строка версии релиза — её печатают --version, /status и --help.
/// Выравнивается при релизе: см. docs/CHANGELOG.md и docs/TIMELINE.md.
pub const version = "1.2.2";
