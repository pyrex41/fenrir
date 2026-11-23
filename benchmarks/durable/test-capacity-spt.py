"""Verify qualification decisions across Solo5 durable-service rates."""
import json
from pathlib import Path
from runpy import run_path
from tempfile import TemporaryDirectory
import unittest

module = run_path(str(Path(__file__).with_name("capacity-spt.py")))
workers = module["paired"]["workers"]


class Capacity(unittest.TestCase):
    def test_brackets_and_latency(self):
        with TemporaryDirectory() as temp:
            dirs = []
            for rate in (70, 100, 110, 120, 130):
                folder = Path(temp) / str(rate)
                folder.mkdir()
                dirs.append(folder)
                count = rate * 600
                shared = dict(rate=rate, seconds=600, container="test", history=dict(event_count=count + 1,
                              events_sha256=str(rate)), store=dict(commits=count, tenant_counts=[count // 2] * 2))
                for i in range(10):
                    samples = []
                    for worker, limit in zip(workers, (100, 120)):
                        clear = rate <= limit
                        samples.append(dict(worker=worker, directory=str(folder / str(i) / worker),
                                            guest_sha256=worker, sustained_backlog_growth=not clear,
                                            offered_rate_verdict="sustained-at-offered-rate" if clear else "growing-backlog",
                                            acknowledgement_p99_us=100))
                    row = dict(shared=shared, order=workers[::1 if i % 2 == 0 else -1], samples=samples)
                    (folder / f"{i}.json").write_text(json.dumps(row))
            result = module["summarize"](dirs)
            self.assertEqual(result["capacity_bounds"]["fenrir"], dict(sustained=100, failed=110))
            self.assertEqual(result["capacity_bounds"]["c"], dict(sustained=120, failed=130))
            self.assertEqual(result["paired_latency_rate"], 70)
            self.assertEqual(result["p99_at_paired_latency_rate"], "meets-threshold")
            self.assertEqual(result["two_thirds_capacity_comparison"], "meets-threshold")
            self.assertEqual(module["summarize"](dirs[1:])["p99_at_paired_latency_rate"], "undetermined")
            with self.assertRaisesRegex(ValueError, "duplicate offered rate"):
                module["summarize"]([dirs[0], dirs[0]])


if __name__ == "__main__":
    unittest.main()
