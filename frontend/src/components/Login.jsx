import { useState } from 'react'
import { api, auth } from '../api.js'

export default function Login({ onLogged }) {
  const [mode, setMode] = useState('login')
  const [form, setForm] = useState({ email: '', password: '', full_name: '' })
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const update = (k) => (e) => setForm({ ...form, [k]: e.target.value })

  const submit = async (e) => {
    e.preventDefault()
    setError('')
    setBusy(true)
    try {
      if (mode === 'register') {
        await api('/auth/register', { method: 'POST', body: form })
      }
      const { access_token } = await api('/auth/login', {
        method: 'POST',
        body: { email: form.email, password: form.password },
      })
      auth.set(access_token)
      onLogged()
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="center">
      <form className="card login" onSubmit={submit}>
        <h1><img src="/favicon.svg" alt="" width="32" height="32" /> ResaFlow</h1>
        <p className="muted">Réservez salles et matériel en quelques clics.</p>
        {mode === 'register' && (
          <label>Nom complet
            <input value={form.full_name} onChange={update('full_name')} required minLength={2} />
          </label>
        )}
        <label>E-mail
          <input type="email" value={form.email} onChange={update('email')} required autoComplete="username" />
        </label>
        <label>Mot de passe
          <input type="password" value={form.password} onChange={update('password')} required
            minLength={mode === 'register' ? 10 : undefined}
            autoComplete={mode === 'register' ? 'new-password' : 'current-password'} />
        </label>
        {error && <p className="error" role="alert">{error}</p>}
        <button className="primary" disabled={busy}>{mode === 'login' ? 'Se connecter' : 'Créer mon compte'}</button>
        <button type="button" className="link" onClick={() => setMode(mode === 'login' ? 'register' : 'login')}>
          {mode === 'login' ? 'Pas de compte ? Inscription' : 'Déjà inscrit ? Connexion'}
        </button>
      </form>
    </div>
  )
}
