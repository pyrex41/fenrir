"""Check the measured recovery window across both drains of the service scenario."""
from pathlib import Path
from runpy import run_path
import unittest

validate = run_path(str(Path(__file__).with_name("compare-recovery.py")))["check_recovery_timings"]


class RecoveryTimings(unittest.TestCase):
    def setUp(self):
        self.history = dict(scenario="supervised-store-and-worker-recovery", events=[
            ["complete", 0, 0, False, ["failed"]], ["complete", 0, 0, True, ["delivered"]],
            ["drained"], ["complete", 1, 0, True, ["delivered"]], ["drained"]])
        self.timing = dict(worker_kill_to_replacement_observed_us=2, replacement_observed_to_successful_retry_us=3,
                           worker_kill_to_successful_retry_us=5, runner_start_to_verified_empty_us=4,
                           fresh_submit_to_accepted_us=6, fresh_submit_to_respond_us=7,
                           duplicate_submit_to_accepted_us=1, delivery_attempts=2, pending_jobs_at_start=1)

    def test_measured_drain(self):
        validate(self.timing, self.history)

    def test_inconsistent_measurements(self):
        for field, value in (("delivery_attempts", 3), ("pending_jobs_at_start", 2),
                             ("worker_kill_to_successful_retry_us", 6), ("fresh_submit_to_respond_us", 5),
                             ("runner_start_to_verified_empty_us", False), ("duplicate_submit_to_accepted_us", -1)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate(dict(self.timing, **{field: value}), self.history)


if __name__ == "__main__":
    unittest.main()
