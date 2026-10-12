"""核对提交包的源码、测试、综合和演示证据，生成可验证的文件清单。"""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {"base": ("attention_ip.v", 1218, 125),
            "mask": ("attention_ip_causal_mask.v", 1065, 125),
            "ab": ("attention_ip_parallel.v", 1071, 93),
            "dot": ("attention_ip_parallel_dot.v", 1076, 69)}


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def included(path):
    relative = path.relative_to(ROOT)
    if any(part in {"build", "project", "learning", "__pycache__", ".Xil"} for part in relative.parts):
        return False
    if path.suffix.lower() in {".pyc", ".jou", ".dmp", ".dll", ".exe", ".vvp"}:
        return False
    if path.name.startswith(("hs_err_pid", "synthesis_attempt")):
        return False
    return path.name not in {"rerun_console.log", "source_copy_manifest.json", "manifest_sha256.json"}


def resource_value(text, label):
    return int(re.search(r"\|\s*" + re.escape(label) + r"\*?\s*\|\s*(\d+)", text).group(1))


def main():
    tests, synthesis = {}, {}
    for version, (name, cases, cycles) in VERSIONS.items():
        status = load(ROOT / "tests" / version / "results/validation.json")
        assert status.get("passed", status.get("functional_checks_passed"))
        assert status["simulator_exit_code"] == 0 and status["cases"] == cases
        if version in {"ab", "dot"}:
            assert status["fast_restart_passed"] and status["fast_restart_exit_code"] == 0
        for filename, expected in status["source_sha256"].items():
            candidates = [ROOT / "tests" / version / folder / filename for folder in ("rtl", "reference_rtl", "tb")]
            source = next(path for path in candidates if path.exists())
            assert digest(source) == expected.lower(), source
        for filename in (name, "exp_lut.v", "round_div_signed.v"):
            assert (ROOT / "tests" / version / "rtl" / filename).read_bytes() == (ROOT / "demo/rtl" / filename).read_bytes()
        tests[version] = {"cases": cases, "passed": True, "simulator_exit_code": 0, "start_to_done_cycles": cycles}
        folder = ROOT / "evidence/synthesis" / version
        report = (folder / "utilization.rpt").read_text()
        summary = (folder / "summary.txt").read_text()
        assert "part=xc7z010iclg225-1L" in summary and "period_ns=10.0" in summary and "latches=0" in summary
        synthesis[version] = {"LUT": resource_value(report, "Slice LUTs"),
                              "FF": resource_value(report, "Slice Registers"),
                              "DSP": resource_value(report, "DSPs"),
                              "BRAM": resource_value(report, "Block RAM Tile"),
                              "WNS_ns": float(re.search(r"worst_slack_ns=(.*)", summary).group(1)),
                              "rtl_sha256": digest(ROOT / "demo/rtl" / name)}
    synthesis_log = (ROOT / "evidence/synthesis.log").read_text(encoding="utf-8", errors="replace")
    assert "SUBMISSION_ALL_SYNTHESIS_COMPLETED" in synthesis_log
    demo_log = (ROOT / "evidence/demo/submission_demo.log").read_text(encoding="utf-8", errors="replace")
    completed = re.findall(r"(?m)^FOUR_DEMO_COMPLETED: (\w+)", demo_log)
    demo_cycles = [int(x) for x in re.findall(r"(?m)^CYCLES: start_to_done=(\d+)", demo_log)]
    assert completed == list(VERSIONS) and demo_cycles == [125, 125, 93, 69]
    assert "SUBMISSION_ALL_DEMOS_COMPLETED" in demo_log
    assert not re.search(r"(?m)^ERROR:", demo_log)
    status = {"date": "2026-10-12", "tests": tests, "synthesis": synthesis,
              "synthesis_part": "xc7z010iclg225-1L", "synthesis_clock_period_ns": 10.0,
              "synthesis_reports_completed": True,
              "synthesis_exit_code": int((ROOT / "evidence/synthesis_exit.txt").read_text(encoding="utf-8-sig")),
              "demo_versions_completed": completed, "demo_cycles": demo_cycles,
              "demo_exit_code": int((ROOT / "evidence/demo/submission_demo_exit.txt").read_text(encoding="utf-8-sig")),
              "scope": "功能自检、四版现场入口和综合后模块内部时序；不包含布局布线或上板。"}
    (ROOT / "evidence/submission_validation.json").write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
    files = sorted(path for path in ROOT.rglob("*") if path.is_file() and included(path))
    manifest = {path.relative_to(ROOT).as_posix(): digest(path) for path in files}
    (ROOT / "manifest_sha256.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"files": len(files) + 1, "bytes": sum(path.stat().st_size for path in files),
                      "tests_passed": True, "demo_passed": True, "synthesis_reports_completed": True}, ensure_ascii=False))


if __name__ == "__main__":
    main()
