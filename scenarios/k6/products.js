// Browse the catalog: public endpoint, served from the Valkey cache after the first hit.
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 10 },
    { duration: '2m', target: 20 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'], // < 5% errors
    http_req_duration: ['p(95)<1000'], // laptop numbers, not an SLO
  },
};

export default function () {
  const res = http.get(`http://${__ENV.HOST}/api/products`);
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(0.2);
}
