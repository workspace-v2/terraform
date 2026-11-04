#!/usr/bin/env python3
"""Refresh file_sd atomically; both blue and green tasks are included during deployments."""
import json
import os
from pathlib import Path

import boto3


def targets(config, ecs):
    result = []
    for env, values in config["environments"].items():
        for ip_key, port, job, role in [
            ("database_ip", 9100, "node", "database"),
            ("redis_ip", 9100, "node", "redis"),
            ("database_ip", 9104, "mysql", "database"),
            ("redis_ip", 9121, "redis", "redis"),
        ]:
            result.append({"targets": [f"{values[ip_key]}:{port}"], "labels": {
                "project": "burger", "env": env, "role": role, "job": job,
                "instance": f"burger-{env}-{role}", "__metrics_path__": "/metrics",
            }})
        arns = []
        for page in ecs.get_paginator("list_tasks").paginate(
            cluster=config["cluster"], serviceName=values["service"], desiredStatus="RUNNING"
        ):
            arns.extend(page["taskArns"])
        for offset in range(0, len(arns), 100):
            response = ecs.describe_tasks(cluster=config["cluster"], tasks=arns[offset:offset + 100])
            if response.get("failures"):
                raise RuntimeError("ECS task discovery incomplete; preserving previous targets")
            for task in response["tasks"]:
                if task["lastStatus"] != "RUNNING":
                    continue
                for attachment in task.get("attachments", []):
                    for detail in attachment.get("details", []):
                        if detail["name"] == "privateIPv4Address":
                            ip = detail["value"]
                            result.append({"targets": [f"{ip}:8081"], "labels": {
                                "project": "burger", "env": env, "role": "backend",
                                "platform": "ecs", "job": "spring-actuator",
                                "instance": f"burger-{env}-{ip}",
                                "__metrics_path__": "/actuator/prometheus",
                            }})
    return result


if __name__ == "__main__":
    config = json.loads(Path("/etc/burger-monitoring.json").read_text())
    ecs = boto3.client("ecs", region_name=config["region"])
    output = Path("/opt/monitoring/prometheus/burger-targets.json")
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps(targets(config, ecs)))
    temporary.chmod(0o644)
    os.replace(temporary, output)
