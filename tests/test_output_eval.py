from datetime import datetime, timezone

from app.eval import _parse_score
from app.output import generate_json_report, generate_pdf


def test_pdf_is_a_real_pdf():
    pdf = generate_pdf("Title", "line one\nline two\n" * 100)  # long enough for 2+ pages
    assert pdf.startswith(b"%PDF")


def test_json_report_fields():
    data = generate_json_report("AI", "one two three", "id-1", datetime(2026, 1, 1, tzinfo=timezone.utc))
    assert data["report_id"] == "id-1"
    assert data["word_count"] == 3
    assert data["created_at"].startswith("2026-01-01")


def test_parse_score_reads_judge_answer():
    assert _parse_score("SCORE: 8/10\nGood report") == 0.8
    assert _parse_score("score: 7.5 / 10") == 0.75


def test_parse_score_defaults_to_half_when_unreadable():
    assert _parse_score("I think it is fine") == 0.5
