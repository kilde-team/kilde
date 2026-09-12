import Foundation
import Darwin

/// 既定の出力名を、別プロセスの録画と衝突しないよう原子的に予約した結果。
/// URL だけでなく作成時のファイル識別子を保持し、別のファイルへすり替わった場合に
/// MovieWriter が誤って削除しないためのトークンとして使う。
public struct OutputFileReservation: Sendable {
    public let url: URL

    private let device: dev_t
    private let inode: ino_t

    private init(url: URL, device: dev_t, inode: ino_t) {
        self.url = url
        self.device = device
        self.inode = inode
    }

    /// preferredURL、続いて拡張子の前へ `-2`, `-3` … を付けた候補を予約する。
    /// `open(O_CREAT | O_EXCL)` を使うため、同時に録画を開始したプロセス同士でも
    /// 同じ名前を取得することはない。
    public static func reserve(preferredURL: URL, maximumCandidateNumber: Int = 999) throws -> Self {
        guard maximumCandidateNumber >= 1 else {
            throw KilError.failed("出力ファイル名の予約候補数が不正です: \(maximumCandidateNumber)")
        }

        for number in 1...maximumCandidateNumber {
            let candidate = candidateURL(for: preferredURL, number: number)
            switch createExclusively(candidate) {
            case .success(let identity):
                return Self(url: candidate, device: identity.device, inode: identity.inode)
            case .alreadyExists:
                continue
            case .failure(let code):
                throw KilError.failed(
                    "出力ファイルを予約できません: \(candidate.path) (errno=\(code): \(String(cString: strerror(code))))"
                )
            }
        }

        throw KilError.failed(
            "出力ファイル名を予約できません: \(preferredURL.path) (-\(maximumCandidateNumber) まで使用済みです)"
        )
    }

    static func candidateURL(for preferredURL: URL, number: Int) -> URL {
        guard number > 1 else { return preferredURL }
        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem)-\(number)" : "\(stem)-\(number).\(ext)"
        return preferredURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// AVAssetWriter が出力先を作り直す直前に、自分が予約した空ファイルだけを削除する。
    /// URL が同じでも inode が変わっていれば他人のファイルなので失敗させる。
    func consume() throws {
        guard matchesReservedEmptyFile() else {
            throw KilError.failed("予約した出力ファイルが変更されています: \(url.path)")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw KilError.failed("予約した出力ファイルを開けません: \(url.path) (\(error))")
        }
    }

    /// writer 構築前の失敗時に予約だけが残らないよう、自分の空ファイルなら片付ける。
    /// 他プロセスが差し替えたファイルはデータ損失を避けるため触らない。
    /// GUI の RecordingController が options を使わずに破棄する経路からも呼ぶため public
    @discardableResult
    public func removeIfStillReserved() -> Bool {
        guard matchesReservedEmptyFile() else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            // 失敗を握りつぶすと 0 バイトの予約が残ったまま気づけない — 呼び出し側が
            // 警告に出せるよう成否を返す (「触らない」は所有物でないため成功扱い)
            return false
        }
    }

    private func matchesReservedEmptyFile() -> Bool {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }) else { return false }
        return info.st_dev == device && info.st_ino == inode && info.st_size == 0
    }

    private struct Identity {
        let device: dev_t
        let inode: ino_t
    }

    private enum CreationResult {
        case success(Identity)
        case alreadyExists
        case failure(Int32)
    }

    private static func createExclusively(_ url: URL) -> CreationResult {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .failure(EINVAL) }
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                let code = errno
                return code == EEXIST ? .alreadyExists : .failure(code)
            }
            defer { close(descriptor) }

            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                let code = errno
                unlink(path)
                return .failure(code)
            }
            return .success(Identity(device: info.st_dev, inode: info.st_ino))
        }
    }
}

extension OutputFileReservation {
    /// 既定名 (非明示) でまだ予約されていない options に予約を確定して反映する。
    /// 開始表示に実際の出力先を出したい呼び出し元 (CLI・ホットキー・GUI) が
    /// Recorder に渡す前に使う共用入口 — ここだけに書くことで「-2 に退避したときの
    /// 表示と実態の不一致」対策の処理が呼び出し先に散らばらないようにする
    public static func resolveDefaultOutput(on options: inout RecordOptions) throws {
        guard options.outputReservation == nil, !options.outputPathIsExplicit,
              let preferred = options.outputURL else { return }
        options.outputReservation = try reserve(preferredURL: preferred)
        options.outputURL = options.outputReservation?.url
    }
}
