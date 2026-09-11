import Foundation

private final class ResultBox<T> {
    var result: Result<T, Error>?
}

/// async 関数を同期的に待つ (CLI の都合上、実行を run() 内でブロックする)
func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    switch box.result! {
    case .success(let v): return v
    case .failure(let e): throw e
    }
}
