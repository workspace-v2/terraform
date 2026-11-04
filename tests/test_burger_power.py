"""Mock AWS to prove power-off stays in Burgerpedia and refuses active deployments."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / "scripts/burger-power.sh"


class PowerTest(unittest.TestCase):
    def run_power(self, active=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"region": "ap-northeast-2", "environments": {"main": {
                "service": "burger-main", "database_id": "i-burger-db", "redis_id": "i-burger-redis"
            }}}
            terraform = root / "terraform"
            terraform.write_text("#!/bin/sh\nprintf '%s' '" + json.dumps(config) + "'\n")
            terraform.chmod(0o755)
            aws = root / "aws"
            aws.write_text('''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['AWS_TEST_LOG'],'a') as log:log.write(json.dumps(args)+'\\n')
if 'list-deployments' in args: print('["d-active"]' if os.environ.get('TEST_ACTIVE')=='1' else '[]')
elif 'describe-services' in args:
 print('arn:aws:ecs:region:account:service/burger/burger-main' if 'serviceArn' in ' '.join(args) else '1')
elif 'list-tasks' in args: print('[]' if '--output' in args and args[-1]=='json' else '0')
else: print('{}')
''')
            aws.chmod(0o755)
            log = root / "aws.log"
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       AWS_TEST_LOG=str(log), TEST_ACTIVE='1' if active else '0')
            result = subprocess.run(['bash', str(SCRIPT), 'main', 'stop'], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return result, calls

    def test_stop_only_changes_selected_environment(self):
        result, calls = self.run_power()
        self.assertEqual(result.returncode, 0, result.stderr)
        stops = [call for call in calls if 'stop-instances' in call]
        self.assertEqual(len(stops), 1)
        self.assertIn('i-burger-db', stops[0])
        self.assertIn('i-burger-redis', stops[0])
        self.assertFalse(any('monitoring' in ' '.join(call) or 'load-generator' in ' '.join(call) for call in calls))
        update = next(i for i, call in enumerate(calls) if 'update-service' in call)
        stop = next(i for i, call in enumerate(calls) if 'stop-instances' in call)
        self.assertLess(update, stop)

    def test_active_deployment_blocks_power_off(self):
        result, calls = self.run_power(active=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('stop-instances' in call or 'update-service' in call for call in calls))


if __name__ == '__main__':
    unittest.main()
