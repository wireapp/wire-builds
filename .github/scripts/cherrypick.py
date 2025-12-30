#!/usr/bin/env python3

import sys
import json
import subprocess

def get_build(commit):
    result = subprocess.run(
        ['git', 'show', f'{commit}:build.json'],
        capture_output=True,
        text=True
    )
    
    if result.returncode != 0:
        raise Exception(f"Failed to get build.json at commit {commit}: {result.stderr}")
    
    build_data = json.loads(result.stdout)
    return build_data

def main():
    target_commit = sys.argv[1]
    source_commit = sys.argv[2]
    chart_list = sys.argv[3]
    charts = chart_list.split(',')
    
    build_json_target = get_build(target_commit)
    build_json_source = get_build(source_commit)
    for chart in charts:
        build_json_target['helmCharts'][chart] = build_json_source['helmCharts'][chart]

    print(json.dumps(build_json_target))


if __name__ == '__main__':
    main()
