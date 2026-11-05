import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

dataset=module('burger_dataset','monitoring/burger/dataset.py')

class DatasetTest(unittest.TestCase):
    def test_seed_is_repeatable_and_scale_keeps_review_prefix(self):
        a,menus=dataset.catalog(10,1000000000)
        self.assertEqual(len(a),100);self.assertEqual(len(menus),3000)
        self.assertEqual(dataset.catalog(10,1000000000),(a,menus))
        for i in range(1,200):
            review=dataset.review(10,i,menus,1000000000)
            self.assertEqual(review,dataset.review(10,i,menus,1000000000))
            self.assertLessEqual(len(review['title']),26)
            self.assertTrue(1<=review['rating']<=5)
        self.assertNotEqual(dataset.review(10,1,menus,1000000000),dataset.review(11,1,menus,1000000000))
        self.assertGreater(len({dataset.review(10,i,menus,1000000000)['content'] for i in range(1,1000)}),950)

    def test_manifest_hashes_and_unjudged_templates(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'bundle'
            with patch.dict(dataset.PROFILES,{'tiny':20}):
                manifest=dataset.generate(path,'tiny',10,2)
            self.assertEqual(manifest['counts']['comments'],40)
            template=json.loads((path/'judgments-template.json').read_text())
            self.assertEqual(len(template['queries']),100)
            self.assertTrue(all(not q['judged'] and not q['grades'] for q in template['queries']))
            self.assertEqual(len({(q['target'],q['keyword']) for q in template['queries']}),100)
            with self.assertRaises(ValueError):dataset.generate(path,'10k')
            sql=(path/'dataset.sql').read_text()
            self.assertNotIn('DELETE ',sql);self.assertNotIn('TRUNCATE ',sql)
            self.assertIn('post_tag',sql)

    def test_real_menu_requires_provenance_and_preserves_unknown_price(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'menus.csv'
            path.write_text('brand,name,description,price,source_url\n브랜드,메뉴,설명,,https://example.com/menu\n')
            _,menus=dataset.catalog(1,1000000000,path)
            self.assertEqual(menus[0]['source_type'],'REAL');self.assertIsNone(menus[0]['price'])
            path.write_text('brand,name,description,price,source_url\n브랜드,메뉴,설명,,\n')
            with self.assertRaises(ValueError):dataset.catalog(1,1000000000,path)


if __name__=='__main__':unittest.main()
