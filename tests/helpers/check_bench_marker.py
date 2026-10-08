"""Check marker CSV contracts using the built FASTQ benchmark harness."""

import csv
import io
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT / "benchmarks" / "bench_fastq"


def rows(output):
    reader = csv.DictReader(io.StringIO(output))
    result = list(reader)
    assert result and all(None not in row and None not in row.values() for row in result)
    return result


def run(*args):
    return subprocess.run(
        [str(BENCH), *map(str, args)], cwd=ROOT, text=True,
        capture_output=True, check=True,
    ).stdout


def write_csv(path, fields, records):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(records)


def main():
    raw = rows(run(
        "--repeat:1", "--warmup:0", "--threads:1", "--modes:api,cli-null",
        "--no-gunzip", "--no-pigz", ROOT / "tests/corpus/small_text.gz",
    ))
    marker_fields = [name for name in raw[0] if name.startswith("marker_")
                     and name != "marker_enabled"]
    assert len(marker_fields) == 10
    api = next(row for row in raw if row["mode"] == "api-read-crc")
    assert api["marker_fallback_reason"] == "mfrNone"
    assert api["marker_replayed_bytes"] == "0"
    external = next(row for row in raw if row["mode"] == "cli-stdout-null")
    assert all(external[name] == "" for name in marker_fields)

    with tempfile.TemporaryDirectory(prefix="gzfast-bench-csv-") as directory:
        path = Path(directory) / "results.csv"
        fields = list(api)
        write_csv(path, fields, raw)
        summary = rows(run("--summary:" + str(path)))
        assert any(row["marker_fallback_reasons"] == "mfrNone" for row in summary)

        old_fields = [name for name in fields if name not in marker_fields]
        write_csv(path, old_fields, [
            {name: row[name] for name in old_fields} for row in raw
        ])
        legacy = rows(run("--summary:" + str(path)))
        assert all(row["marker_fallback_reasons"] == "" for row in legacy)
        assert all(row["max_marker_replayed_bytes"] == "" for row in legacy)

        first = dict(api, marker_fallback_reason="mfrDecodeRejected",
                     marker_fallback_detail="mdsOutputLimit, diagnostic",
                     marker_exact_status="edsOutputLimit",
                     marker_committed_bytes="4000", marker_replayed_bytes="4000",
                     marker_fallback_bytes="6258", marker_bytes_before_fallback="4000")
        second = dict(first, marker_fallback_reason="mfrBoundaryMismatch",
                      marker_fallback_detail="", marker_committed_bytes="2000",
                      marker_replayed_bytes="2000", marker_fallback_bytes="8258",
                      marker_bytes_before_fallback="2000")
        write_csv(path, fields, [first, second])
        combined = rows(run("--summary:" + str(path)))
        assert len(combined) == 1
        row = combined[0]
        assert row["marker_fallback_reasons"] == "mfrDecodeRejected|mfrBoundaryMismatch"
        assert "mdsOutputLimit, diagnostic" in row["marker_fallback_details"]
        assert row["max_marker_committed_bytes"] == "4000"
        assert row["max_marker_replayed_bytes"] == "4000"
        assert row["max_marker_fallback_bytes"] == "8258"

        missing = [name for name in fields if name != "marker_replayed_bytes"]
        write_csv(path, missing, [{name: first[name] for name in missing}])
        failed = subprocess.run([str(BENCH), "--summary:" + str(path)],
                                text=True, capture_output=True)
        assert failed.returncode != 0
        assert "marker_replayed_bytes" in failed.stderr
    print("Marker CSV contracts passed (new, legacy, aggregation, malformed schema).")


if __name__ == "__main__":
    main()
