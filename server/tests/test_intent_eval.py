"""意图评测 fixture 全绿（plan §9.6 的离线门禁）。"""
from app import eval as intent_eval


def test_intent_fixture_is_aligned():
    passed, total, failures = intent_eval.evaluate()
    assert passed == total, failures


def test_fixture_cases_are_well_formed():
    cases = intent_eval.load()
    assert len(cases) >= 12
    names = set()
    for case in cases:
        assert case["name"] and case["input"]
        assert case["name"] not in names, "case names must be unique"
        names.add(case["name"])
        assert "expect" in case and ("reply" in case or "operations" in case)
