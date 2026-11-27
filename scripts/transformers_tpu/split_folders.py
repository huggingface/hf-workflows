"""Split the test folders into slices, with the important models at the start of each slice.

Run from the `tests` directory of transformers. Prints the `folder_slices` and `slice_ids` outputs.
"""

import argparse
import ast
import json
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subdirs", default="")
    parser.add_argument("--num-slices", type=int, required=True)
    args = parser.parse_args()

    output = subprocess.check_output(
        [sys.executable, "../utils/split_model_tests.py", "--subdirs", args.subdirs, "--num_splits", "1"], text=True
    )
    folders = [folder for split in ast.literal_eval(output) for folder in split]

    sys.path.insert(0, "../utils")
    try:
        from important_files import IMPORTANT_MODELS
    except ImportError:
        IMPORTANT_MODELS = []
    important = {f"models/{model}" for model in IMPORTANT_MODELS}
    ordered = [f for f in folders if f in important] + [f for f in folders if f not in important]

    num_slices = min(args.num_slices, len(ordered))
    print(f"folder_slices={json.dumps([ordered[idx::num_slices] for idx in range(num_slices)])}")
    print(f"slice_ids={json.dumps(list(range(num_slices)))}")


if __name__ == "__main__":
    main()
