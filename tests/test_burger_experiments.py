import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

comparison=module('burger_compare','monitoring/burger/compare.py')
runner=module('burger_runner','scripts/burger-experiment.py')
metrics=module('burger_metrics','monitoring/burger/collect_metrics.py')

class RunnerTest(unittest.TestCase):
    def bundle(self,directory):
        target=Path(directory)/'bundle';target.mkdir()
        corpus=json.dumps({'queries':[{'id':'q1','keyword':'치즈','weight':1}]}).encode()
        import hashlib
        manifest={'schemaVersion':1,'generatorVersion':1,'profile':'10k','seed':10,'commentsPerReview':0,'idBase':1000000000,'catalogSourceType':'SYNTHETIC',
                  'datasetSha256':'a'*64,'workloadSha256':hashlib.sha256(corpus).hexdigest(),'counts':{'brands':100,'menus':3000,'users':1000,'reviews':10000,'comments':0}}
        (target/'manifest.json').write_text(json.dumps(manifest));(target/'workload.json').write_bytes(corpus)
        return target,manifest
    def config(self):return {'region':'ap-northeast-2','load_generator_id':'i-load','monitoring_ip':'10.0.0.1','environments':{'main':{'database_id':'i-db','redis_id':'i-redis','url':'https://example.invalid','service':'burger-main'}}}
    def test_generated_remote_scripts_parse_and_contain_safety_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle,manifest=self.bundle(directory)
            args=types.SimpleNamespace(env='main',bundle=bundle,rps=10,seconds=30,warmup=5,vus=5,max_vus=10,limit=10,endpoint='mixed',experiment='issue-1')
            with patch.object(runner,'submit',return_value='command') as submit,patch.object(runner,'receipt'),patch.object(runner,'verify_dataset'),patch.object(runner,'deployed_metadata',return_value={'resources':{}}):
                runner.seed(args,self.config());seed_script=submit.call_args.args[2]
                self.assertIn('collisions=',seed_script);self.assertIn('SELECT menu_id,rating',seed_script)
                self.assertNotIn('TRUNCATE',seed_script)
                self.assertEqual(subprocess.run(['bash','-n'],input=seed_script,text=True,capture_output=True).returncode,0)
                runner.load(args,self.config());load_script=submit.call_args.args[2]
                self.assertIn('flock -n /var/lock/burger-benchmark.lock',load_script)
                self.assertIn('collect-metrics.py',load_script)
                self.assertEqual(subprocess.run(['bash','-n'],input=load_script,text=True,capture_output=True).returncode,0)

    def test_bundle_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle,_=self.bundle(directory)
            (bundle/'workload.json').write_text('{}')
            with self.assertRaises(ValueError):runner.read_bundle(bundle)

    def test_fetch_reassembles_safe_remote_results_and_tails_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);remote=root/'remote';remote.mkdir()
            (remote/'summary.json').write_text('{"test":"summary"}')
            (remote/'output.log').write_text('\n'.join(str(i) for i in range(150)))
            receipt=root/'receipt.json'
            receipt.write_text(json.dumps({'runId':'search-main-test','instance':'i-load','command':'original','kind':'load'}))
            outputs={}
            def submit(config,instance,script,timeout=86400):
                result=subprocess.run(['bash','-c',script.replace('/opt/loadtest/burger/search-main-test',str(remote))],capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                command=str(len(outputs));outputs[command]=result.stdout;return command
            args=types.SimpleNamespace(receipt=receipt,output=root/'result')
            with patch.object(runner,'submit',side_effect=submit),patch.object(runner,'wait',side_effect=lambda config,instance,command:outputs[command]),patch.object(runner,'aws',return_value={'Status':'Success'}):
                runner.fetch(args,self.config())
            self.assertEqual(json.loads((args.output/'summary.json').read_text()),{'test':'summary'})
            self.assertEqual(len((args.output/'output.log').read_text().splitlines()),100)

class ComparisonTest(unittest.TestCase):
    def value(self,env):
        return {'config':dict({key:'same' for key in comparison.MATCH},env=env,testid=env),
                'measurement':{'thresholdsPassed':True,'latency':{'p(95)':100,'p(99)':200},'completedRps':10,'errorRate':0}}
    def test_only_matching_successful_experiments_are_compared(self):
        main,dev=self.value('main'),self.value('dev')
        self.assertEqual(comparison.compare(main,dev)['results']['p95Ms']['changePercent'],0)
        dev['config']['datasetSha256']='different'
        with self.assertRaises(ValueError):comparison.compare(main,dev)
        dev=self.value('dev');dev['measurement']['thresholdsPassed']=False
        with self.assertRaises(ValueError):comparison.compare(main,dev)

class MonitoringTest(unittest.TestCase):
    def test_missing_data_stays_missing(self):
        report=metrics.collect('http://example.invalid','dev',1,10,fetch=lambda url:{'status':'success','data':{'result':[]}})
        self.assertTrue(all(v['status']=='no-data' for v in report['metrics'].values()))

if __name__=='__main__':unittest.main()
