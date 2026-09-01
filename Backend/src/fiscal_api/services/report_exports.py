from __future__ import annotations

import csv
from collections.abc import Iterable
from datetime import datetime
from io import StringIO
from zoneinfo import ZoneInfo

from fiscal_api.api.p34_schemas import PeriodReport, PeriodReportV2
from fiscal_api.services.common import conflict

MAX_REPORT_EXPORT_BYTES = 5 * 1024 * 1024
SHANGHAI = ZoneInfo("Asia/Shanghai")

SUMMARY_LABELS = {
    "income_minor": "收入",
    "gross_consumption_minor": "消费总额",
    "merchant_refund_minor": "商户退款",
    "net_consumption_minor": "净消费",
    "expected_reimbursement_minor": "预计报销",
    "received_reimbursement_minor": "已收报销",
    "personal_expected_minor": "个人预计承担",
    "personal_realized_minor": "个人实际承担",
    "net_income_expense_minor": "收支净额",
    "cash_inflow_minor": "现金流入",
    "cash_outflow_minor": "现金流出",
    "cash_net_minor": "现金净流入",
    "internal_transfer_inflow_minor": "内部转入",
    "internal_transfer_outflow_minor": "内部转出",
    "credit_debt_at_period_end_minor": "期末信用欠款",
    "reimbursement_outstanding_at_period_end_minor": "期末待收报销",
}

CATEGORY_LABELS = {
    "gross_consumption_minor": "消费总额",
    "merchant_refund_minor": "商户退款",
    "net_consumption_minor": "净消费",
    "expected_reimbursement_minor": "预计报销",
    "received_reimbursement_minor": "已收报销",
    "personal_expected_minor": "个人预计承担",
    "personal_realized_minor": "个人实际承担",
}

ACCOUNT_LABELS = {
    "opening_balance_minor": "期初余额",
    "closing_balance_minor": "期末余额",
    "period_inflow_minor": "本期流入",
    "period_outflow_minor": "本期流出",
    "internal_transfer_inflow_minor": "内部转入",
    "internal_transfer_outflow_minor": "内部转出",
}

COMPLETENESS_LABELS = {
    "unresolved_import_count": "待核对导入",
    "failed_import_count": "导入失败",
    "uncategorized_transaction_count": "未分类账目",
}

SOURCE_LABELS = {
    "manual": "手动记账",
    "system": "系统生成",
    "ai_text": "文字记账",
    "ocr": "截图识别",
    "legacy_import": "历史导入",
    "cash_flow": "现金流计划",
    "statement_import": "账单导入",
}


def report_csv(report: PeriodReport | PeriodReportV2) -> bytes:
    """Render a user-facing report without exposing internal contract fields."""
    buffer = StringIO(newline="")
    writer = csv.writer(buffer, lineterminator="\r\n")
    writer.writerow(["分类", "项目", "对象", "金额（元）", "数量", "说明"])
    meta = report.meta
    for label, value in (
        ("报表类型", "月度报表" if meta.period_kind.value == "month" else "年度报表"),
        ("报表期间", meta.period),
        ("开始日期", meta.date_from.isoformat()),
        ("结束日期", meta.date_to.isoformat()),
        ("时间口径", "上海时间"),
        ("币种", "人民币"),
        ("数据截至", _visible_datetime(meta.as_of)),
        ("生成时间", _visible_datetime(meta.generated_at)),
    ):
        writer.writerow(["报表信息", label, "", "", "", _safe_csv_text(value)])
    for key, value in report.summary.model_dump().items():
        writer.writerow(["汇总", SUMMARY_LABELS[key], "", _yuan_number(value), "", ""])
    for account in report.accounts:
        for key, value in (
            ("opening_balance_minor", account.opening_balance_minor),
            ("closing_balance_minor", account.closing_balance_minor),
            ("period_inflow_minor", account.period_inflow_minor),
            ("period_outflow_minor", account.period_outflow_minor),
            ("internal_transfer_inflow_minor", account.internal_transfer_inflow_minor),
            ("internal_transfer_outflow_minor", account.internal_transfer_outflow_minor),
        ):
            writer.writerow(
                [
                    "账户",
                    ACCOUNT_LABELS[key],
                    _safe_csv_text(account.account_name),
                    _yuan_number(value),
                    "",
                    "",
                ]
            )
    for category in report.categories:
        category_values = [
            ("gross_consumption_minor", category.gross_consumption_minor),
            ("merchant_refund_minor", category.merchant_refund_minor),
            ("net_consumption_minor", category.net_consumption_minor),
        ]
        for key in (
            "expected_reimbursement_minor",
            "received_reimbursement_minor",
            "personal_expected_minor",
            "personal_realized_minor",
        ):
            if hasattr(category, key):
                category_values.append((key, getattr(category, key)))
        for key, value in category_values:
            writer.writerow(
                [
                    "分类",
                    CATEGORY_LABELS[key],
                    _safe_csv_text(category.category_name),
                    _yuan_number(value),
                    "",
                    "",
                ]
            )
        writer.writerow(
            [
                "分类",
                "账目数量",
                _safe_csv_text(category.category_name),
                "",
                category.transaction_count,
                "",
            ]
        )
    for merchant in report.merchants:
        writer.writerow(
            [
                "商户",
                "净消费",
                _safe_csv_text(merchant.merchant_name),
                _yuan_number(merchant.net_consumption_minor),
                merchant.transaction_count,
                "",
            ]
        )
    for source in report.sources:
        writer.writerow(
            ["记账来源", _source_label(source.source.value), "", "", source.transaction_count, ""]
        )
    for key, value in report.completeness.model_dump().items():
        writer.writerow(["待处理", COMPLETENESS_LABELS[key], "", "", value, ""])
    if isinstance(report, PeriodReportV2):
        for point in report.daily:
            for key, value in point.model_dump(exclude={"date"}).items():
                writer.writerow(
                    [
                        "每日趋势",
                        CATEGORY_LABELS[key],
                        point.date.isoformat(),
                        _yuan_number(value),
                        "",
                        "",
                    ]
                )
        for event in report.known_future_events:
            event_kind = (
                f"{_direction_label(event.direction.value)} · "
                f"{_certainty_label(event.certainty.value)}"
            )
            writer.writerow(
                [
                    "已知未来",
                    event_kind,
                    _safe_csv_text(event.title),
                    _yuan_number(event.amount_minor),
                    "",
                    event.date.isoformat(),
                ]
            )
        for cycle in report.debt_cycles:
            writer.writerow(
                [
                    "债务账期",
                    "待还金额",
                    _safe_csv_text(cycle.account_name),
                    _yuan_number(cycle.remaining_minor),
                    "",
                    f"还款日 {cycle.due_date.isoformat()}",
                ]
            )
        for installment in report.installments:
            for key, value in (
                ("计划本金", installment.principal_scheduled_gross_minor),
                ("计划费用", installment.fee_scheduled_gross_minor),
                ("计划合计", installment.total_scheduled_gross_minor),
            ):
                writer.writerow(["分期计划", key, installment.month, _yuan_number(value), "", ""])
            writer.writerow(
                ["分期计划", "期数", installment.month, "", installment.period_count, ""]
            )
    return _bounded(("\ufeff" + buffer.getvalue()).encode("utf-8"))


def report_pdf(report: PeriodReport | PeriodReportV2) -> bytes:
    """Create a compact Unicode PDF from exactly the same canonical snapshot.

    The built-in Adobe GB CID font avoids system-font variability for Chinese
    labels.  The document deliberately contains summaries and safe aggregate
    labels only; evidence titles, notes and provider/original-statement data
    do not cross the export boundary.
    """
    lines = ["汇总（元）"]
    lines.extend(
        f"{SUMMARY_LABELS[key]}：{_yuan_text(value)}"
        for key, value in report.summary.model_dump().items()
    )
    lines.append("")
    lines.append("分类")
    lines.extend(
        (
            f"{row.category_name}：净消费 {_yuan_text(row.net_consumption_minor)}"
            f"（{row.transaction_count} 笔）"
        )
        for row in report.categories
    )
    lines.append("")
    lines.append("账户")
    lines.extend(
        (
            f"{row.account_name}：期初 {_yuan_text(row.opening_balance_minor)}，"
            f"期末 {_yuan_text(row.closing_balance_minor)}，"
            f"流入 {_yuan_text(row.period_inflow_minor)}，"
            f"流出 {_yuan_text(row.period_outflow_minor)}"
        )
        for row in report.accounts
    )
    lines.append("")
    lines.append("商户")
    lines.extend(
        (
            f"{row.merchant_name}：净消费 {_yuan_text(row.net_consumption_minor)}"
            f"（{row.transaction_count} 笔）"
        )
        for row in report.merchants
    )
    lines.append("")
    lines.append("记账来源")
    lines.extend(
        f"{_source_label(row.source.value)}：{row.transaction_count} 笔" for row in report.sources
    )
    lines.append("")
    lines.append("待处理")
    lines.extend(
        f"{COMPLETENESS_LABELS[key]}：{value} 项"
        for key, value in report.completeness.model_dump().items()
    )
    if isinstance(report, PeriodReportV2):
        lines.append("")
        lines.append("已知未来事项")
        lines.extend(
            f"{row.date} {row.title}：{_yuan_text(row.amount_minor)}，"
            f"{_direction_label(row.direction.value)} · {_certainty_label(row.certainty.value)}"
            for row in report.known_future_events
        )
        lines.append("")
        lines.append("债务账期")
        lines.extend(
            f"{row.account_name} {row.due_date}：待还 {_yuan_text(row.remaining_minor)}"
            for row in report.debt_cycles
        )
        lines.append("")
        lines.append("分期计划")
        lines.extend(
            (
                f"{row.month}：本金 {_yuan_text(row.principal_scheduled_gross_minor)}，"
                f"费用 {_yuan_text(row.fee_scheduled_gross_minor)}，"
                f"合计 {_yuan_text(row.total_scheduled_gross_minor)}，共 {row.period_count} 期"
            )
            for row in report.installments
        )
    return _bounded(
        _unicode_pdf(
            lines,
            title=f"Fiscal report {report.meta.period}",
            header=(
                "Fiscal 报告",
                f"期间：{report.meta.period}（{report.meta.date_from} 至 {report.meta.date_to}）",
                "口径：上海时间 · 人民币",
                f"生成：{_visible_datetime(report.meta.generated_at)}",
            ),
        )
    )


def report_export_filename(report: PeriodReport | PeriodReportV2, extension: str) -> str:
    return f"Fiscal-report-{report.meta.period}.{extension}"


def _yuan_number(value: int) -> str:
    sign = "-" if value < 0 else ""
    major, minor = divmod(abs(value), 100)
    return f"{sign}{major}.{minor:02d}"


def _yuan_text(value: int) -> str:
    sign = "-" if value < 0 else ""
    major, minor = divmod(abs(value), 100)
    return f"{sign}¥{major:,}.{minor:02d}"


def _visible_datetime(value: datetime) -> str:
    return value.astimezone(SHANGHAI).strftime("%Y-%m-%d %H:%M")


def _source_label(value: str) -> str:
    return SOURCE_LABELS.get(value, "其他来源")


def _direction_label(value: str) -> str:
    return "流入" if value == "inflow" else "流出"


def _certainty_label(value: str) -> str:
    return {
        "exact_due": "明确到期",
        "confirmed": "已确认",
        "expected": "预计",
        "scheduled": "已排期",
    }.get(value, "已知事项")


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
