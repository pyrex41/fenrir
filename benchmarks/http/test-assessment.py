"""Regression cases at the sustainable-rate evidence boundary."""
from copy import deepcopy
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from runpy import run_path
import subprocess
import unittest
from unittest.mock import MagicMock, Mock, patch

assess = run_path(str(Path(__file__).with_name("assess-rate.py")))["assess"]


def valid_row():
    return dict(Seconds=600, Rate=10, Connections=2, Scheduled=6000, Valid=6000,
                Invalid=0, Errors=0, Missed=0, ElapsedNs=600_000_010_000,
                P50ns=100, P99ns=200, MaxNs=400,
                Timeline=[dict(Second=i, Scheduled=min(6000, i*10+1),
                               Completed=i*10, Backlog=int(i<600), ObservedNs=i*10**9)
                          for i in range(1, 601)])


class Assessment(unittest.TestCase):
    def test_slowest_request_must_finish_within_measured_run(self):
        row = valid_row()
        index = row["Scheduled"] - 1
        duration = row["ElapsedNs"] - index * 10**9 // row["Rate"]
        row["SlowestValid"] = dict(Index=index, Lane=index % row["Connections"],
                                   ElapsedNs=duration, PreviousRequestNs=0,
                                   DispatchNs=0, FetchNs=duration)
        row["MaxNs"] = duration
        assess(row)
        row["MaxNs"] += 1
        row["SlowestValid"]["ElapsedNs"] += 1
        row["SlowestValid"]["FetchNs"] += 1
        with self.assertRaisesRegex(ValueError, "finished after the run"):
            assess(row)

    def test_guest_memory_retries_only_a_timed_out_snapshot(self):
        guest_memory = run_path(str(Path(__file__).with_name("sweep.py")))["guest_memory"]
        timeout = subprocess.TimeoutExpired("docker", 10)
        snapshot = ("Cpus_allowed_list: 2\nRollupRss: 10 kB\nVmRSS: 12 kB\n"
                    "VmHWM: 16 kB\nMemTotal: 256 kB\nMemAvailable: 128 kB\n")
        with patch.object(subprocess, "check_output", side_effect=[timeout, snapshot]) as read:
            self.assertEqual(guest_memory("container", 2)["tender_rollup_rss_bytes"], 10240)
            first, second = read.call_args_list
            self.assertEqual(first.args, second.args)
            self.assertEqual([first.kwargs["timeout"], second.kwargs["timeout"]], [10, 30])
        with patch.object(subprocess, "check_output", side_effect=timeout) as read:
            with self.assertRaises(subprocess.TimeoutExpired):
                guest_memory("container", 2)
            self.assertEqual(read.call_count, 2)
        with patch.object(subprocess, "check_output", return_value=snapshot) as read:
            with self.assertRaisesRegex(ValueError, "affinity changed"):
                guest_memory("container", 3)
            read.assert_called_once()

    def test_load_result_survives_periodic_sampler_timeouts(self):
        run_load = run_path(str(Path(__file__).with_name("sweep.py")))["run_load"]
        timeout = subprocess.TimeoutExpired("ps", 5)
        client = MagicMock()
        client.__enter__.return_value = client
        client.returncode = 1
        client.communicate.side_effect = [timeout, timeout, (b"overload report", b"")]
        process_samples = Mock(side_effect=[{"cpu_seconds": 0}, timeout, {"cpu_seconds": 1},
                                            {"cpu_seconds": 2}])
        with patch.object(subprocess, "Popen", return_value=client), patch.dict(
                run_load.__globals__, mac_resources=process_samples, mac_cpu_load=Mock(side_effect=timeout)):
            raw, samples = run_load(["load"], 10, 123)
        self.assertEqual(raw, b"overload report")
        self.assertEqual(samples, [{"cpu_seconds": 0}, {"cpu_seconds": 1}, {"cpu_seconds": 2}])
        client.kill.assert_not_called()

    def test_single_capacity_sweep_requires_the_driver_and_servers(self):
        summarize = run_path(str(Path(__file__).with_name("capacity.py")))["summarize"]
        with TemporaryDirectory() as tmp:
            folder = Path(tmp)
            env = dict(target="mac", blocks=1, rates=[100], binaries={
                role: "a" * 64 for role in ("fenrir", "rust", "nim")
            })
            (folder / "environment.json").write_text(json.dumps(env))
            with self.assertRaisesRegex(ValueError, "incomplete benchmark binary identities"):
                summarize(folder)

    def test_invalid_reference_response_withholds_linked_latency(self):
        capacity = run_path(str(Path(__file__).with_name("capacity.py")))["summarize"]
        linked = run_path(str(Path(__file__).with_name("paired-latency.py")))["capacity_linked"]
        workers = ("fenrir", "rust", "nim")
        with TemporaryDirectory() as tmp:
            folder = Path(tmp)
            env = dict(target="mac", blocks=2, rates=[10, 20], seconds=600, connections=2,
                       binaries={role: "a" * 64 for role in (*workers, "load")})
            (folder / "environment.json").write_text(json.dumps(env))
            for block in range(2):
                for index, rate in enumerate(env["rates"]):
                    for worker in workers:
                        row = valid_row()
                        total = 600 * rate
                        row.update(Rate=rate, Scheduled=total, Valid=total, Block=block, RateIndex=index)
                        for t in row["Timeline"]:
                            t["Scheduled"] = min(total, rate * t["Second"] + 1)
                            t["Completed"] = rate * t["Second"]
                        if worker == "nim" or rate == 20:
                            row.update(Errors=total // 100, Valid=total - total // 100)
                        path = folder / f"{2*block+index}-{worker}-{rate}.json"
                        path.write_text(json.dumps(row))
            before = capacity(folder)
            self.assertEqual((before["reference"], before["paired_latency_rate"]), ("rust", 7))
            path = folder / "3-nim-20.json"
            row = json.loads(path.read_text())
            row["Invalid"] = 1
            row["Errors"] -= 1
            path.write_text(json.dumps(row))
            after = capacity(folder)
            self.assertEqual(after["invalid_response_workers"], ["nim"])
            self.assertIsNone(after["reference"])
            self.assertIsNone(after["paired_latency_rate"])
            with self.assertRaisesRegex(ValueError, "not resolved"):
                linked(folder, folder)

    def test_partial_mac_grid_cannot_establish_replicated_capacity(self):
        capacity = run_path(str(Path(__file__).with_name("capacity.py")))["summarize"]
        with TemporaryDirectory() as tmp:
            folder = Path(tmp)
            env = dict(target="mac", blocks=2, rates=[10], seconds=600, connections=2,
                       binaries={role: "a" * 64 for role in ("fenrir", "rust", "nim", "load")})
            (folder / "environment.json").write_text(json.dumps(env))
            row = dict(valid_row(), Block=0, RateIndex=0)
            (folder / "0-rust-10.json").write_text(json.dumps(row))
            report = capacity(folder)
            self.assertEqual(report["observations"]["rust"][10], ["sustained-at-offered-rate", "missing"])
            self.assertEqual(report["capacity_bounds"]["rust"], dict(sustained=None, failed=None))
            self.assertIsNone(report["reference"])
            self.assertIsNone(report["paired_latency_rate"])
            self.assertEqual(report["two_thirds_capacity_comparison"], "undetermined")

    def test_each_capacity_block_has_one_observation_per_rate(self):
        observe = run_path(str(Path(__file__).with_name("capacity.py")))["observations"]
        with TemporaryDirectory() as tmp:
            for blocks, rates in [(0, [100]), (True, [100]), (2, []), (2, [100, 100]), (2, [False])]:
                with self.subTest(blocks=blocks, rates=rates), self.assertRaises(ValueError):
                    observe(Path(tmp), dict(target="mac", blocks=blocks, rates=rates))

    def test_release_requires_replicated_capacity_and_latency(self):
        service_gate = run_path(str(Path(__file__).with_name("paired-latency.py")))["service_gate"]
        def gate(*args):
            return service_gate(*args, origin_version=1)

        meets = "meets-threshold"
        self.assertEqual(gate(1, meets, True, meets), "undetermined")
        self.assertEqual(gate(10, meets, False, meets), "undetermined")
        self.assertEqual(gate(10, "undetermined", True, meets), "undetermined")
        self.assertEqual(gate(10, meets, True, meets), "passed")
        self.assertEqual(gate(10, "below-threshold", False, "undetermined"), "failed")
        self.assertEqual(gate(10, meets, True, "above-threshold"), "failed")

        for version in (None, True, 2):
            self.assertEqual(service_gate(10, meets, True, meets, origin_version=version), "undetermined")

    def test_sample_origin(self):
        verify = run_path(str(Path(__file__).with_name("assess-rate.py")))["verify_sample_origin"]
        env = dict(target="mac", sample_origin_version=1)
        origin = dict(worker="nim", position=0, environment_sha256="digest")
        verify({"Origin": origin}, env, "nim", 1, 1, "digest")
        for change in (dict(worker="rust"), dict(position=1), dict(environment_sha256="other")):
            with self.assertRaises(ValueError):
                verify({"Origin": {**origin, **change}}, env, "nim", 1, 1, "digest")
        with self.assertRaises(ValueError):
            verify({}, env, "nim", 1, 1, "digest")

    def test_origin_requires_integer_version_and_position(self):
        module = run_path(str(Path(__file__).with_name("assess-rate.py")))
        env = dict(target="mac", sample_origin_version=1, darwin_logical_cpu_max=1)
        origin = dict(worker="fenrir", position=0, environment_sha256="digest")
        for version in (True, 1.0):
            invalid = dict(env, sample_origin_version=version)
            with self.assertRaises(ValueError):
                module["darwin_cpu_limit"](invalid)
            with self.assertRaises(ValueError):
                module["verify_sample_origin"]({"Origin": origin}, invalid, "fenrir", 0, 0, "digest")
        for position in (False, 0.0):
            with self.assertRaises(ValueError):
                module["verify_sample_origin"]({"Origin": dict(origin, position=position)},
                                               env, "fenrir", 0, 0, "digest")

    def test_latency_environment_matches_solo5_measurement_conditions(self):
        identity = run_path(str(Path(__file__).with_name("paired-latency.py")))["latency_environment"]
        env = dict(target="solo5", guest_cpuset="2", solo5_memory_method="method-a",
                   rates=[5000, 8000], seconds=600, blocks=2, connections=16,
                   host="machine", cpu="arm64", go="go", checkout_sha256={},
                   solo5_container="image", guest_memory_budget_bytes=32 << 20,
                   binaries={role: "a" * 64 for role in
                             ("load", "spt/ingress", "spt/http.spt", "spt-c/ingress", "spt-c/http.spt")})
        latency = dict(env, rates=[3500], blocks=10,
                       binaries={f"/other/{role}": digest for role, digest in env["binaries"].items()})
        self.assertEqual(identity(env), identity(latency))
        for change in (dict(guest_cpuset="3"), dict(solo5_memory_method="method-b"),
                       dict(binaries={**latency["binaries"], "/other/load": "b" * 64})):
            self.assertNotEqual(identity(env), identity({**latency, **change}))

    def test_recorded_guest_affinity(self):
        verify = run_path(str(Path(__file__).with_name("assess-rate.py")))["verify_sample_origin"]
        env = dict(target="solo5", sample_origin_version=1, guest_cpuset="3",
                   solo5_memory_method="proc-status-smaps-rollup-vm-meminfo-cgroup-peak/3")
        sample = dict(tender_allowed_cpus="3", tender_rollup_rss_bytes=4096,
                      container_lifetime_peak_bytes=None)
        memory = dict(before=dict(sample), after=dict(sample))
        row = dict(Solo5Memory=memory, Origin=dict(worker="fenrir", position=0, environment_sha256="hash"))
        verify(row, env, "fenrir", 0, 0, "hash")
        for endpoint in ("before", "after"):
            memory[endpoint]["tender_allowed_cpus"] = "2-3"
            with self.assertRaisesRegex(ValueError, "affinity"):
                verify(row, env, "fenrir", 0, 0, "hash")
            memory[endpoint] = dict(sample)

    def test_latency_requires_valid_responses_within_the_run(self):
        row = valid_row()
        row.update(Valid=0, Invalid=row["Scheduled"])
        with self.assertRaisesRegex(ValueError, "without a valid response"):
            assess(row)
        row.update(P50ns=0, P99ns=0, MaxNs=0)
        self.assertEqual(assess(row)["verdict"], "invalid-response")
        row = valid_row()
        row["MaxNs"] = row["ElapsedNs"] + 1
        with self.assertRaisesRegex(ValueError, "latency distribution"):
            assess(row)

    def test_completions_after_final_sample(self):
        row = valid_row()
        row["Timeline"][-1].update(Completed=5996, Backlog=4)
        row.update(Valid=5998, Missed=2)
        result = assess(row)["completion_window"]
        self.assertEqual(result, dict(completed_by_last_sample=5996, completed_after_last_sample=2,
                                      last_sample_ns=600_000_000_000, remaining_wall_ns=10000))

    def test_last_valid_completion(self):
        row = valid_row()
        cutoff = row["Seconds"] * 10**9
        for invalid in (True, 400, cutoff + 1, row["ElapsedNs"] + 1):
            with self.assertRaisesRegex(ValueError, "last valid response"):
                assess(dict(row, LastValidCompletionNs=invalid))
        row["Timeline"][-1].update(Completed=5999, Backlog=1)
        window = assess(dict(row, LastValidCompletionNs=cutoff + 500))["completion_window"]
        self.assertEqual(window["last_valid_past_cutoff_ns"], 500)

    def test_complete(self):
        self.assertEqual(assess(valid_row())["verdict"], "sustained-at-offered-rate")

    def test_decreasing_tender_peak(self):
        row = valid_row()
        before = dict(tender_rss_bytes=8192, tender_lifetime_hwm_bytes=16384,
                      vm_total_bytes=65536, vm_available_bytes=32768)
        row["Solo5Memory"] = dict(container_id="a"*64, before=before,
                                  after={**before, "tender_lifetime_hwm_bytes": 12288})
        result = assess(row)
        self.assertEqual(result["verdict"], "sustained-at-offered-rate")
        self.assertEqual(result["solo5_memory"]["tender_hwm_status"], "inconsistent")
        self.assertIsNone(result["solo5_memory"]["tender_lifetime_peak_bytes"])

    def test_errors(self):
        row = valid_row()
        row.update(Valid=5994, Errors=6)
        self.assertEqual(assess(row)["verdict"], "failed-response-criteria")
        row.update(Valid=5995, Errors=5)
        self.assertEqual(assess(row)["verdict"], "sustained-at-offered-rate")
        row.update(Errors=4, Invalid=1)
        self.assertEqual(assess(row)["verdict"], "invalid-response")
        bounds = run_path(str(Path(__file__).with_name("capacity.py")))["bounds"]
        self.assertEqual(bounds({10: ["invalid-response"]}), {"sustained": None, "failed": None})

    def test_transport_error_census(self):
        row = valid_row()
        row.update(Errors=1, Valid=5999, ErrorKinds={"timeout": 1})
        for sample in row["Timeline"]:
            sample["Errors"] = int(sample["Second"] >= 30)
        self.assertEqual(assess(row)["error_kinds"], {"timeout": 1})
        with self.assertRaises(ValueError):
            assess(dict(row, ErrorKinds={}))
        row["Timeline"][31]["Errors"] = 0
        with self.assertRaises(ValueError):
            assess(row)

    def test_missing_and_corrupt(self):
        row = valid_row()
        for key, value in [("Timeline", row["Timeline"][:-1]), ("Valid", 5999),
                           ("ElapsedNs", 500_000_000_000), ("P99ns", 401)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                assess(dict(row, **{key:value}))
        for key, value in [("Scheduled", 0), ("Completed", 6000), ("ObservedNs", 1)]:
            broken = deepcopy(row)
            broken["Timeline"][25][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                assess(broken)

    def test_census_requires_whole_requests(self):
        row = valid_row()
        for invalid in [dict(row, Valid=5999.5, Errors=0.5), dict(row, Errors=False)]:
            with self.assertRaises(ValueError):
                assess(invalid)
        row["Timeline"][0].update(Completed=10.5, Backlog=0.5)
        with self.assertRaises(ValueError):
            assess(row)

    def test_process_resources(self):
        row = valid_row()
        row["ServerResources"] = dict(cpu_seconds=12, cpu_us_per_completed=2000,
            max_sampled_rss_bytes=4096, samples=[
                dict(elapsed_ns=1, cpu_seconds=2, rss_bytes=4096),
                dict(elapsed_ns=6_000_000_001, cpu_seconds=14, rss_bytes=2048)])
        self.assertEqual(assess(row)["process_resources"]["average_cpu_cores"], 2)
        resources = row["ServerResources"]
        self.assertIsNone(assess(row)["process_resources"]["host_cpu"])
        for sample, driver in zip(resources["samples"], [215.0, None]):
            sample["host_cpu"] = dict(server_percent=130, driver_percent=driver, other_processes_percent=10)
        summary = assess(row)["process_resources"]["host_cpu"]
        self.assertEqual(summary["driver_percent"], dict(samples=1, median=215, peak=215))
        self.assertEqual(summary["other_processes_percent"]["samples"], 2)
        resources["samples"][0]["host_cpu"]["driver_percent"] = -1
        with self.assertRaises(ValueError):
            assess(row)
        resources["samples"][0]["host_cpu"]["driver_percent"] = 215
        row["ServerResources"]["cpu_us_per_completed"] = 1750
        with self.assertRaisesRegex(ValueError, "resource summary"):
            assess(row)

    def test_phase_histograms(self):
        row = valid_row()
        bins = [5940, 60] + [0] * 62
        row["ValidRequestPhases"] = dict.fromkeys(("PreviousRequest", "Dispatch", "Fetch"), bins)
        self.assertEqual(assess(row)["phase_p99_upper_ms"]["Dispatch"], 0)
        bins[:2] = [5939, 61]
        self.assertEqual(assess(row)["phase_p99_upper_ms"]["Dispatch"], 0.000001)
        bins[0] -= 1
        with self.assertRaises(ValueError):
            assess(row)

    def test_lane_origin_matches_immediate_predecessor(self):
        row = valid_row()
        row["MaxNs"] = 300_000_000
        row["SlowestValid"] = dict(Index=4, Lane=0, ElapsedNs=row["MaxNs"],
                                   PreviousRequestNs=50_000_000, DispatchNs=0, FetchNs=250_000_000)
        origin = dict(Index=2, Lane=0, ElapsedNs=250_000_000,
                      PreviousRequestNs=0, DispatchNs=0, FetchNs=250_000_000, Valid=True)
        row["SlowestLaneOrigin"] = origin
        assess(row)
        assess(dict(row, SlowestLaneOrigin=dict(origin, RunFetchNs=500_000_000)))
        for bad_fetch in (499_999_999, 500_000_001, False):
            with self.subTest(bad_fetch=bad_fetch), self.assertRaises(ValueError):
                assess(dict(row, SlowestLaneOrigin=dict(origin, RunFetchNs=bad_fetch)))
        for change in (dict(ElapsedNs=249_999_999, FetchNs=249_999_999), dict(Valid=False),
                       dict(Lane=1), dict(ElapsedNs=301_000_000, FetchNs=301_000_000)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                assess(dict(row, SlowestLaneOrigin=dict(origin, **change)))
        assess(dict(row, SlowestValid=dict(row["SlowestValid"], PreviousRequestNs=0,
                                          FetchNs=row["MaxNs"]), SlowestLaneOrigin=dict(
                                              row["SlowestValid"], PreviousRequestNs=0,
                                              FetchNs=row["MaxNs"], Valid=True)))

    def test_backlog(self):
        row = valid_row()
        for s in row["Timeline"][-60:]:
            s["Completed"] -= 4
            s["Backlog"] += 4
        self.assertEqual(assess(row)["verdict"], "backlog-clearance-unconfirmed")

    def test_separated_rising_minute_ranges_bound_capacity(self):
        row = valid_row()
        for sample in row["Timeline"]:
            backlog = 3 + sample["Second"]
            sample.update(Backlog=backlog, Completed=sample["Scheduled"] - backlog)
        self.assertEqual(assess(row)["verdict"], "growing-backlog")
        bounds = run_path(str(Path(__file__).with_name("capacity.py")))["bounds"]
        self.assertEqual(bounds({10: ["growing-backlog", "failed-response-criteria"]})["failed"], 10)
        self.assertIsNone(bounds({10: ["growing-backlog", "missing"]})["failed"])
        # Touching ranges can also arise from a burst followed by a plateau.
        sample = row["Timeline"][60]
        sample.update(Backlog=63, Completed=sample["Scheduled"] - 63)
        self.assertEqual(assess(row)["verdict"], "backlog-clearance-unconfirmed")

    def test_late_sample_does_not_prove_sustained_rate(self):
        row = valid_row()
        delayed = row["Timeline"][99]
        delayed.update(ObservedNs=101 * 10**9, Scheduled=1011, Backlog=11)
        result = assess(row)
        self.assertEqual(result["verdict"], "sampling-cadence-unconfirmed")
        self.assertEqual(result["late_sample_seconds"], [100])
        self.assertEqual(result["max_observed_sample_delay_ns"], 10**9)
        delayed["ObservedNs"] += 1
        with self.assertRaisesRegex(ValueError, "sampling clock"):
            assess(row)

    def test_legacy(self):
        row = valid_row()
        for s in row["Timeline"]:
            del s["ObservedNs"]
        self.assertEqual(assess(row)["verdict"], "sustained-at-offered-rate")
        row["ElapsedNs"] += 2_000_000_000
        self.assertEqual(assess(row)["verdict"], "sampling-cadence-unconfirmed")


if __name__ == "__main__":
    unittest.main()
