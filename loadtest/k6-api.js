// Test de charge de l'API ResaFlow.
// - pipeline (staging) : 10 utilisateurs virtuels pendant 1 min, vérifie le SLO de latence
// - démonstration HPA  : k6 run -e BASE_URL=https://... -e VUS=80 -e DURATION=10m loadtest/k6-api.js
import http from 'k6/http'
import { check, sleep } from 'k6'

const BASE = __ENV.BASE_URL
const VUS = Number(__ENV.VUS || 20)
const DURATION = __ENV.DURATION || '3m'

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      stages: [
        { duration: '30s', target: VUS },
        { duration: DURATION, target: VUS },
        { duration: '30s', target: 0 },
      ],
    },
  },
  // Seuils alignés sur les SLO : le test échoue s'ils ne sont pas tenus
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{kind:read}': ['p(95)<300'],
    checks: ['rate>0.99'],
  },
}

export function setup() {
  const email = `k6-${Date.now()}@example.com`
  const password = `k6-${Math.random().toString(36).slice(2)}-password`
  const params = { headers: { 'Content-Type': 'application/json' } }
  http.post(`${BASE}/api/v1/auth/register`, JSON.stringify({ email, full_name: 'Load Test', password }), params)
  const res = http.post(`${BASE}/api/v1/auth/login`, JSON.stringify({ email, password }), params)
  check(res, { 'login ok': (r) => r.status === 200 })
  return { token: res.json('access_token') }
}

export default function (data) {
  const params = { headers: { Authorization: `Bearer ${data.token}` }, tags: { kind: 'read' } }
  const list = http.get(`${BASE}/api/v1/resources`, params)
  check(list, { 'ressources 200': (r) => r.status === 200 })
  const resources = list.status === 200 ? list.json() : []
  if (resources.length) {
    const id = resources[Math.floor(Math.random() * resources.length)].id
    const now = new Date()
    const end = new Date(now.getTime() + 7 * 86400000)
    const slots = http.get(`${BASE}/api/v1/resources/${id}/slots?start=${now.toISOString()}&end=${end.toISOString()}`, params)
    check(slots, { 'créneaux 200': (r) => r.status === 200 })
  }
  const mine = http.get(`${BASE}/api/v1/reservations`, params)
  check(mine, { 'réservations 200': (r) => r.status === 200 })
  sleep(1)
}
