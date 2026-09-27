from __future__ import annotations

import csv
from datetime import datetime
from io import StringIO
from zoneinfo import ZoneInfo

from fiscal_api.api.p34_schemas import PeriodReportV2
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


def report_csv(report: PeriodReportV2) -> bytes:
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
    for key in SUMMARY_LABELS:
        value = getattr(report.summary, key)
        writer.writerow(
            [
                "汇总",
                SUMMARY_LABELS[key],
                "",
                _yuan_number(value),
                "",
                report.summary.balance_unavailable_reason if value is None else "",
            ]
        )
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
                    account.balance_unavailable_reason if value is None else "",
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
            f"{_direction_label(event.direction.value)} · {_certainty_label(event.certainty.value)}"
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
        writer.writerow(["分期计划", "期数", installment.month, "", installment.period_count, ""])
    return _bounded(("\ufeff" + buffer.getvalue()).encode("utf-8"))


def report_export_filename(report: PeriodReportV2, extension: str) -> str:
    return f"Fiscal-report-{report.meta.period}.{extension}"


def _yuan_number(value: int | None) -> str:
    if value is None:
        return ""
    sign = "-" if value < 0 else ""
    major, minor = divmod(abs(value), 100)
    return f"{sign}{major}.{minor:02d}"


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
