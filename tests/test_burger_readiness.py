"""Startup readiness must tolerate transient ALB/transport failures and fail on persistent errors."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

COMMON = Path(__file__).parents[1] / "scripts/burger-common.sh"

class ReadinessTest(unittest.TestCase):
    def check(self, permanent=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"region": "ap-northeast-2"}
            for name, body in {
                "terraform": "#!/bin/sh\nprintf '%s' '" + json.dumps(config) + "'\n",
                "sleep": "#!/bin/sh\nexit 0\n",
                "curl": """#!/usr/bin/env python3
import os
from pathlib import Path
p=Path(os.environ['READINESS_COUNTER'])
n=int(p.read_text())+1 if p.exists() else 1
p.write_text(str(n))
if os.environ.get('PERMANENT_FAILURE')=='1':
 print('502',end='');raise SystemExit(0)
if n==1:
 print('000',end='');raise SystemExit(56)
print('503' if n==2 else '200',end='')
""",
            }.items():
                path=root/name
                path.write_text(body)
                path.chmod(0o755)
            counter=root/'count'
            env=dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'], READINESS_COUNTER=str(counter), PERMANENT_FAILURE='1' if permanent else '0')
            result=subprocess.run(['bash','-c','source "$1"; burger_wait_for_api "https://example.invalid/v1/posts/cursor?limit=1"','test',str(COMMON)],env=env,text=True,capture_output=True)
            return result,int(counter.read_text())

    def test_transport_and_http_errors_are_retried_until_ready(self):
        result,count=self.check()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(count,3)

    def test_persistent_http_failure_does_not_report_success(self):
        result,count=self.check(permanent=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(count,60)
        self.assertIn('Servers remain running',result.stderr)

if __name__=='__main__':
    unittest.main()
