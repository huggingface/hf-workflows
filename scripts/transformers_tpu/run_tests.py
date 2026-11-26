"""Run test folders on a TPU v6e-4 host.

`single-gpu`: one pytest process per chip, each taking folders from a shared queue.
`multi-gpu`: one pytest process holding every chip, running the folders one after the other.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

TIER2_ROOT = Path("/dev/shm/torch_tpu_cache")
NUM_CHIPS = 4
STAGGER_S = 5
TEST_TIMEOUT_S = 3600
# `pytest-timeout` does not catch a native abort or a hang inside torch-tpu.
FOLDER_TIMEOUT_S = 3 * 3600
MIN_FREE_GB = 100


def chip_env(chip):
    return {
        "ALLOW_MULTIPLE_LIBTPU_LOAD": "1",
        "TPU_CHIPS_PER_PROCESS_BOUNDS": "1,1,1",
        "TPU_PROCESS_BOUNDS": "1,1,1",
        "TPU_VISIBLE_CHIPS": str(chip),
        "TPU_VISIBLE_DEVICES": str(chip),
        "TPU_PROCESS_PORT": str(8476 + chip),
    }


def log(message):
    print(f"[{time.strftime('%H:%M:%S', time.gmtime())}] {message}", flush=True)


class Runner:
    def __init__(self, args):
        self.args = args
        self.pending = list(args.folders)
        self.outcomes = {}
        self.running = {}
        self.stop = None
        self.cancelled = False
        self.last_start = 0.0
        self.lock = threading.Lock()
        self.start_lock = threading.Lock()

    def report_name(self, folder):
        if self.args.single_report == "true":
            return f"{self.args.machine_type}_{self.args.report_name_prefix}_test_reports"
        # As `notification_service.py` names the reports.
        folder = folder.replace("models/", "models_").replace("quantization/", "quantization_")
        return f"{self.args.machine_type}_{self.args.report_name_prefix}_{folder}_test_reports"

    def cancel(self, signum, frame):
        self.stop = "the job was cancelled"
        self.cancelled = True
        # Waits for a launch in progress, which then sees the cancellation or is registered.
        with self.start_lock:
            for proc in list(self.running.values()):
                os.killpg(proc.pid, signal.SIGKILL)

    def next_folder(self):
        with self.lock:
            if self.stop or not self.pending:
                return None
            free_gb = shutil.disk_usage(self.args.hub_cache_root).free / 2**30
            if free_gb < MIN_FREE_GB:
                self.stop = f"only {free_gb:.0f} GB free on {self.args.hub_cache_root}"
                return None
            return self.pending.pop(0)

    def worker(self, index):
        tier2_name = f"ci-w{index}"
        hub_cache = self.args.hub_cache_root / f"w{index}"
        while (folder := self.next_folder()) is not None:
            shutil.rmtree(TIER2_ROOT / tier2_name, ignore_errors=True)
            shutil.rmtree(hub_cache, ignore_errors=True)
            env = os.environ.copy()
            env.update(
                PYTEST_ADDOPTS=f"--timeout={TEST_TIMEOUT_S}",
                TORCH_TPU_TIER2_COMPILATION_CACHE=tier2_name,
                HF_HUB_CACHE=str(hub_cache),
            )
            if self.args.machine_type == "single-gpu":
                env.update(chip_env(index))
            name = self.report_name(folder)
            cmd = [sys.executable, "-m", "pytest", "-rsfE", "-v", f"--make-reports={name}", f"tests/{folder}"]
            if self.args.pytest_marker:
                cmd += ["-m", self.args.pytest_marker]

            with open(self.args.logs_dir / f"{name}.log", "w", encoding="utf-8") as log_file:
                # Processes that initialise the TPU at the same moment can wait 30 s more.
                with self.start_lock:
                    time.sleep(max(0.0, STAGGER_S - (time.time() - self.last_start)))
                    if self.cancelled:
                        return
                    self.last_start = start = time.time()
                    proc = subprocess.Popen(
                        cmd, env=env, stdout=log_file, stderr=subprocess.STDOUT, start_new_session=True
                    )
                    self.running[index] = proc
                try:
                    outcome = f"exit code {proc.wait(timeout=FOLDER_TIMEOUT_S)}"
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                    outcome = f"killed after {FOLDER_TIMEOUT_S} s"
                self.running.pop(index, None)
            shutil.rmtree(hub_cache, ignore_errors=True)

            elapsed = time.time() - start
            with self.lock:
                self.outcomes[folder] = (proc.returncode, outcome)
                with open(self.args.logs_dir / "timings.tsv", "a", encoding="utf-8") as fp:
                    fp.write(f"{self.args.machine_type}\t{folder}\t{index}\t{elapsed:.0f}\t{outcome}\n")
                log(f"worker {index}: {folder} took {elapsed:.0f} s, {outcome}, {len(self.pending)} left")

    def run(self):
        workers = NUM_CHIPS if self.args.machine_type == "single-gpu" else 1
        begin = time.time()
        log(f"{self.args.machine_type}: {len(self.args.folders)} folders, {workers} worker(s)")
        threads = [threading.Thread(target=self.worker, args=(index,)) for index in range(workers)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        log(f"done in {time.time() - begin:.0f} s")

        failed = False
        for folder in self.args.folders:
            code, outcome = self.outcomes.get(folder, (None, f"not run: {self.stop}"))
            failed |= code != 0
            name = self.report_name(folder)
            report_dir = Path("reports") / name
            if report_dir.is_dir():
                (report_dir / "job_link.txt").write_text(self.args.job_link)
            if not (report_dir / "stats.txt").exists():
                print(f"::error::tests/{folder} produced no report ({outcome})")
                log_path = self.args.logs_dir / f"{name}.log"
                if log_path.exists():
                    print("\n".join(log_path.read_text(errors="replace").splitlines()[-50:]))
        return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folders", type=json.loads, required=True, help="JSON list of folders under `tests/`")
    parser.add_argument("--machine-type", choices=["single-gpu", "multi-gpu"], required=True)
    parser.add_argument("--report-name-prefix", required=True)
    parser.add_argument(
        "--single-report", choices=["true", "false"], default="false", help="Leave the folder out of the report name"
    )
    parser.add_argument("--pytest-marker", default="")
    parser.add_argument("--hub-cache-root", type=Path, required=True)
    parser.add_argument("--logs-dir", type=Path, required=True)
    parser.add_argument("--job-link", required=True, help="URL of the job, written to each report")
    args = parser.parse_args()

    if not args.job_link.split("/job/")[-1]:
        sys.exit(f"::error::no job ID in {args.job_link}: `job.check_run_id` needs runner 2.324.0 or later")
    args.hub_cache_root.mkdir(parents=True, exist_ok=True)
    args.logs_dir.mkdir(parents=True, exist_ok=True)

    runner = Runner(args)
    signal.signal(signal.SIGTERM, runner.cancel)
    signal.signal(signal.SIGINT, runner.cancel)
    sys.exit(runner.run())


if __name__ == "__main__":
    main()
