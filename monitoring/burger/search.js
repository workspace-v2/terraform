import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Trend, Rate, Counter, Gauge } from 'k6/metrics';
import { SharedArray } from 'k6/data';

const config = JSON.parse(open(__ENV.BURGER_CONFIG || './search-config.json'));
const queries = new SharedArray('burger-search-queries', () => JSON.parse(open(__ENV.BURGER_WORKLOAD || './workload.json')).queries);
const duration = new Trend('search_duration_ms', true);
const errors = new Rate('search_error_rate');
const requests = new Counter('search_requests');
const empty = new Rate('search_empty_rate');
const windowStart = new Gauge('search_window_start_ms');
if (!['main','dev','local'].includes(config.env) || !['mixed','menus','reviews','combined'].includes(config.endpoint)) throw new Error('Invalid environment or endpoint');
if (!Number.isInteger(config.rps) || config.rps < 1 || !Number.isInteger(config.seconds) || config.seconds < 1 || config.warmupSeconds < 0) throw new Error('Invalid rate/duration');
if (!queries.length || queries.some(q => !q.keyword || !Number.isInteger(q.weight) || q.weight < 1)) throw new Error('Invalid workload');
const totalWeight = queries.reduce((a,q) => a+q.weight,0);
function scenario(seconds, phase, start) {
  return { executor:'constant-arrival-rate', rate:config.rps, timeUnit:'1s', duration:`${seconds}s`,
    startTime:`${start}s`, preAllocatedVUs:config.preAllocatedVUs, maxVUs:config.maxVUs,
    gracefulStop:'10s', tags:{phase} };
}
const scenarios = { measure:scenario(config.seconds,'measure',config.warmupSeconds > 0 ? config.warmupSeconds+10 : 0) };
if (config.warmupSeconds > 0) scenarios.warmup=scenario(config.warmupSeconds,'warmup',0);
export const options = {
  scenarios,
  summaryTrendStats:['avg','min','med','max','p(95)','p(99)'],
  thresholds: { search_error_rate:['rate<0.01'], dropped_iterations:['count==0'] },
  tags:{project:'burger',env:config.env,testid:config.testid,experiment:config.experiment,endpoint:config.endpoint},
};
function numberFor(index, salt) {
  let x=((config.seed >>> 0) ^ (index >>> 0) ^ salt) >>> 0;
  x=Math.imul(x ^ (x >>> 16),0x45d9f3b);x=Math.imul(x ^ (x >>> 16),0x45d9f3b);
  return (x ^ (x >>> 16)) >>> 0;
}
export function requestFor(index) {
  let slot=numberFor(index,12345)%totalWeight;
  let query=queries[queries.length-1];
  for (const candidate of queries) {slot-=candidate.weight;if(slot<0){query=candidate;break;}}
  let endpoint=config.endpoint;
  if(endpoint==='mixed') endpoint=['combined','reviews','menus'][numberFor(index,67890)%3];
  const params={keyword:query.keyword,limit:String(config.limit),sort:query.sort||'relevance'};
  let path;
  if(endpoint==='combined'){path='/v1/search';params.menuOffset='0';params.reviewOffset='0';}
  if(endpoint==='reviews'){path='/v1/posts/search';params.offset='0';if(query.menuId)params.menuId=String(query.menuId);}
  if(endpoint==='menus'){path='/v1/menus';params.offset='0';if(query.brandId)params.brandId=String(query.brandId);}
  return {endpoint,path,query, url:config.baseUrl+path+'?'+Object.keys(params).map(k=>encodeURIComponent(k)+'='+encodeURIComponent(params[k])).join('&')};
}
export default function () {
  const request=requestFor(exec.scenario.iterationInTest);
  const response=http.get(request.url,{timeout:'10s',tags:{name:request.path,query_group:request.query.id}});
  let ok=false,isEmpty=false;
  try {
    const payload=response.json();
    const data=payload.data;
    ok=response.status===200 && payload.code===null && (request.endpoint==='combined' ? Array.isArray(data.menus.content)&&Array.isArray(data.reviews.content) : Array.isArray(data.content));
    if(ok) isEmpty=request.endpoint==='combined' ? data.menus.content.length+data.reviews.content.length===0 : data.content.length===0;
  } catch (_) {ok=false;}
  check(response,{'valid search response':()=>ok});
  if(exec.scenario.name==='measure') {
    windowStart.add(exec.scenario.startTime);
    duration.add(response.timings.duration);
    errors.add(!ok);requests.add(1);if(ok)empty.add(isEmpty);
  }
}
export function handleSummary(data) {
  const metrics=data.metrics;
  const result={schemaVersion:1,config,measurement:{
    windowStartEpochSeconds:metrics.search_window_start_ms ? metrics.search_window_start_ms.values.value/1000 : null,
    requests:metrics.search_requests ? metrics.search_requests.values.count : 0,
    completedRps:metrics.search_requests ? metrics.search_requests.values.count/config.seconds : 0,
    latency:metrics.search_duration_ms ? metrics.search_duration_ms.values : null,
    errorRate:metrics.search_error_rate ? metrics.search_error_rate.values.rate : null,
    emptyRate:metrics.search_empty_rate ? metrics.search_empty_rate.values.rate : null,
    droppedIterations:metrics.dropped_iterations ? metrics.dropped_iterations.values.count : 0,
    thresholdsPassed:Object.values(metrics).every(m=>!m.thresholds || Object.values(m.thresholds).every(t=>t.ok))
  },metrics};
  return {'summary.json':JSON.stringify(result,null,2),'stdout':JSON.stringify(result.measurement,null,2)+'\n'};
}
