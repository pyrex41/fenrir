"""Count persistent C queue cells per search using independently verified oracle rows."""
import argparse
from pathlib import Path
from runpy import run_path
import subprocess
import sys
from tempfile import TemporaryDirectory

from verify import check


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    cases = args.corpus.read_text().splitlines()
    rows = sys.stdin.read()
    check(cases, rows.splitlines())
    c_table = run_path(str(here / "measure-spt.py"))["c_table"]
    with TemporaryDirectory() as work:
        directory = Path(work)
        (directory / "corpus.h").write_text(c_table(args.corpus, rows, "search"))
        binary = directory / "count"
        subprocess.run(["cc", "-O2", "-I", work, here / "count-queue.c", "-o", binary],
                       check=True, timeout=120)
        output = subprocess.check_output([binary], text=True, timeout=60).splitlines()
    if len(output) != len(cases):
        raise ValueError("queue diagnostic returned an incomplete corpus")
    print("case\tsteps\tqueue_cells_including_initial\tcopied_cells\tmax_switch_width")
    for index, (case, counters) in enumerate(zip(cases, output)):
        observed, steps, cells, copies, width = map(int, counters.split())
        if observed != index:
            raise ValueError("queue diagnostic returned cases out of order")
        print(case.split()[0], steps, cells, copies, width, sep="\t")


if __name__ == "__main__":
    main()
