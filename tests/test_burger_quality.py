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

quality=module('burger_quality','monitoring/burger/quality.py')

class QualityTest(unittest.TestCase):
    def judgments(self,**changes):
        q={'id':'q1','target':'menus','keyword':'치즈','judged':True,'grades':{'1':3,'2':1},'expectedEmpty':False}
        q.update(changes)
        return {'schemaVersion':1,'datasetSha256':'a'*64,'queries':[q]}
    @staticmethod
    def fetch(ids):return lambda path:{'code':None,'data':{'content':[{'id':i} for i in ids]}}

    def test_known_ranking_scores_and_fixed_precision_denominator(self):
        perfect=quality.score(['1','2'],{'1':3,'2':1})
        self.assertEqual(perfect['precisionAt10'],.2);self.assertAlmostEqual(perfect['ndcgAt10'],1)
        self.assertLess(quality.score(['2','1'],{'1':3,'2':1})['ndcgAt10'],1)
        with self.assertRaises(ValueError):quality.score(['1','1'],{'1':3})

    def test_missing_judgments_or_unknown_results_never_produce_final_scores(self):
        value=quality.evaluate('http://example.invalid',self.judgments(judged=False),fetch=self.fetch([]))
        self.assertFalse(value['complete']);self.assertIsNone(value['aggregate'])
        value=quality.evaluate('http://example.invalid',self.judgments(),fetch=self.fetch(['1','99']))
        self.assertEqual(value['queries'][0]['status'],'needs-pool-judgment');self.assertIsNone(value['aggregate'])
        value=quality.evaluate('http://example.invalid',self.judgments(),True,fetch=self.fetch(['1','99']))
        self.assertIsNone(value['aggregate'])

    def test_empty_intent_is_evaluated_separately(self):
        result=quality.evaluate('http://example.invalid',self.judgments(expectedEmpty=True,grades={}),fetch=self.fetch([]))
        self.assertTrue(result['complete']);self.assertEqual(result['aggregate']['emptyAccuracy'],1)
        self.assertIsNone(result['aggregate']['precisionAt10'])


if __name__=='__main__':unittest.main()
