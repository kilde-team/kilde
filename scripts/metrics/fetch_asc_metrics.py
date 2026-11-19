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
    # aud は必須 (無いと 401 NOT_AUTHORIZED になる — asc-submit の auth.py と同じ)
    payload = {"iss": issuer_id, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
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
        return path
    if args.key_file:
        return args.key_file
    raise SystemExit("--key-b64 か --key-file のどちらかは必須です")


def _get(url: str, token: str, gzip_ok: bool = False):
    """GET を実行して (body, next_url) を返す。gzip_ok は Sales Report 用
    (Accept: application/a-gzip 必須 — JSON だと 406 で拒否される)。"""
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
            import gzip
            raw = gzip.decompress(raw)
        return raw.decode(), None
    link = resp.headers.get("Link") or ""
    m = re.search(r'<([^>]+)>; rel="next"', link)
    return json.loads(raw), (m.group(1) if m else None)


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
    iap_rows: list[list[str]] = []
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
                # の行が混在するため、Product Type だけでは除外できない
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
                if pti.startswith(("IA1", "FI1")):
                    iap_rows.append(rec)
        d += datetime.timedelta(days=1)
    with out_path.open("a", newline="") as f:
        writer = csv.writer(f)
        if not out_path.exists() or out_path.stat().st_size == 0:
            writer.writerow(SALES_COLUMNS)
        writer.writerows(new_rows)
    if iap_rows:
        # workflow 側がこの印を見て issue を起票する (売上の気づきは即時にしたい)
        print("IAP_SALES_DETECTED")
        for r in iap_rows:
            print("IAP_ROW\t" + "\t".join(r))
    print(f"sales: {len(new_rows)} 行追記 ({args.from_date}〜{args.to_date})")


# ---------- analytics ----------


def cmd_analytics(args: argparse.Namespace) -> None:
    token = make_token(args.key_id, args.issuer_id, _key_file(args))
    # ONGOING のリクエストが無ければ作る。レポート一覧の生成は Apple 側で
    # 翌日以降に行われる (docs/appstore/metadata/metrics.md の既知制約)
    data, _ = _get(f"https://api.appstoreconnect.apple.com/v1/apps/{args.app_id}"
                   f"/analyticsReportRequests?limit=50", token)
    req_ids = [d["id"] for d in data.get("data", [])]
    if not req_ids:
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
    req_id = req_ids[0]
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
    url = f"{ANALYTICS_URL}/{rid}/instances?limit=200"
    instances: list[dict] = []
    while url:
        try:
            data, url = _get(url, token)
        except SystemExit as e:
            # レポートのインスタンス関係がまだ生えていない日は 404 PATH_ERROR になる
            # («relationship 'instances' does not exist») — 未生成として 0 件で続行
            if "404" in str(e):
                print(f"analytics: {name} — インスタンス未生成 (404, 0 件)")
                return
            raise
        instances += data.get("data", [])
    if not instances:
        print(f"analytics: {name} — インスタンス未生成 (0 件)")
        return
    slug = name.lower().replace(" ", "_")
    out_path = Path(args.csv_dir) / f"{slug}.csv"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    seen = _read_keys(out_path, ("date",))
    new_rows = 0
    with out_path.open("a", newline="") as f:
        writer = csv.writer(f)
        if out_path.stat().st_size == 0:
            writer.writerow(["date", "dimension", "dimension_value", "measure", "value"])
        for inst in instances:
            date = inst["attributes"].get("granularity", "")
            iid = inst["id"]
            if date in seen:
                continue
            try:
                data, _ = _get(f"{ANALYTICS_URL}/{rid}/instances/{iid}/data", token)
            except SystemExit as e:
                print(f"analytics: {name} {iid} データ取得失敗 (スキップ): {e}")
                continue
            # data エンドポイントの応答形式は Apple の改変がありうるため、既知の
            # 2 形式 (list / dict-with-data) を両方受け入れる。未知の形式はログして継続
            rows = data if isinstance(data, list) else data.get("data", [])
            for row in rows:
                if not isinstance(row, dict):
                    continue
                keys = row.get("dimensionKeys", row.get("dimension_keys", {}))
                val = row.get("values", row.get("value", ""))
                n = _write_dims(writer, date, keys, val)
                new_rows += n
            seen.add(date)
    print(f"analytics: {name} — {len(instances)} インスタンス、{new_rows} 行追記")


def _write_dims(writer, date: str, keys: dict, val) -> int:
    """dimensionKeys は {'total':..., 'source':..., 'country':...} の辞書 (想定)。
    値ごとに行を分けて記録する (CSV に固定列を持たせない — Apple が次元を追加しても
    旧データを壊さない)。応答形式が想定外のときは 0 行で返る (ログは呼び出し側)。"""
    n = 0
    if isinstance(val, dict):
        for measure, v in val.items():
            n += _write_dims(writer, date, keys, {measure: v} if not isinstance(v, dict) else v)
        return n
    if not isinstance(keys, dict) or not keys:
        writer.writerow([date, "all", "", "value", val])
        return 1
    for k, v in keys.items():
        writer.writerow([date, k, v, "value", val])
        n += 1
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description="ASC の計測データを日次 CSV に追記する")
    ap.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID", ""))
    ap.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER", ""))
    ap.add_argument("--key-file", default=os.environ.get("ASC_KEY_FILE", ""))
    ap.add_argument("--key-b64", default=os.environ.get("ASC_KEY_B64", ""))
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sales", help="Sales Report (日次 SUMMARY) を CSV に追記")
    s.add_argument("--vendor-number", required=True)
    s.add_argument("--skus", required=True, help="カンマ区切りの対象 SKU (例: kilde-mas)")
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
    args.func(args)


if __name__ == "__main__":
    main()
