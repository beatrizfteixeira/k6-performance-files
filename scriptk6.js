import http from 'k6/http';
import { Trend } from 'k6/metrics';
import { sleep } from 'k6';

const latencyTrend = new Trend('latencia');

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const ENDPOINT = __ENV.ENDPOINT || '/api/cpu';

const VUS = parseInt(__ENV.VUS || '20');
const WARMUP_DURATION = __ENV.WARMUP_DURATION || '60s';
const STEADY_DURATION = __ENV.STEADY_DURATION || '40s';
const WARMUP_VUS = parseInt(__ENV.WARMUP_VUS || '70');

const warmupSeconds = parseInt(WARMUP_DURATION);

export const options = {
  scenarios: {
    warmup: {
      executor: 'constant-vus',
      vus: WARMUP_VUS,
      duration: WARMUP_DURATION,
      startTime: '0s',
      exec: 'runWarmup',
      tags: { phase: 'warmup' },
    },
    steady: {
      executor: 'constant-vus',
      vus: VUS,
      duration: STEADY_DURATION,
      startTime: `${warmupSeconds}s`,
      exec: 'runTest',
      tags: { phase: 'steady', vus: `${VUS}` },
    },
  },
};

export function runWarmup() {
  http.get(`${BASE_URL}${ENDPOINT}`);
  sleep(0.1);
}

export function runTest() {
  const res = http.get(`${BASE_URL}${ENDPOINT}`);
  latencyTrend.add(res.timings.duration);
  sleep(0.1);
}
