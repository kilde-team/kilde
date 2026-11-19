#!/usr/bin/env python3
"""App Store Connect の計測データを日次で取得して CSV に追記する。

GitHub Actions の metrics workflow (.github/workflows/metrics.yml) から使う。
標準ライブラリ + macOS/Linux 標準搭載の openssl だけで動く (asc-submit リポジトリの
auth.py と同じ方針 — pip install 不要)。

**アプリ固有の値 (ベンダー番号 / App ID / SKU) はここに書かない** — workflow の env
やコマンドライン引数で渡す。eyechecker など同じ ASC API キーで取得できる他アプリへは、
workflow の env 値を変えるだけで流用できる (kilde での設定値は metrics.yml の env を
参照。ベンダー番号は docs/metrics.md «IAP 販売数と DL の月次台帳» の取得方法に記載)。

サブコマンド:

  sales     ASC API の Sales Report (日次 SUMMARY) を取得して対象 SKU の行だけ
            CSV に追記する。Product Type Identifier は F1 (無料アプリの DL
            トランザクション = 初回 DL の代理指標) / F3 (同 再 DL) / F7 (同
            アップデート) / IA1・IA1-M・FI1 (IAP — 接尾辞 M は Mac) を対象にする。
            定義の詳細は docs/metrics.md «IAP 販売数と DL の月次台帳» を参照
  analytics App Analytics API (analyticsReportRequests) の ONGOING リクエストを
            (無ければ) 作成し、指定レポート名の日次インスタンスを CSV に追記する。
            データは `analyticsReportInstances/{id}/segments` のダウンロード URL
            (gzip CSV) から取得する — **これが ASC の実契約** (cubic レビュー指摘
            2026-11-19。instances 直下に data エンドポイントは存在しない)。
            インスタンスは Apple 側が翌日以降に生成するため、**未生成の日は 0 件で
            正常終了する** (ジョブを失敗させない)

重複排除: 両サブコマンドとも、既存 CSV を読み込んで同一キーの行は追記しない。
Sales Report は配信が後になる地域があるため、同じ日付を複数回取得しても安全に
再実行できる (リトライ・バックフィルで二重計上しない設計)。
"""

from __future__ import annotations

import argparse
import base64
import csv
import datetime
import gzip
import io
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

# JWT は発行から 19 分有効 (Apple の上限は 20 分)。サブコマンド 1 回の実行で共有する
_TOKEN: dict[str, str] = {}

SALES_URL = "https://api.appstoreconnect.apple.com/v1/salesReports"
ANALYTICS_URL = "https://api.appstoreconnect.apple.com/v1/analyticsReportRequests"
# instances / segments は analyticsReportRequests ではなくこちらの配下 (実契約)
REPORT_INSTANCES_URL = "https://api.appstoreconnect.apple.com/v1/analyticsReports"
REPORT_INSTANCE_URL = "https://api.appstoreconnect.apple.com/v1/analyticsReportInstances"

# 計測対象の Product Type Identifier (docs/metrics.md の取得方法と同じ集合。
# F1/F3/F7 は無料アプリの DL / 再 DL / アップデート、IA1-M は Mac の IAP、
# FI1 は Mac の IAP 区分のひとつで無料/有料を表さない — 漏れ防止のため含める)
SALES_TYPES = {"F1", "F3", "F7", "IA1", "IA1-M", "FI1", "FI1-M"}

SALES_COLUMNS = ["date", "sku", "product_type", "units", "customer_price",
                 "customer_currency", "country", "proceeds", "proceeds_currency"]
# sales の重複排除キー。CSV 読み込み側と同じ集合を使う (順序は常に sorted で揃える)
SALES_KEY_COLS = ("country", "date", "product_type", "sku")


# ---------- 認証 (asc-submit の auth.py と同じ ES256 JWT) ----------


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _sign(p8_path: str, signing_input: bytes) -> bytes:
    """openssl で ES256 署名し、DER を RFC 7518 の生 R||S (32+32 バイト) に変換する。
    DER の INTEGER は先頭 0x00 パディングや 31 バイトに縮むことがあるため
    右詰めの下 32 バイトを取り、32 バイトに左ゼロパディングして正規化する。"""
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", p8_path],
        input=signing_input, capture_output=True, check=True,
    ).stdout
    assert der[0] == 0x30, "unexpected DER signature layout"

    def read_int(buf: bytes, pos: int) -> tuple[bytes, int]:
        assert buf[pos] == 0x02, hex(buf[pos])
        length = buf[pos + 1]
        val = buf[pos + 2: pos + 2 + length]
        return val.lstrip(b"\x00")[-32:].rjust(32, b"\x00"), pos + 2 + length

    r, pos = read_int(der, 2)
    s, _ = read_int(der, pos)
    return r + s


def make_token(key_id: str, issuer_id: str, p8_path: str) -> str:
    cached = _TOKEN.get(p8_path)
    if cached:
        return cached
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    # aud と typ は必須 (無いと 401 NOT_AUTHORIZED になる — 2026-11-19 実測。
    # asc-submit の auth.py は同じ 2 クレームを付けている)
    payload = {"iss": issuer_id, "iat": now, "exp": now + 19 * 60,
               "aud": "appstoreconnect-v1"}
    signing_input = (
        _b64url(json.dumps(header).encode()).encode()
        + b"." + _b64url(json.dumps(payload).encode()).encode()
    )
    sig = _sign(p8_path, signing_input)
    tok = (signing_input + b"." + _b64url(sig).encode()).decode()
    _TOKEN[p8_path] = tok
    return tok


def _key_file(args: argparse.Namespace) -> str:
    """--key-b64 (CI: secrets から base64 で渡す) を優先し、無ければ --key-file (ローカル)。"""
    if args.key_b64:
        fd, path = tempfile.mkstemp(suffix=".p8")
        with os.fdopen(fd, "wb") as f:
            f.write(base64.b64decode(args.key_b64))
        os.chmod(path, 0o600)
        # ASC 秘密鍵を tmp に残さない — 呼び出し側はこのパスを finally で消す
        return path
    if args.key_file:
        return args.key_file
    raise SystemExit("--key-b64 か --key-file のどちらかは必須です")


def _get(url: str, token: str, gzip_ok: bool = False):
    """GET を実行して (body, next_url) を返す。gzip_ok は Sales Report 用
    (Accept: application/a-gzip 必須 — JSON だと 406 で拒否される)。
    next_url は HTTP の Link ヘッダと JSON 本文の links.next の両方を見る
    (Analytics 系は本文側でページングするため)。"""
    headers = {"Authorization": f"Bearer {token}"}
    if gzip_ok:
        headers["Accept"] = "application/a-gzip"
    rq = urllib.request.Request(url, headers=headers)
    try:
        resp = urllib.request.urlopen(rq)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise SystemExit(f"ASC API error {e.code} for {url}: {body[:300]}")
    raw = resp.read()
    if gzip_ok:
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        return raw.decode(), None
    link = resp.headers.get("Link") or ""
    m = re.search(r'<([^>]+)>; rel="next"', link)
    next_url = m.group(1) if m else None
    data = json.loads(raw)
    if not next_url:
        # 本文側のページング (Analytics の reports / instances / segments はこちら)
        body_next = (data.get("links", {}) or {}).get("next")
        if body_next:
            next_url = body_next
    return data, next_url


# ---------- 共通: CSV の重複排除 ----------


def _read_keys(csv_path: Path, key_cols: tuple[str, ...]) -> set[tuple]:
    seen: set[tuple] = set()
    if not csv_path.exists() or csv_path.stat().st_size == 0:
        return seen
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            if set(key_cols) <= set(row.keys()):
                seen.add(tuple(row[c] for c in key_cols))
    return seen


# ---------- sales ----------


def cmd_sales(args: argparse.Namespace) -> None:
    token = make_token(args.key_id, args.issuer_id, _key_file(args))
    start = datetime.date.fromisoformat(args.from_date)
    end = datetime.date.fromisoformat(args.to_date)
    skus = {s.strip() for s in args.skus.split(",") if s.strip()}
    out_path = Path(args.csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    seen = _read_keys(out_path, SALES_KEY_COLS)
    new_rows: list[list[str]] = []
    d = start
    while d <= end:
        # 日次レポートは地域ごとに配信時刻が違い、未配信日は 404 を返す。
        # バックフィル範囲に未配信日が混ざるのは通常の経路なので 404 は黙ってスキップ
        url = (f"{SALES_URL}?filter[frequency]=DAILY&filter[reportType]=SALES"
               f"&filter[reportSubType]=SUMMARY&filter[vendorNumber]={args.vendor_number}"
               f"&filter[reportDate]={d.isoformat()}")
        try:
            raw, _ = _get(url, token, gzip_ok=True)
        except SystemExit as e:
            if "404" in str(e):
                print(f"sales: {d} レポート未配信 — スキップ")
                d += datetime.timedelta(days=1)
                continue
            raise
        lines = [l for l in raw.strip().split("\n") if l]
        if lines:
            header = lines[0].split("\t")
            for line in lines[1:]:
                row = dict(zip(header, line.split("\t")))
                # SKU で絞る: 同じベンダー番号には別アプリ (kilde では eyechecker)
                # の行が混在するため、Product Type だけでは除外できない。
                # **IAP の SKU (kilde.pro / kilde.tip.*) も workflow の env で
                # 指定する必要がある** — アプリ本体 SKU だけだと IAP 行が落ちる
                if row.get("SKU") not in skus:
                    continue
                pti = row.get("Product Type Identifier", "")
                if pti not in SALES_TYPES:
                    continue
                rec = [
                    d.isoformat(),
                    row.get("SKU", ""),
                    pti,
                    row.get("Units", ""),
                    row.get("Customer Price", ""),
                    row.get("Customer Currency", ""),
                    row.get("Country Code", ""),
                    row.get("Developer Proceeds", ""),
                    row.get("Currency of Proceeds", ""),
                ]
                key = (rec[6], rec[0], rec[2], rec[1])  # SALES_KEY_COLS と同じ順序
                if key in seen:
                    continue
                seen.add(key)
                new_rows.append(rec)
        d += datetime.timedelta(days=1)
    with out_path.open("a", newline="") as f:
        writer = csv.writer(f)
        if not out_path.exists() or out_path.stat().st_size == 0:
            writer.writerow(SALES_COLUMNS)
        writer.writerows(new_rows)
    # IAP の検知は **CSV から行う** (実行中のメモリに依存しない) — コミット後に
    # issue 起票が失敗しても、次回の実行が CSV を再検査して検知を回復できる
    print(f"sales: {len(new_rows)} 行追記 ({args.from_date}〜{args.to_date})")


# ---------- analytics ----------


def _pick_ongoing_request(token: str, app_id: str) -> str | None:
    """ONGOING かつ停止していないリクエストだけを選ぶ。
    ONE_TIME_SNAPSHOT を拾うと一回限りのデータしか取れないため。"""
    url = f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/analyticsReportRequests?limit=50"
    while url:
        data, url = _get(url, token)
        for d in data.get("data", []):
            attrs = d.get("attributes", {})
            if attrs.get("accessType") == "ONGOING" and not attrs.get("stoppedDueToInactivity"):
                return d["id"]
    return None


def cmd_analytics(args: argparse.Namespace) -> None:
    token = make_token(args.key_id, args.issuer_id, _key_file(args))
    # ONGOING のリクエストが無ければ作る。レポート一覧の生成は Apple 側で
    # 翌日以降に行われる (docs/appstore/metadata/metrics.md の既知制約)
    req_id = _pick_ongoing_request(token, args.app_id)
    if not req_id:
        body = json.dumps({"data": {"type": "analyticsReportRequests",
                                    "attributes": {"accessType": "ONGOING"},
                                    "relationships": {"app": {"data": {"type": "apps",
                                                                      "id": args.app_id}}}}}).encode()
        rq = urllib.request.Request(ANALYTICS_URL, data=body, method="POST",
                                    headers={"Authorization": f"Bearer {token}",
                                             "Content-Type": "application/json"})
        with urllib.request.urlopen(rq) as resp:
            req_id = json.load(resp)["data"]["id"]
        print(f"analytics: ONGOING リクエストを作成 ({req_id}) — レポート一覧は翌日以降に生成される")
        return
    reports: dict[str, str] = {}
    url = f"{ANALYTICS_URL}/{req_id}/reports?limit=200"
    while url:
        data, url = _get(url, token)
        for d in data.get("data", []):
            reports[d["attributes"]["name"]] = d["id"]
    wanted = [n.strip() for n in args.reports.split(",") if n.strip()]
    missing = [n for n in wanted if n not in reports]
    if missing:
        # レポート一覧は Apple 側の生成が終わるまで現れない名前がある — 0 件で続行
        print(f"analytics: レポート未生成 (0 件で続行): {', '.join(missing)}")
    for name in wanted:
        rid = reports.get(name)
        if rid:
            _fetch_instances(token, rid, name, args)


def _fetch_instances(token: str, rid: str, name: str, args: argparse.Namespace) -> None:
    """日次インスタンスを列挙し、segments のダウンロード URL (gzip CSV) を
    そのまま CSV に蓄積する。CSV の列は Apple が出した形式をそのまま保持する
    (date 列はインスタンスの processingDate — granularity は «DAILY» という
    粒度の値で日付ではないため、重複排除キーには使えない)。"""
    url = f"{REPORT_INSTANCES_URL}/{rid}/instances?filter[granularity]=DAILY&limit=200"
    instances: list[dict] = []
    while url:
        try:
            data, url = _get(url, token)
        except SystemExit as e:
            # レポートのインスタンスがまだ生えていない日は 404 になる
            # («relationship 'instances' does not exist» など) — 未生成として 0 件で続行
            if "404" in str(e):
                print(f"analytics: {name} — インスタンス未生成 (404, 0 件)")
                return
            raise
        instances += data.get("data", [])
    if not instances:
        print(f"analytics: {name} — インスタンス未生成 (0 件)")
        return
    slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    out_path = Path(args.csv_dir) / f"{slug}.csv"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    seen = _read_keys(out_path, ("date",))
    new_rows = 0
    fetched_days = 0
    for inst in instances:
        date = (inst.get("attributes", {}) or {}).get("processingDate", "")
        iid = inst["id"]
        if not date or date in seen:
            continue
        try:
            rows, columns = _download_segment_rows(token, iid)
        except SystemExit as e:
            print(f"analytics: {name} {iid} データ取得失敗 (スキップ): {e}")
            continue
        if not columns:
            # セグメントに本文が無い日 (集計中) は記録しない — 次回の実行で
            # まだ seen に入っていないので再取得される
            continue
        with out_path.open("a", newline="") as f:
            writer = csv.writer(f)
            if out_path.stat().st_size == 0:
                writer.writerow(["date"] + columns)
            for row in rows:
                writer.writerow([date] + row)
                new_rows += 1
        seen.add(date)
        fetched_days += 1
    print(f"analytics: {name} — {len(instances)} インスタンス中 {fetched_days} 日分・{new_rows} 行追記")


def _download_segment_rows(token: str, instance_id: str) -> tuple[list[list[str]], list[str]]:
    """`analyticsReportInstances/{id}/segments` の各セグメントから gzip CSV を
    ダウンロードして (rows, columns) を返す。"""
    url = f"{REPORT_INSTANCE_URL}/{instance_id}/segments?limit=200"
    rows: list[list[str]] = []
    columns: list[str] = []
    while url:
        data, url = _get(url, token)
        for seg in data.get("data", []):
            dl = (seg.get("attributes", {}) or {}).get("url", "")
            if not dl:
                continue
            rq = urllib.request.Request(dl)
            with urllib.request.urlopen(rq) as resp:
                raw = resp.read()
            if raw[:2] == b"\x1f\x8b":
                raw = gzip.decompress(raw)
            text = raw.decode("utf-8-sig")
            reader = csv.reader(io.StringIO(text))
            seg_rows = [r for r in reader if r]
            if not seg_rows:
                continue
            if not columns:
                columns = seg_rows[0]
            # 列名はセグメント間で同一のはず (列数が違う行は壊れ防止のため読み捨てる)
            for r in seg_rows[1:]:
                if len(r) == len(columns):
                    rows.append(r)
    return rows, columns


def main() -> None:
    ap = argparse.ArgumentParser(description="ASC の計測データを日次 CSV に追記する")
    ap.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID", ""))
    ap.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER", ""))
    ap.add_argument("--key-file", default=os.environ.get("ASC_KEY_FILE", ""))
    ap.add_argument("--key-b64", default=os.environ.get("ASC_KEY_B64", ""))
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sales", help="Sales Report (日次 SUMMARY) を CSV に追記")
    s.add_argument("--vendor-number", required=True)
    s.add_argument("--skus", required=True, help="カンマ区切りの対象 SKU (本体 + IAP)")
    s.add_argument("--from-date", required=True, help="YYYY-MM-DD (含む)")
    s.add_argument("--to-date", required=True, help="YYYY-MM-DD (含む)")
    s.add_argument("--csv", required=True, help="追記先 CSV パス")
    s.set_defaults(func=cmd_sales)

    a = sub.add_parser("analytics", help="App Analytics API の日次インスタンスを CSV に追記")
    a.add_argument("--app-id", required=True)
    a.add_argument("--reports", required=True, help="カンマ区切りのレポート名")
    a.add_argument("--csv-dir", required=True, help="CSV の保存先ディレクトリ")
    a.set_defaults(func=cmd_analytics)

    args = ap.parse_args()
    if not (args.key_id and args.issuer_id):
        raise SystemExit("--key-id / --issuer-id (または ASC_KEY_ID / ASC_ISSUER 環境変数) は必須です")
    tmp_key = None
    try:
        if args.key_b64 and not args.key_file:
            tmp_key = _key_file(args)
            args.key_file = tmp_key  # サブコマンド側は --key-file を見る
        args.func(args)
    finally:
        # --key-b64 で作った一時鍵ファイルを必ず消す (ASC 秘密鍵を tmp に残さない)
        if tmp_key and os.path.exists(tmp_key):
            os.unlink(tmp_key)


if __name__ == "__main__":
    main()
