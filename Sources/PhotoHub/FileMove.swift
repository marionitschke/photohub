import Foundation

/// Verschieben für „Apple Fotos Export“ (Option) und „Bilder-Ordner abgleichen“.
enum FileMove {
    /// Verschiebt, ohne zu überschreiben: auf demselben Laufwerk durch Umbenennen (sofort), sonst als Kopie samt
    /// Metadaten, nach der das Original gelöscht wird. Pfade als Text, damit Namen Byte für Byte bleiben.
    static func move(atPath source: String, toPath target: String) throws {
        func failure(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        if renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == EXDEV else { throw failure(code) }
        guard copyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL)) == 0 else {
            let code = errno
            // Halb geschriebene Kopie wieder weg – sie stammt sicher von uns (COPYFILE_EXCL).
            if code != EEXIST { unlink(target) }
            throw failure(code)
        }
        // Erst löschen, wenn die Kopie vollständig ist.
        var sourceInfo = stat()
        var targetInfo = stat()
        guard stat(source, &sourceInfo) == 0, stat(target, &targetInfo) == 0, sourceInfo.st_size == targetInfo.st_size else {
            unlink(target)
            throw failure(EIO)
        }
        guard unlink(source) == 0 else {
            let code = errno
            unlink(target)
            throw failure(code)
        }
    }
}
