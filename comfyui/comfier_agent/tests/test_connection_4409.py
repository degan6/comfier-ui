import logging

from comfier_agent.connection import close_code_backoff_seconds, log_close_code


def test_close_code_4409_no_long_backoff():
    assert close_code_backoff_seconds(4409) == 0.0
    assert close_code_backoff_seconds(4401) == 300.0


def test_close_code_4409_logs_warning(caplog):
    caplog.set_level(logging.WARNING, logger="comfier_agent")
    log_close_code(4409)
    assert any("another machine" in r.message for r in caplog.records)
