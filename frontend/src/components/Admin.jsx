import { useCallback, useEffect, useState } from 'react'
import { api } from '../api.js'

const EMPTY = { name: '', type: 'room', location: '', capacity: 1, description: '' }

export default function Admin({ currentUser }) {
  const [stats, setStats] = useState(null)
  const [users, setUsers] = useState([])
  const [resources, setResources] = useState([])
  const [form, setForm] = useState(EMPTY)
  const [msg, setMsg] = useState(null)

  const load = useCallback(async () => {
    const [s, u, r] = await Promise.all([
      api('/admin/stats'), api('/admin/users'), api('/resources?include_inactive=true'),
    ])
    setStats(s)
    setUsers(u)
    setResources(r)
  }, [])

  useEffect(() => { load().catch((e) => setMsg({ ok: false, text: e.message })) }, [load])

  const create = async (e) => {
    e.preventDefault()
    try {
      await api('/resources', { method: 'POST', body: { ...form, capacity: Number(form.capacity) } })
      setForm(EMPTY)
      setMsg({ ok: true, text: 'Ressource créée.' })
      load()
    } catch (err) {
      setMsg({ ok: false, text: err.message })
    }
  }

  const uploadImage = async (id, file) => {
    if (!file) return
    const data = new FormData()
    data.append('file', file)
    try {
      await api(`/resources/${id}/image`, { method: 'POST', form: data })
      setMsg({ ok: true, text: 'Image envoyée — la miniature est générée en arrière-plan.' })
      load()
    } catch (err) {
      setMsg({ ok: false, text: err.message })
    }
  }

  const toggle = async (r) => {
    if (r.is_active) await api(`/resources/${r.id}`, { method: 'DELETE' })
    else await api(`/resources/${r.id}`, { method: 'PATCH', body: { is_active: true } })
    load()
  }

  const setRole = async (u, role) => {
    await api(`/admin/users/${u.id}/role`, { method: 'PATCH', body: { role } })
    load()
  }

  return (
    <section className="stack">
      <h2>Administration</h2>
      {stats && (
        <div className="kpis">
          <div className="card kpi"><strong>{stats.users}</strong><span>utilisateurs</span></div>
          <div className="card kpi"><strong>{stats.resources}</strong><span>ressources actives</span></div>
          <div className="card kpi"><strong>{stats.reservations_confirmed}</strong><span>réservations confirmées</span></div>
        </div>
      )}
      {msg && <p className={msg.ok ? 'success' : 'error'} role="status">{msg.text}</p>}

      <form className="card stack" onSubmit={create}>
        <h3>Nouvelle ressource</h3>
        <div className="row">
          <label>Nom<input value={form.name} required minLength={2} onChange={(e) => setForm({ ...form, name: e.target.value })} /></label>
          <label>Type
            <select value={form.type} onChange={(e) => setForm({ ...form, type: e.target.value })}>
              <option value="room">Salle</option><option value="equipment">Matériel</option>
            </select>
          </label>
          <label>Lieu<input value={form.location} onChange={(e) => setForm({ ...form, location: e.target.value })} /></label>
          <label>Capacité<input type="number" min={1} value={form.capacity} onChange={(e) => setForm({ ...form, capacity: e.target.value })} /></label>
        </div>
        <label>Description<textarea value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} /></label>
        <button className="primary">Créer</button>
      </form>

      <div className="card">
        <h3>Ressources</h3>
        <table className="table">
          <thead><tr><th>Nom</th><th>Image</th><th>État</th><th /></tr></thead>
          <tbody>
            {resources.map((r) => (
              <tr key={r.id} className={r.is_active ? '' : 'dim'}>
                <td>{r.name}</td>
                <td>
                  <label className="upload">{r.has_image ? 'Remplacer…' : 'Ajouter…'}
                    <input type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={(e) => uploadImage(r.id, e.target.files[0])} />
                  </label>
                  {r.has_image && !r.has_thumbnail && <span className="muted small"> miniature en cours…</span>}
                </td>
                <td>{r.is_active ? 'Active' : 'Désactivée'}</td>
                <td><button className="ghost" onClick={() => toggle(r)}>{r.is_active ? 'Désactiver' : 'Réactiver'}</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h3>Utilisateurs</h3>
        <table className="table">
          <thead><tr><th>Nom</th><th>E-mail</th><th>Rôle</th></tr></thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id}>
                <td>{u.full_name}</td>
                <td>{u.email}</td>
                <td>
                  <select value={u.role} disabled={u.id === currentUser.id} onChange={(e) => setRole(u, e.target.value)}
                    aria-label={`Rôle de ${u.full_name}`}>
                    <option value="user">user</option><option value="admin">admin</option>
                  </select>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
