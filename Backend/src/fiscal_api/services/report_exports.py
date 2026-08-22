from __future__ import annotations

import csv
from collections.abc import Iterable
from io import StringIO

from fiscal_api.api.p34_schemas import PeriodReport
from fiscal_api.services.common import conflict

MAX_REPORT_EXPORT_BYTES = 5 * 1024 * 1024


def report_csv(report: PeriodReport) -> bytes:
    """Render the canonical report snapshot as a reviewable, safe CSV.

    This is intentionally a report document, not the legacy transaction
    ledger export.  It contains only report aggregation rows and stable IDs;
    no account institution/last-four, notes, original bank text, or provider
    material can enter this output.
    """
    buffer = StringIO(newline="")
    writer = csv.writer(buffer, lineterminator="\r\n")
    writer.writerow(["section", "key", "stable_id", "value_minor", "count", "value_text"])
    meta = report.meta
    for key, value in (
        ("period_kind", meta.period_kind.value),
        ("period", meta.period),
        ("date_from", meta.date_from.isoformat()),
        ("date_to", meta.date_to.isoformat()),
        ("timezone", meta.timezone),
        ("currency", meta.currency),
        ("as_of", meta.as_of.isoformat()),
        ("data_revision", str(meta.data_revision)),
        ("report_schema_version", meta.report_schema_version),
        ("generated_at", meta.generated_at.isoformat()),
    ):
        writer.writerow(["meta", key, "", "", "", _safe_csv_text(value)])
    for key, value in report.summary.model_dump().items():
        writer.writerow(["summary", key, "", value, "", ""])
    for account in report.accounts:
        identifier = str(account.account_id)
        for key, value in (
            ("opening_balance_minor", account.opening_balance_minor),
            ("closing_balance_minor", account.closing_balance_minor),
            ("period_inflow_minor", account.period_inflow_minor),
            ("period_outflow_minor", account.period_outflow_minor),
            ("internal_transfer_inflow_minor", account.internal_transfer_inflow_minor),
            ("internal_transfer_outflow_minor", account.internal_transfer_outflow_minor),
        ):
            writer.writerow(
                ["account", key, identifier, value, "", _safe_csv_text(account.account_name)]
            )
    for category in report.categories:
        identifier = str(category.category_id) if category.category_id else ""
        for key, value in (
            ("gross_consumption_minor", category.gross_consumption_minor),
            ("merchant_refund_minor", category.merchant_refund_minor),
            ("net_consumption_minor", category.net_consumption_minor),
        ):
            writer.writerow(
                ["category", key, identifier, value, "", _safe_csv_text(category.category_name)]
            )
        writer.writerow(
            ["category", "transaction_count", identifier, "", category.transaction_count, ""]
        )
    for merchant in report.merchants:
        writer.writerow(
            [
                "merchant",
                "net_consumption_minor",
                str(merchant.merchant_id) if merchant.merchant_id else "",
                merchant.net_consumption_minor,
                merchant.transaction_count,
                _safe_csv_text(merchant.merchant_name),
            ]
        )
    for source in report.sources:
        writer.writerow(["source", source.source.value, "", "", source.transaction_count, ""])
    for key, value in report.completeness.model_dump().items():
        writer.writerow(["completeness", key, "", "", value, ""])
    return _bounded(("\ufeff" + buffer.getvalue()).encode("utf-8"))


def report_pdf(report: PeriodReport) -> bytes:
    """Create a compact Unicode PDF from exactly the same canonical snapshot.

    The built-in Adobe GB CID font avoids system-font variability for Chinese
    labels.  The document deliberately contains summaries and safe aggregate
    labels only; evidence titles, notes and provider/original-statement data
    do not cross the export boundary.
    """
    lines = ["汇总 (分)"]
    lines.extend(f"{key}: {value}" for key, value in report.summary.model_dump().items())
    lines.append("")
    lines.append("分类 (分)")
    lines.extend(
        f"{row.category_name}: {row.net_consumption_minor} ({row.transaction_count} 笔)"
        for row in report.categories
    )
    lines.append("")
    lines.append("账户 (分)")
    lines.extend(
        (
            f"{row.account_name}: opening={row.opening_balance_minor}, "
            f"closing={row.closing_balance_minor}, in={row.period_inflow_minor}, "
            f"out={row.period_outflow_minor}"
        )
        for row in report.accounts
    )
    lines.append("")
    lines.append("商户 (分)")
    lines.extend(
        f"{row.merchant_name}: {row.net_consumption_minor} ({row.transaction_count} 笔)"
        for row in report.merchants
    )
    lines.append("")
    lines.append("来源")
    lines.extend(f"{row.source.value}: {row.transaction_count}" for row in report.sources)
    lines.append("")
    lines.append("完整性")
    lines.extend(f"{key}: {value}" for key, value in report.completeness.model_dump().items())
    return _bounded(
        _unicode_pdf(
            lines,
            title=f"Fiscal report {report.meta.period}",
            header=(
                "Fiscal 报告",
                f"期间: {report.meta.period} ({report.meta.date_from} 至 {report.meta.date_to})",
                (
                    f"口径: {report.meta.timezone} · {report.meta.currency}"
                    f" · revision {report.meta.data_revision}"
                ),
                f"生成: {report.meta.generated_at.isoformat()}",
            ),
        )
    )


def report_export_filename(report: PeriodReport, extension: str) -> str:
    return (
        f"fiscal-report-{report.meta.period_kind.value}-{report.meta.period}"
        f"-r{report.meta.data_revision}.{extension}"
    )


def _safe_csv_text(value: str) -> str:
    # Spreadsheet formula injection applies to names too, even though this
    # report intentionally excludes memo/title/provider evidence.
    return f"\t{value}" if value[:1] in {"=", "+", "-", "@"} else value


def _bounded(value: bytes) -> bytes:
    if len(value) > MAX_REPORT_EXPORT_BYTES:
        conflict("report_export_too_large", "The report export exceeds the 5 MiB safety limit")
    return value


def _unicode_pdf(lines: Iterable[str], *, title: str, header: tuple[str, str, str, str]) -> bytes:
    # PDF Type0 text in UTF-16BE is deterministic and does not need a local
    # font file.  Every canonical line is paginated; no ranking cap may make
    # the PDF disagree with JSON/CSV.
    body = [_pdf_line(line) for line in lines]
    page_size = 40
    pages = [body[index : index + page_size] for index in range(0, len(body), page_size)] or [[]]
    font_id = 3 + len(pages) * 2
    cid_font_id = font_id + 1
    info_id = cid_font_id + 1
    page_ids = [3 + index * 2 for index in range(len(pages))]
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        (
            b"<< /Type /Pages /Kids ["
            + b" ".join(f"{page_id} 0 R".encode() for page_id in page_ids)
            + b"] /Count "
            + str(len(pages)).encode()
            + b" >>"
        ),
    ]
    for index, page in enumerate(pages):
        page_id = page_ids[index]
        content_id = page_id + 1
        page_lines = [*header, f"页码: {index + 1}/{len(pages)}", "", *page]
        content = _pdf_page_content(page_lines)
        objects.extend(
            [
                (
                    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
                    + f"/Resources << /Font << /F1 {font_id} 0 R >> >> ".encode()
                    + f"/Contents {content_id} 0 R >>".encode()
                ),
                (
                    b"<< /Length "
                    + str(len(content)).encode()
                    + b" >>\nstream\n"
                    + content
                    + b"\nendstream"
                ),
            ]
        )
    objects.extend(
        [
            (
                b"<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light "
                b"/Encoding /UniGB-UCS2-H /DescendantFonts ["
                + f"{cid_font_id} 0 R".encode()
                + b"] >>"
            ),
            (
                b"<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light "
                b"/CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 5 >> /DW 1000 >>"
            ),
            b"<< /Title (" + _pdf_literal(title) + b") /Producer (Fiscal) >>",
        ]
    )
    result = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, value in enumerate(objects, start=1):
        offsets.append(len(result))
        result.extend(f"{number} 0 obj\n".encode())
        result.extend(value)
        result.extend(b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(objects) + 1}\n".encode())
    result.extend(b"0000000000 65535 f \n")
    result.extend(b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:]))
    result.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R /Info {info_id} 0 R >>"
            f"\nstartxref\n{xref}\n%%EOF\n"
        ).encode()
    )
    return bytes(result)


def _pdf_page_content(lines: list[str]) -> bytes:
    content_lines = ["BT", "/F1 10 Tf", "48 790 Td", "14 TL"]
    for index, line in enumerate(lines):
        if index:
            content_lines.append("T*")
        content_lines.append(f"<{line.encode('utf-16-be').hex().upper()}> Tj")
    content_lines.append("ET")
    return "\n".join(content_lines).encode("ascii")


def _pdf_line(value: str) -> str:
    return value.replace("\r", " ").replace("\n", " ")


def _pdf_literal(value: str) -> bytes:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)").encode("ascii")
