import http from 'k6/http';
import { check } from 'k6';
const config = JSON.parse(open('./loadtest-config.json'));
export const options = {
  scenarios: { burger: {
    executor: 'constant-arrival-rate', rate: config.rps, timeUnit: '1s',
    duration: config.duration, preAllocatedVUs: 50, maxVUs: config.maxVUs,
  } },
  thresholds: { http_req_failed: ['rate<0.01'], dropped_iterations: ['count==0'] },
  tags: { project: 'burger', env: config.env, testid: config.testid },
};
export default function () {
  const result = http.get(config.baseUrl + config.path, { tags: { name: 'burger-endpoint' } });
  check(result, { 'HTTP 200': (response) => response.status === 200 });
}
