#!/usr/bin/env python3
"""MySQL snapshot -> versioned Elasticsearch indices -> atomic alias switch.

Run on a host with mysql CLI and network access to MySQL/Elasticsearch.
Credentials are read from protected files; no credentials or document bodies are logged.
No live synchronization: stop writes (including view-count changes) for benchmark parity.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

TAGS = {"SPICY": "매콤", "THICK_PATTY": "두꺼운 패티", "GOOD_VALUE": "가성비",
        "CHEESY": "치즈", "JUICY": "육즙", "CRISPY": "바삭", "HANDMADE": "수제버거"}

MENU_SQL = """SELECT JSON_OBJECT('kind','menus','document',JSON_OBJECT(
'id',m.menu_id,'brandId',b.brand_id,'brandName',b.name,'name',m.name,
'description',m.description,'price',m.price,
'response',JSON_OBJECT('id',m.menu_id,'brandId',b.brand_id,'brandName',b.name,
'name',m.name,'description',m.description,'price',m.price,
'sourceType',m.source_type,'sourceUrl',m.source_url)))
FROM menu m JOIN brand b ON b.brand_id=m.brand_id
WHERE m.deleted_at IS NULL AND b.deleted_at IS NULL ORDER BY m.menu_id;"""
# Reviews match the existing inner joins: legacy posts without a menu are excluded;
# a soft-deleted menu/brand does not hide an otherwise active review in the MySQL path.
REVIEW_SQL = """SELECT JSON_OBJECT('kind','reviews','document',JSON_OBJECT(
'id',p.post_id,'menuId',m.menu_id,'menuName',m.name,'brandName',b.name,
'title',p.title,'content',p.content,
'response',JSON_OBJECT('id',p.post_id,'menuId',m.menu_id,'menuName',m.name,
'brandName',b.name,'rating',p.rating,'title',p.title,
'createdAt',DATE_FORMAT(p.created_at,'%Y-%m-%d %H:%i:%s'),
'likeCount',p.like_count,'commentCount',p.comment_count,'viewCount',p.view_count,
'author',JSON_OBJECT('userId',u.user_id,'nickname',u.nickname,'profileImageUrl',u.profile_image_url)),
 'tags',COALESCE((SELECT JSON_ARRAYAGG(t.tag) FROM post_tag t WHERE t.post_id=p.post_id),JSON_ARRAY())))
FROM post p JOIN users u ON u.user_id=p.user_id JOIN menu m ON m.menu_id=p.menu_id
JOIN brand b ON b.brand_id=m.brand_id WHERE p.deleted_at IS NULL ORDER BY p.post_id;"""


def protected_file(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_mode & 0o077:
        raise ValueError('Credential file must exist and have permissions 400 or 600')
    return path


def index_definition(kind):
    fields = {'id': {'type': 'long'}, 'response': {'type': 'object', 'enabled': False}}
    names = ('name', 'description', 'brandName') if kind == 'menus' else ('title', 'content', 'menuName', 'brandName', 'tagLabels')
    fields.update({name: {'type': 'text', 'analyzer': 'standard'} for name in names})
    if kind == 'menus':
        fields.update({'brandId': {'type': 'long'}, 'price': {'type': 'integer'}})
    else:
        fields.update({'menuId': {'type': 'long'}, 'tags': {'type': 'keyword'}})
    # Existing offset max 10000 + max page 100 + hasNext lookahead 1.
    return {'settings': {'number_of_shards': 1, 'number_of_replicas': 0,
                         'max_result_window': 10101, 'refresh_interval': '-1'},
            'mappings': {'dynamic': 'strict', 'properties': fields}}


class Elastic:
    def __init__(self, url, username, password):
        from urllib.parse import urlsplit
        parsed = urlsplit(url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.query or parsed.fragment:
            raise ValueError('Invalid Elasticsearch URL')
        self.url = url.rstrip('/')
        self.auth = 'Basic ' + base64.b64encode((username + ':' + password).encode()).decode()

    def request(self, method, path, body=None, ndjson=False, missing_ok=False):
        data = body.encode() if ndjson else None if body is None else json.dumps(body, ensure_ascii=False).encode()
        req = urllib.request.Request(self.url + path, data=data, method=method,
            headers={'Authorization': self.auth, 'Content-Type': 'application/x-ndjson' if ndjson else 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return {}
            # Never print Elasticsearch responses containing document contents.
            raise RuntimeError('Elasticsearch HTTP ' + str(error.code) + ' at ' + path) from None


def prepare_document(row):
    kind, document = row['kind'], row['document']
    if kind not in ('menus', 'reviews'):
        raise ValueError('Unexpected document kind')
    if kind == 'reviews':
        tags = sorted(document['tags'])
        document['tags'] = tags
        document['tagLabels'] = [TAGS[tag] for tag in tags]
        document['response']['tags'] = tags
    return kind, document


def bulk(client, rows, indices):
    lines = []
    for kind, document in rows:
        lines.extend([json.dumps({'create': {'_index': indices[kind], '_id': str(document['id'])}}),
                      json.dumps(document, ensure_ascii=False, sort_keys=True)])
    result = client.request('POST', '/_bulk', '\n'.join(lines) + '\n', ndjson=True)
    items = result.get('items', [])
    if result.get('errors') or len(items) != len(rows) or any(next(iter(item.values()))['status'] != 201 for item in items):
        raise RuntimeError('Bulk item failure; aliases were not switched')


def publish(client, indices, prefix, counts):
    for kind, index in indices.items():
        client.request('PUT', '/' + index + '/_settings', {'index': {'refresh_interval': '1s', 'blocks.write': True}})
        client.request('POST', '/' + index + '/_refresh')
        health = client.request('GET', '/_cluster/health/' + index + '?wait_for_status=green&timeout=30s')
        if health.get('timed_out') or health.get('status') != 'green':
            raise RuntimeError('Index not healthy; aliases were not switched')
        actual = client.request('GET', '/' + index + '/_count')['count']
        if actual != counts[kind]:
            raise RuntimeError('Index count mismatch; aliases were not switched')
    actions = []
    for kind, index in indices.items():
        alias = prefix + '-' + kind
        previous = client.request('GET', '/_alias/' + alias, missing_ok=True)
        actions.extend({'remove': {'index': old, 'alias': alias, 'must_exist': True}} for old in previous)
        actions.append({'add': {'index': index, 'alias': alias}})
    result = client.request('POST', '/_aliases', {'actions': actions})
    if result.get('errors') or not result.get('acknowledged'):
        raise RuntimeError('Alias acknowledgement failed; inspect aliases before retrying')


def reindex(client, rows, prefix, run_id, batch_size):
    indices = {kind: prefix + '-' + kind + '-' + run_id for kind in ('menus', 'reviews')}
    # Existing index names are never overwritten. Failed builds remain for diagnosis.
    for kind, index in indices.items():
        client.request('PUT', '/' + index, index_definition(kind))
    counts = dict.fromkeys(indices, 0)
    digest = hashlib.sha256()
    batch, size = [], 0
    for row in rows:
        kind, document = prepare_document(row)
        encoded = json.dumps(document, ensure_ascii=False, sort_keys=True).encode()
        digest.update(kind.encode() + b'\0' + encoded + b'\n')
        batch.append((kind, document)); size += len(encoded); counts[kind] += 1
        if len(batch) >= batch_size or size >= 5 * 1024 * 1024:
            bulk(client, batch, indices); batch, size = [], 0
    if batch:
        bulk(client, batch, indices)
    # An empty corpus usually signals a wrong DB; do not replace a working alias.
    if not all(counts.values()):
        raise RuntimeError('Empty menu/review corpus; aliases were not switched')
    publish(client, indices, prefix, counts)
    return {'indices': indices, 'counts': counts, 'documents_sha256': digest.hexdigest(),
            'analyzer': 'standard', 'shards': 1, 'replicas': 0, 'snapshot_only': True}


def snapshot_rows(defaults_file, database):
    # Single mysql process/connection: both SELECTs share a consistent read-only snapshot.
    # stderr goes to a protected file, never to a CI log (mysql can echo failing SQL).
    import tempfile
    sql = 'SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;\nSTART TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY;\n' + MENU_SQL + '\n' + REVIEW_SQL + '\nCOMMIT;\n'
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(['mysql', '--defaults-extra-file=' + str(defaults_file),
            '--default-character-set=utf8mb4', '--quick', '--batch', '--raw', '--skip-column-names', database],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            process.stdin.write(sql); process.stdin.close()
            for line in process.stdout:
                yield json.loads(line)
            if process.wait() != 0:
                raise RuntimeError('MySQL snapshot export failed; aliases were not switched')
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait()
            process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mysql-defaults-file', required=True, type=protected_file)
    parser.add_argument('--database', required=True)
    parser.add_argument('--url', required=True)
    parser.add_argument('--username', default='elastic')
    parser.add_argument('--password-file', required=True, type=protected_file)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--run-id', default=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d%H%M%S'))
    parser.add_argument('--batch-size', type=int, default=500)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--quiescent-source-confirmed', action='store_true', help='confirm writes and benchmark traffic are stopped')
    args = parser.parse_args()
    if not args.quiescent_source_confirmed:
        parser.error('Stop source writes and benchmark traffic, then pass --quiescent-source-confirmed')
    if not re.fullmatch(r'burger-[a-z0-9-]+', args.prefix) or not re.fullmatch(r'[a-z0-9-]+', args.run_id):
        parser.error('Invalid index prefix/run ID')
    if not re.fullmatch(r'[A-Za-z0-9_]+', args.database) or not 1 <= args.batch_size <= 2000:
        parser.error('Invalid database/batch size')
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    # Check receipt path before modifying indices/aliases; never overwrite old evidence.
    with args.receipt.open('x') as receipt:
        os.chmod(args.receipt, 0o600)
        metadata = {'source_database': args.database, 'prefix': args.prefix, 'run_id': args.run_id,
                    'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        def record(state, **extra):
            receipt.seek(0); receipt.truncate()
            json.dump(dict(metadata, state=state, **extra), receipt, ensure_ascii=False, indent=2)
            receipt.flush(); os.fsync(receipt.fileno())
        record('building')
        try:
            client = Elastic(args.url, args.username, args.password_file.read_text().strip())
            result = reindex(client, snapshot_rows(args.mysql_defaults_file, args.database), args.prefix, args.run_id, args.batch_size)
            record('published', **result, finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        except BaseException as error:
            # Timeout may occur after the server applies an alias update. Inspect state; never assume rollback.
            record('failed_or_unknown', error_type=type(error).__name__, inspect_aliases_before_retry=True)
            raise
    print(json.dumps({'counts': result['counts'], 'receipt': str(args.receipt)}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, urllib.error.URLError) as error:
        print(type(error).__name__ + ': indexing failed; inspect local configuration and index state', file=sys.stderr)
        sys.exit(1)
