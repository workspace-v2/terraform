"""Offline tests: discovery follows both deployment colors and keeps environment labels."""
import importlib.util
from pathlib import Path
import sys
import types
import unittest

sys.modules.setdefault("boto3", types.SimpleNamespace())
spec = importlib.util.spec_from_file_location(
    "discovery", Path(__file__).parents[1] / "monitoring/burger/discover.py"
)
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


class ECS:
    def __init__(self, failures=False):
        self.failures = failures

    def get_paginator(self, name):
        return self

    def paginate(self, **kwargs):
        return [{"taskArns": ["blue", "green"]}]

    def describe_tasks(self, **kwargs):
        return {"failures": ["error"] if self.failures else [], "tasks": [
            {"lastStatus": status, "attachments": [{"details": [
                {"name": "privateIPv4Address", "value": ip}
            ]}]} for status, ip in [("RUNNING", "10.0.0.1"), ("RUNNING", "10.0.0.2"), ("STOPPED", "10.0.0.3")]
        ]}


class DiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.config = {"cluster": "burger", "environments": {
            "main": {"database_ip": "10.0.1.1", "redis_ip": "10.0.1.2", "service": "burger-main"}
        }}

    def test_scrapes_both_colors_but_never_stopped_tasks(self):
        result = discovery.targets(self.config, ECS())
        apps = [entry for entry in result if entry["labels"]["role"] == "backend"]
        self.assertEqual([entry["targets"] for entry in apps], [["10.0.0.1:8081"], ["10.0.0.2:8081"]])
        self.assertTrue(all(entry["labels"]["project"] == "burger" for entry in result))
        self.assertTrue(all(entry["labels"]["env"] == "main" for entry in result))
        self.assertEqual(len(result), 6)

    def test_partial_discovery_failure_is_not_published(self):
        with self.assertRaises(RuntimeError):
            discovery.targets(self.config, ECS(failures=True))


if __name__ == "__main__":
    unittest.main()
