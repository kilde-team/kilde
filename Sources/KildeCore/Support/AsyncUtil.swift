import Foundation

private final class ResultBox<T> {
    var result: Result<T, Error>?
}

/// async 関数を同期的に待つ。**同期コンテキスト専用** (CLI のサブコマンド、GUI の onAppear 等)。
/// 呼び出したスレッドを DispatchSemaphore で塞ぐため、async コンテキスト (協調プールのスレッド) から
/// 呼ぶとプールを枯渇させうる (issue #35)。noasync にして、async コンテキストからの呼び出しを
/// コンパイル時に警告させる — 同期 API を包む側 (DisplayCatalog 等) も同じく noasync にしている
@available(*, noasync, message: "async コンテキストでは直接 await してください (issue #35)")
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
