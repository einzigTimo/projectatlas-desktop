//! Purpose: Typed error surface for Tauri commands, serialized as a plain message for the frontend.

/// Error returned to the frontend from a Tauri command.
#[derive(Debug, thiserror::Error)]
pub(crate) enum AppError {
    /// A registry read, write, or scan operation failed.
    #[error("Projekt-Registrierung fehlgeschlagen: {0}")]
    Registry(String),
    /// Opening or querying a project's `ProjectAtlas` database failed.
    #[error("Zugriff auf ProjectAtlas-Datenbank fehlgeschlagen: {0}")]
    Database(projectatlas_db::DbError),
    /// The project database was written by an older `ProjectAtlas` version.
    #[error(
        "Die Datenbank dieses Projekts stammt aus einer aelteren ProjectAtlas-Version          (Stand {found}, erwartet {expected}). Im Projektordner einmal `projectatlas init`          ausfuehren, damit sie neu aufgebaut wird."
    )]
    OutdatedDatabase {
        /// Schema version found in the project database.
        found: i64,
        /// Schema version this build expects.
        expected: i64,
    },
    /// A higher-level service query failed.
    #[error("Abfrage fehlgeschlagen: {0}")]
    Service(#[from] projectatlas_service::ServiceError),
    /// A filesystem operation failed.
    #[error("Dateizugriff fehlgeschlagen: {0}")]
    Io(#[from] std::io::Error),
    /// Serializing or deserializing the on-disk registry failed.
    #[error("Registrierungsdatei ungueltig: {0}")]
    Serde(#[from] serde_json::Error),
    /// The requested project id is not registered.
    #[error("Unbekanntes Projekt: {0}")]
    UnknownProject(String),
    /// `%LOCALAPPDATA%` or `%USERPROFILE%` was not set in the environment.
    #[error("Umgebungsvariable fehlt: {0}")]
    MissingEnvVar(&'static str),
    /// The service returned a different report kind than the one requested.
    #[error("Unerwartete Berichtsart, erwartet wurde: {0}")]
    UnexpectedReport(&'static str),
    /// A blocking database read did not finish, e.g. because its worker thread died.
    #[error("Hintergrundabfrage abgebrochen: {0}")]
    Background(String),
    /// Checking for, downloading, or installing an update failed.
    #[error("Aktualisierung fehlgeschlagen: {0}")]
    Updater(#[from] tauri_plugin_updater::Error),
    /// Running the bundled `projectatlas` command-line binary failed.
    #[error("Aufruf des ProjectAtlas-Programms fehlgeschlagen: {0}")]
    Shell(#[from] tauri_plugin_shell::Error),
}

/// Translate database failures, naming the outdated-schema case explicitly.
///
/// Without this, a project last indexed by an older `ProjectAtlas` shows the raw
/// `unsupported schema version 16, expected 19` and gives the user nothing to act on.
impl From<projectatlas_db::DbError> for AppError {
    fn from(error: projectatlas_db::DbError) -> Self {
        error
            .unsupported_schema_version()
            .map_or(Self::Database(error), |(found, expected)| {
                Self::OutdatedDatabase { found, expected }
            })
    }
}

/// Serialize an [`AppError`] as its plain display message for the Tauri IPC bridge.
impl serde::Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

/// Convenient result alias for app-level operations.
pub(crate) type AppResult<T> = Result<T, AppError>;
