import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from './App.jsx'
import { api, ApiError } from './api.js'
import { toLocalInput } from './dates.js'

function mockFetch(routes) {
  return vi.fn(async (url, opts = {}) => {
    const key = `${opts.method || 'GET'} ${url.split('?')[0]}`
    const handler = routes[key]
    if (!handler) return new Response(JSON.stringify({ detail: 'not found' }), { status: 404 })
    const [status, body] = handler(opts)
    return new Response(body === null ? null : JSON.stringify(body), { status })
  })
}

afterEach(() => {
  cleanup()
  sessionStorage.clear()
  vi.restoreAllMocks()
})

describe('authentification', () => {
  it('affiche le formulaire de connexion sans jeton', () => {
    render(<App />)
    expect(screen.getByRole('button', { name: 'Se connecter' })).toBeInTheDocument()
  })

  it('se connecte puis affiche les ressources', async () => {
    globalThis.fetch = mockFetch({
      'POST /api/v1/auth/login': () => [200, { access_token: 'tok', token_type: 'bearer', expires_in: 1800 }],
      'GET /api/v1/auth/me': () => [200, { id: 1, email: 'a@b.fr', full_name: 'Alice', role: 'user' }],
      'GET /api/v1/resources': () => [200, [{ id: 1, name: 'Salle Confluence', type: 'room', location: 'A',
        capacity: 12, description: '', is_active: true, has_image: false, has_thumbnail: false }]],
    })
    render(<App />)
    fireEvent.change(screen.getByLabelText('E-mail'), { target: { value: 'a@b.fr' } })
    fireEvent.change(screen.getByLabelText('Mot de passe'), { target: { value: 'secret-long' } })
    fireEvent.click(screen.getByRole('button', { name: 'Se connecter' }))
    await waitFor(() => expect(screen.getByText('Salle Confluence')).toBeInTheDocument())
    expect(screen.queryByText('Administration')).not.toBeInTheDocument()
    expect(sessionStorage.getItem('resaflow.token')).toBe('tok')
  })

  it("affiche l'erreur renvoyée par l'API", async () => {
    globalThis.fetch = mockFetch({
      'POST /api/v1/auth/login': () => [401, { detail: 'Identifiants invalides' }],
    })
    render(<App />)
    fireEvent.change(screen.getByLabelText('E-mail'), { target: { value: 'a@b.fr' } })
    fireEvent.change(screen.getByLabelText('Mot de passe'), { target: { value: 'x' } })
    fireEvent.click(screen.getByRole('button', { name: 'Se connecter' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Identifiants invalides')
  })
})

describe('client API', () => {
  it('formate les erreurs de validation FastAPI', async () => {
    globalThis.fetch = mockFetch({
      'POST /api/v1/reservations': () => [422, { detail: [{ msg: 'Value error, end_at doit être postérieur à start_at' }] }],
    })
    await expect(api('/reservations', { method: 'POST', body: {} })).rejects.toEqual(
      new ApiError(422, 'end_at doit être postérieur à start_at'),
    )
  })

  it('produit une valeur compatible datetime-local', () => {
    expect(toLocalInput(new Date(2030, 0, 5, 9, 7))).toBe('2030-01-05T09:07')
  })
})
