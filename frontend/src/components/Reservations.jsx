import { useCallback, useEffect, useState } from 'react'
import { api, downloadFile } from '../api.js'
import { fmt } from '../dates.js'

export default function Reservations() {
  const [items, setItems] = useState([])
  const [resources, setResources] = useState({})
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    try {
      const [res, list] = await Promise.all([api('/resources?include_inactive=true'), api('/reservations')])
      setResources(Object.fromEntries(res.map((r) => [r.id, r.name])))
      setItems(list)
    } catch (e) {
      setError(e.message)
    }
  }, [])

  useEffect(() => { load() }, [load])

  const cancel = async (id) => {
    if (!window.confirm('Annuler cette réservation ?')) return
    await api(`/reservations/${id}/cancel`, { method: 'POST' })
    load()
  }

  const upload = async (id, file) => {
    if (!file) return
    const form = new FormData()
    form.append('file', file)
    try {
      await api(`/reservations/${id}/attachment`, { method: 'POST', form })
      load()
    } catch (e) {
      setError(e.message)
    }
  }

  return (
    <section>
      <h2>Mes réservations</h2>
      {error && <p className="error">{error}</p>}
      <table className="table">
        <thead>
          <tr><th>N°</th><th>Ressource</th><th>Début</th><th>Fin</th><th>Statut</th><th>Pièce jointe</th><th /></tr>
        </thead>
        <tbody>
          {items.map((r) => (
            <tr key={r.id} className={r.status === 'cancelled' ? 'dim' : ''}>
              <td>{r.id}</td>
              <td>{resources[r.resource_id] ?? `#${r.resource_id}`}<div className="muted small">{r.purpose}</div></td>
              <td>{fmt(r.start_at)}</td>
              <td>{fmt(r.end_at)}</td>
              <td><span className={`pill ${r.status}`}>{r.status === 'confirmed' ? 'Confirmée' : 'Annulée'}</span></td>
              <td>
                {r.attachment_name
                  ? <button className="link" onClick={() => downloadFile(`/reservations/${r.id}/attachment`, r.attachment_name)}>
                      {r.attachment_name}
                    </button>
                  : r.status === 'confirmed' && (
                    <label className="upload">
                      Joindre…
                      <input type="file" accept="application/pdf,image/png,image/jpeg,image/webp" hidden
                        onChange={(e) => upload(r.id, e.target.files[0])} />
                    </label>
                  )}
              </td>
              <td>{r.status === 'confirmed' && <button className="ghost" onClick={() => cancel(r.id)}>Annuler</button>}</td>
            </tr>
          ))}
          {!items.length && <tr><td colSpan={7} className="muted">Aucune réservation pour l'instant.</td></tr>}
        </tbody>
      </table>
    </section>
  )
}
