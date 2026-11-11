"""Export the rpt_* reporting views to CSV files in results/.

The script drives the mysql command-line client, so it needs no Python
database driver and never sees a password: authentication is left to the
client (a stored login path, or the client's own password prompt).

Examples
--------
Store your credentials once (you type the password; it is kept outside the
project, not in plain text):

    mysql_config_editor set --login-path=readmissions --user=root --password

Then:

    python scripts/export_results.py --login-path readmissions

Or let the client ask for the password each time:

    python scripts/export_results.py --user root --ask-password
"""
from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from pathlib import Path

DATABASE = "readmissions"

# view name -> ORDER BY clause, so every export has a stable row order
VIEWS = {
    "rpt_headline": "",
    "rpt_patient_concentration": "ORDER BY sort_key",
    "rpt_segment_rates": "ORDER BY dimension_order, segment_order, rate_pct DESC",
    "rpt_hba1c_by_diagnosis": "ORDER BY pct_tested DESC",
    "rpt_score_calibration": "ORDER BY risk_score_capped",
    "rpt_risk_tiers": "ORDER BY risk_tier_order DESC",
}


def client_arguments(args: argparse.Namespace) -> list[str]:
    command = [args.mysql]
    if args.login_path:
        # --login-path must be the first option the client sees
        command.append(f"--login-path={args.login_path}")
    if args.host:
        command.append(f"--host={args.host}")
    if args.port:
        command += [f"--port={args.port}", "--protocol=TCP"]
    if args.user:
        command.append(f"--user={args.user}")
    if args.ask_password:
        command.append("--password")
    command += ["--batch", "--default-character-set=utf8mb4", DATABASE]
    return command


def export_view(base_command: list[str], view: str, order_by: str, out_dir: Path) -> int:
    query = f"SELECT * FROM {view} {order_by}".strip()
    completed = subprocess.run(base_command + ["-e", query], capture_output=True, text=True, encoding="utf-8")
    if completed.returncode != 0:
        sys.exit(f"mysql failed on {view}:\n{completed.stderr.strip()}")
    lines = completed.stdout.splitlines()
    rows = [["" if cell == "NULL" else cell for cell in line.split("\t")] for line in lines]
    out_path = out_dir / f"{view}.csv"
    with out_path.open("w", newline="", encoding="utf-8") as handle:
        csv.writer(handle).writerows(rows)
    return len(rows) - 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mysql", default="mysql", help="path to the mysql client (default: mysql on PATH)")
    parser.add_argument("--login-path", help="login path stored with mysql_config_editor")
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    parser.add_argument("--user")
    parser.add_argument("--ask-password", action="store_true", help="let the mysql client prompt for the password")
    parser.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "results"))
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    base_command = client_arguments(args)
    for view, order_by in VIEWS.items():
        n_rows = export_view(base_command, view, order_by, out_dir)
        print(f"{view:<28} {n_rows:>3} rows -> {out_dir / (view + '.csv')}")


if __name__ == "__main__":
    main()
