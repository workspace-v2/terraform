import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('indexer', Path(__file__).resolve().parents[1] / 'burger-search-index.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class FakeElastic:
    def __init__(self, fail_bulk=False, fail_count=False):
        self.calls = []
        self.counts = {}
        self.fail_bulk = fail_bulk
        self.fail_count = fail_count
    def request(self, method, path, body=None, **kwargs):
        self.calls.append((method, path, copy.deepcopy(body)))
        if path == '/_bulk':
            lines = body.splitlines()
            items = []
            for pos in range(0, len(lines), 2):
                index = json.loads(lines[pos])['create']['_index']
                self.counts[index] = self.counts.get(index, 0) + 1
                items.append({'create': {'status': 400 if self.fail_bulk else 201}})
            return {'errors': self.fail_bulk, 'items': items}
        if path.endswith('/_count'):
            return {'count': self.counts.get(path.split('/')[1], 0) + int(self.fail_count)}
        if path.startswith('/_cluster/health/'):
            return {'status': 'green', 'timed_out': False}
        if path.startswith('/_alias/'):
            return {'burger-test-old-' + path.rsplit('-', 1)[1]: {'aliases': {}}}
        return {'acknowledged': True}


def rows():
    return [
        {'kind': 'menus', 'document': {'id': 1, 'name': '버거', 'response': {'id': 1}}},
        {'kind': 'reviews', 'document': {'id': 10, 'tags': ['CHEESY', 'SPICY'], 'response': {'id': 10}}},
        {'kind': 'reviews', 'document': {'id': 11, 'tags': [], 'response': {'id': 11}}},
    ]

class IndexTests(unittest.TestCase):
    def test_counts_bulk_batches_and_atomic_alias_switch(self):
        client = FakeElastic()
        result = m.reindex(client, iter(rows()), 'burger-test', 'new', 2)
        self.assertEqual(result['counts'], {'menus': 1, 'reviews': 2})
        self.assertEqual(len(result['documents_sha256']), 64)
        self.assertEqual(sum(path == '/_bulk' for _, path, _ in client.calls), 2)
        calls = [body for _, path, body in client.calls if path == '/_aliases']
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(calls[0]['actions']), 4)
        self.assertEqual(client.calls[-1][1], '/_aliases')
        for _, path, body in client.calls:
            if path.endswith('/_settings'):
                self.assertTrue(body['index']['blocks.write'])

    def test_bulk_item_failure_does_not_publish(self):
        client = FakeElastic(fail_bulk=True)
        with self.assertRaises(RuntimeError):
            m.reindex(client, iter(rows()), 'burger-test', 'new', 2)
        self.assertFalse(any(path == '/_aliases' for _, path, _ in client.calls))

    def test_count_mismatch_does_not_publish(self):
        client = FakeElastic(fail_count=True)
        with self.assertRaises(RuntimeError):
            m.reindex(client, iter(rows()), 'burger-test', 'new', 2)
        self.assertFalse(any(path == '/_aliases' for _, path, _ in client.calls))

    def test_source_failure_does_not_publish(self):
        def broken():
            yield rows()[0]
            raise RuntimeError('mysql export failed')
        client = FakeElastic()
        with self.assertRaises(RuntimeError):
            m.reindex(client, broken(), 'burger-test', 'new', 1)
        self.assertFalse(any(path == '/_aliases' for _, path, _ in client.calls))

    def test_empty_corpus_does_not_replace_alias(self):
        client = FakeElastic()
        with self.assertRaises(RuntimeError):
            m.reindex(client, iter([]), 'burger-test', 'new', 500)
        self.assertFalse(any(path == '/_aliases' for _, path, _ in client.calls))

    def test_tags_and_digest_are_deterministic(self):
        first = m.reindex(FakeElastic(), iter(rows()), 'burger-test', 'first', 2)
        other = rows(); other[1]['document']['tags'].reverse()
        second = m.reindex(FakeElastic(), iter(other), 'burger-test', 'second', 3)
        self.assertEqual(first['documents_sha256'], second['documents_sha256'])
        _, review = m.prepare_document(rows()[1])
        self.assertEqual(review['response']['tags'], ['CHEESY', 'SPICY'])
        self.assertEqual(review['tagLabels'], ['치즈', '매콤'])

    def test_mapping_matches_existing_pagination_and_has_no_replica(self):
        for kind in ('menus', 'reviews'):
            definition = m.index_definition(kind)
            self.assertEqual(definition['settings']['max_result_window'], 10101)
            self.assertEqual(definition['settings']['number_of_replicas'], 0)
            self.assertFalse(definition['mappings']['properties']['response']['enabled'])

if __name__ == '__main__':
    unittest.main()
