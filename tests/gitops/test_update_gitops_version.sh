#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
# Local-only fixtures: requires Python 3 (standard library) and Mike Farah yq v4.44.3.
set -euo pipefail
[[ $(yq --version) == 'yq (https://github.com/mikefarah/yq/) version v4.44.3' ]]
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo/.github/workflows/update-gitops.yml" <<'PY'
import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def load(path):
    return json.loads(subprocess.check_output(['yq', '-o=json', '.', str(path)]))


job = load(sys.argv[1])['jobs']['update-gitops']
# Execute only the three inline yq commands, never checkout/diff/commit/push steps.
steps = [s for s in job['steps'] if 'cmd' in s.get('with', {})]
assert len(steps) == 3
assert all(s['uses'] == 'docker://mikefarah/yq:4.44.3-githubaction' for s in steps)
variables = {k: str(v) for k, v in job['env'].items() if '${{' not in str(v)}
prefix = 'ghcr.io/felixngwhuk/opentelemetry-devops-demo/'
meta, pod = variables['VERSION_LABEL_SELECTOR'], variables['POD_VERSION_LABEL_SELECTOR']
meta_path, pod_path = variables['VERSION_LABEL_PATH'], variables['POD_VERSION_LABEL_PATH']


def patch(selector, path, target=None):
    return {'target': target or {'labelSelector': selector}, 'patch': json.dumps([
        {'op': 'add', 'path': path, 'value': 'old'}])}


fixture = {
    'apiVersion': 'kustomize.config.k8s.io/v1beta1', 'kind': 'Kustomization',
    'resources': ['../../base'],
    'images': [{'name': prefix + 'checkout', 'newTag': 'old'},
               {'name': prefix + 'flagd-ui', 'newTag': 'old'},
               {'name': 'docker.io/library/postgres', 'newTag': '17'},
               {'name': prefix.rstrip('/') + '-other/checkout', 'newTag': 'keep'}],
    'patches': [patch(meta, meta_path), patch(pod, pod_path, {
        'group': 'apps', 'version': 'v1', 'kind': 'Deployment', 'labelSelector': pod}),
        {'path': 'resources.yaml'}],
}

with tempfile.TemporaryDirectory(prefix='inline-gitops-test-') as tmp:
    root = Path(tmp)
    file = root / 'gitops/fixture.yaml'
    file.parent.mkdir()
    # Any unexpected git invocation fails and leaves evidence, even if ignored.
    (root / 'bin').mkdir()
    git = root / 'bin/git'
    git.write_text('#!/bin/sh\ntouch "$GIT_CALLED"\nexit 99\n')
    git.chmod(0o755)
    env = dict(os.environ, **variables, KUSTOMIZATION_FILE='fixture.yaml',
               PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
               GIT_CALLED=str(root / 'git-called'))

    def run(environment='dev', tag='dev-abcdef0'):
        for step in steps:
            inputs = step['with']
            result = subprocess.run([inputs['entrypoint'], *shlex.split(inputs['args'])],
                                    cwd=root, env=dict(env, RELEASE_ENVIRONMENT=environment,
                                    IMAGE_TAG=tag, INPUT_CMD=inputs['cmd']),
                                    capture_output=True, text=True)
            if result.returncode:
                return result
        return result

    for environment, tag in [('dev', 'dev-abcdef0'), ('staging', '1.2.3-rc-abcdef0'),
                             ('prod', '1.2.3')]:
        file.write_text(json.dumps(fixture))
        result = run(environment, tag)
        assert result.returncode == 0, result.stderr
        expected = copy.deepcopy(fixture)
        for image in expected['images'][:2]:
            image['newTag'] = tag
        actual = load(file)
        for i in (0, 1):
            operations = json.loads(expected['patches'][i]['patch'])
            operations[0]['value'] = tag
            # Independently decode the inline patch YAML produced by yq.
            decoded = json.loads(subprocess.check_output(['yq', '-o=json', '.', '-'],
                                 input=actual['patches'][i]['patch'].encode()))
            assert decoded == operations
            expected['patches'][i]['patch'] = actual['patches'][i]['patch']
        assert actual == expected, 'unrelated images, fields or patch counts changed'
        before = file.read_bytes()
        assert run(environment, tag).returncode == 0
        assert file.read_bytes() == before, 'not idempotent'
        print(f'PASS: {environment}, release fields, preservation, idempotence')

    def reject(name, config=fixture, environment='dev', tag='dev-abcdef0'):
        file.write_text(config if isinstance(config, str) else json.dumps(config))
        before = file.read_bytes()
        assert run(environment, tag).returncode != 0, f'accepted {name}'
        assert file.read_bytes() == before, f'modified rejected input: {name}'
        print(f'PASS: rejects {name}, input unchanged')

    reject('unknown environment', environment='unknown')
    for tag in ['', 'latest', 'dev-abc', 'dev-ABCDEFG', 'dev-abcdef00',
                'dev-abcdef0\n', 'dev-abcdef0; echo unsafe', '1.2.3']:
        reject(f'invalid dev tag {tag!r}', tag=tag)
    reject('staging tag mismatch', environment='staging')
    reject('prod tag mismatch', environment='prod', tag='1.2.3-rc-abcdef0')
    reject('malformed YAML', 'images: [')
    reject('multiple YAML documents', json.dumps(fixture) + '\n---\nkind: Kustomization\n')
    for i in (0, 1):
        for mode in ('missing patch', 'duplicate patch', 'missing path', 'duplicate path', 'invalid operation'):
            config = copy.deepcopy(fixture)
            if mode == 'missing patch':
                del config['patches'][i]
            elif mode == 'duplicate patch':
                config['patches'].append(copy.deepcopy(config['patches'][i]))
            else:
                operations = json.loads(config['patches'][i]['patch'])
                if mode == 'missing path':
                    operations[0]['path'] = '/unrelated'
                elif mode == 'duplicate path':
                    operations.append(copy.deepcopy(operations[0]))
                else:
                    operations[0]['op'] = 'remove'
                config['patches'][i]['patch'] = json.dumps(operations)
            reject(f'{mode} ({i})', config)
    for field, value in [('group', 'wrong'), ('version', 'v2'), ('kind', 'StatefulSet'), ('name', 'checkout')]:
        config = copy.deepcopy(fixture)
        config['patches'][1]['target'][field] = value
        reject(f'invalid Pod target {field}', config)
    for mode in ('missing first-party images', 'duplicate image'):
        config = copy.deepcopy(fixture)
        if mode == 'duplicate image':
            config['images'].append(copy.deepcopy(config['images'][0]))
        else:
            config['images'] = config['images'][2:]
        reject(mode, config)
    assert not (root / 'git-called').exists(), 'unexpected git invocation'
print('PASS: all inline GitOps release fixtures; no git commands executed')
PY
