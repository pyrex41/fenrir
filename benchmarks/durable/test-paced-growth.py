"""Regression cases for durable-service backlog evidence."""
from pathlib import Path
from runpy import run_path
import unittest


growth = run_path(str(Path(__file__).with_name("assess-paced.py")))["sustained_growth"]


class Growth(unittest.TestCase):
    def test_slow_accumulation_across_minute_boundaries(self):
        queue = [(second + 30) // 60 for second in range(600)]
        self.assertTrue(growth(queue))
        self.assertFalse(growth(queue[:-1]))

    def test_transient_and_stationary_backlogs(self):
        for queue in ([0] * 599 + [10], [8] * 600, list(range(60)) * 10):
            self.assertFalse(growth(queue))

    def test_recovery_after_accumulation(self):
        queue = [second // 60 for second in range(600)]
        self.assertTrue(growth(queue))
        queue[-1] = 0
        self.assertFalse(growth(queue))


if __name__ == "__main__":
    unittest.main()
