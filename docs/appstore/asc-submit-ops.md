# asc-submit の本番運用 (m1 ランナー)

mas.yml / mas-watch.yml が使う [asc-submit](https://github.com/takezou621/asc-submit)
のバージョン管理と、実行ジャーナル・ライブ視聴 (v0.3.0 の機能) の運用手順。
**asc-submit のピンを更新するときは §3 の手順全体を実行すること** —
ワークフロー用のピンだけ上げて serve 用コードを再配置し忘れると、
ワークフローとダッシュボードでバージョンがずれる。

## 1. 構成 (どこに何があるか)

| 要素 | 場所 | 役割 |
|---|---|---|
| asc-submit 本体 (ワークフロー用) | ジョブごとに checkout。`mas.yml` / `mas-watch.yml` が**コミット SHA ピン**で取得 | `run` の実行 (apply / submit) |
| 実行ジャーナル | ランナー `~/asc-submit-runs/` (`ASC_SUBMIT_RUNS_DIR` で指定) | run のステップ状況・タイミング・ログの永続化。ワークスペース内だと次ジョブの checkout クリーンで消えるため外に出している |
| serve (読み取り専用ダッシュボード) | ランナー `~/asc-submit-serve/asc-submit` + LaunchAgent `dev.takezou621.asc-submit-serve` | `127.0.0.1:8756` で JSON API とダッシュボードを提供 (KeepAlive 常駐) |
| serve のログ | `~/asc-submit-runs/serve.log` | 起動メッセージとエラー |

SSH は `kawai@192.168.2.243` (鍵認証。root には鍵を置いていない)。

## 2. 日々の動作と見方

- `apply` / `submit` モードの `asc-submit run` がステップ単位でジャーナルを記録する
  (`plan` / `status` / `doctor` は読み取りのみで記録なし。upload モードは独自スクリプト経由のため対象外)
- ターミナルから:

  ```sh
  ssh kawai@192.168.2.243
  PYTHONPATH=~/asc-submit-serve/asc-submit python3 -m asc_submit runs       # 一覧
  PYTHONPATH=~/asc-submit-serve/asc-submit python3 -m asc_submit logs <id>  # 個別ログ
  ```

- ブラウザから (ライブ視聴): 手元でトンネルを張って http://127.0.0.1:8756/ を開く

  ```sh
  ssh -f -N -L 8756:127.0.0.1:8756 kawai@192.168.2.243
  ```

  serve は loopback 専用。**`--host` を広げないこと** (認証なしで誰でも読める)

## 3. asc-submit をバージョンアップする手順

1. asc-submit リポジトリで変更し、テストを通す。**本番ランタイムは Python 3.9.6**
   (`/usr/bin/python3`) なので、バージョンアップ前に 3.9 で全テストを実行して確認する
2. kilde の `mas.yml` / `mas-watch.yml` のピン SHA を更新する PR を出してマージ
   (merge commit。cubic / CodeRabbit のチェックが終わるのを待つ)
3. **ランナーの serve 用コードを同じ SHA で再配置**:

   ```sh
   git -C <asc-submit のチェックアウト> archive <sha> \
     | ssh kawai@192.168.2.243 \
       'rm -rf ~/asc-submit-serve/asc-submit && mkdir -p ~/asc-submit-serve/asc-submit && tar xf - -C ~/asc-submit-serve/asc-submit'
   ```

4. serve を再起動:

   ```sh
   ssh kawai@192.168.2.243 \
     'launchctl kickstart -k gui/$(id -u)/dev.takezou621.asc-submit-serve'
   ```

5. 検証: ランナー上で `curl -s http://127.0.0.1:8756/api/runs`、ワークフローは
   `mode=plan` (API キー不要・副作用なし) を dispatch して通し確認

手順 2 と 3 は必ずセット。ジャーナル形式は前方互換なのでずれても直ちには壊れないが、
放置するとダッシュボードの挙動とワークフローの実コードが離れていく。

## 4. トラブルシュート

- serve が応答しない → `launchctl print gui/$(id -u)/dev.takezou621.asc-submit-serve`
  で状態を確認、ログは `~/asc-submit-runs/serve.log`。KeepAlive なので落としても自動復帰する
- LaunchAgent の定義 → `~/Library/LaunchAgents/dev.takezou621.asc-submit-serve.plist`
  (ポート 8756 / `--runs-dir` / PYTHONPATH はここで管理)
- ジャーナルを掃除したい → `~/asc-submit-runs/` 内の run ディレクトリ
  (`YYYYMMDD-HHMMSS-xxxx`) は削除してよい (asc-submit が再生成する。`serve.log` は残す)
