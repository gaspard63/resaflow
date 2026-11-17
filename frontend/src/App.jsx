import { useCallback, useEffect, useState } from 'react'
import { api, auth } from './api.js'
import Login from './components/Login.jsx'
import Resources from './components/Resources.jsx'
import Reservations from './components/Reservations.jsx'
import Exports from './components/Exports.jsx'
import Admin from './components/Admin.jsx'

const TABS = [
  { id: 'resources', label: 'Ressources' },
  { id: 'reservations', label: 'Mes réservations' },
  { id: 'exports', label: 'Exports PDF' },
  { id: 'admin', label: 'Administration', admin: true },
]

export default function App() {
  const [user, setUser] = useState(null)
  const [loading, setLoading] = useState(Boolean(auth.token))
  const [tab, setTab] = useState('resources')

  const loadMe = useCallback(async () => {
    if (!auth.token) return setLoading(false)
    try {
      setUser(await api('/auth/me'))
    } catch {
      auth.set(null)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    loadMe()
    const onLogout = () => setUser(null)
    window.addEventListener('resaflow:logout', onLogout)
    return () => window.removeEventListener('resaflow:logout', onLogout)
  }, [loadMe])

  const logout = () => {
    auth.set(null)
    setUser(null)
  }

  if (loading) return <div className="center muted">Chargement…</div>
  if (!user) return <Login onLogged={loadMe} />

  const visibleTabs = TABS.filter((t) => !t.admin || user.role === 'admin')
  return (
    <div className="layout">
      <header className="topbar">
        <div className="brand">
          <img src="/favicon.svg" alt="" width="28" height="28" />
          <span>ResaFlow</span>
        </div>
        <nav aria-label="Navigation principale">
          {visibleTabs.map((t) => (
            <button key={t.id} className={tab === t.id ? 'tab active' : 'tab'} onClick={() => setTab(t.id)}>
              {t.label}
            </button>
          ))}
        </nav>
        <div className="me">
          <span title={user.email}>{user.full_name}{user.role === 'admin' && <em className="badge">admin</em>}</span>
          <button className="ghost" onClick={logout}>Déconnexion</button>
        </div>
      </header>
      <main>
        {tab === 'resources' && <Resources />}
        {tab === 'reservations' && <Reservations />}
        {tab === 'exports' && <Exports />}
        {tab === 'admin' && user.role === 'admin' && <Admin currentUser={user} />}
      </main>
    </div>
  )
}
