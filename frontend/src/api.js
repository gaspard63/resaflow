// Client HTTP minimal. Le jeton est gardé en sessionStorage (effacé à la fermeture de l'onglet).
const BASE = '/api/v1'
const TOKEN_KEY = 'resaflow.token'

export const auth = {
  get token() {
    try { return sessionStorage.getItem(TOKEN_KEY) } catch { return null }
  },
  set(token) {
    try { token ? sessionStorage.setItem(TOKEN_KEY, token) : sessionStorage.removeItem(TOKEN_KEY) } catch { /* ignore */ }
  },
}

export class ApiError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

function errorMessage(body, status) {
  if (!body) return `Erreur ${status}`
  if (typeof body.detail === 'string') return body.detail
  if (Array.isArray(body.detail)) return body.detail.map((d) => d.msg.replace(/^Value error, /, '')).join(' · ')
  return `Erreur ${status}`
}

export async function api(path, { method = 'GET', body, form, raw } = {}) {
  const headers = {}
  if (auth.token) headers.Authorization = `Bearer ${auth.token}`
  let payload
  if (form) payload = form
  else if (body !== undefined) {
    headers['Content-Type'] = 'application/json'
    payload = JSON.stringify(body)
  }
  const res = await fetch(BASE + path, { method, headers, body: payload })
  if (res.status === 401 && auth.token) {
    auth.set(null)
    window.dispatchEvent(new Event('resaflow:logout'))
  }
  if (!res.ok) {
    const data = await res.json().catch(() => null)
    throw new ApiError(res.status, errorMessage(data, res.status))
  }
  if (raw) return res.blob()
  if (res.status === 204) return null
  return res.json()
}

export async function downloadFile(path, filename) {
  const blob = await api(path, { raw: true })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
