"""Run Python unit tests with stdlib line coverage; no added test dependency."""
from pathlib import Path
import sys
import trace
import unittest

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1])
# Discovery must happen inside tracing so top-level module definitions are included.
def run():
    suite = unittest.TestLoader().discover(str(root / 'Tests' / 'HelperTests'))
    return unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful()
tracer = trace.Trace(count=True, trace=False, ignoredirs=[sys.base_prefix, sys.prefix])
success = tracer.runfunc(run)
results = tracer.results()
# Exclude tests and installed dependencies from the production report.
results.counts = {(filename, line): count for (filename, line), count in results.counts.items()
                  if any(Path(filename).resolve().is_relative_to(root / folder)
                         for folder in ('helper', 'scripts'))}
results.write_results(show_missing=True, summary=True, coverdir=str(out / 'python'))
if not success: sys.exit(1)
