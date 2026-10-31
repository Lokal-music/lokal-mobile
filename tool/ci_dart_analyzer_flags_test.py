"""Guard workflow analyzer options against unsupported Dart CLI arguments."""

from pathlib import Path
import unittest


class DartAnalyzerWorkflowFlagsTests(unittest.TestCase):
    def test_analyzer_commands_do_not_use_unsupported_negated_fatal_infos(self):
        # Dart 3.13: --fatal-infos is a one-way flag; --no-fatal-infos
        # exits with status 64 before any source file is analyzed.
        workflows = Path(__file__).resolve().parents[1] / ".github" / "workflows"
        for path in sorted(workflows.glob("*.yml")):
            with self.subTest(workflow=path.name):
                for line in path.read_text(encoding="utf-8").splitlines():
                    if "dart analyze " in line and not line.lstrip().startswith("#"):
                        self.assertNotIn("--no-fatal-infos", line)


if __name__ == "__main__":
    unittest.main()
