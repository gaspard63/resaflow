import { useCallback, useEffect, useState } from 'react'
import { api } from '../api.js'
import AuthImage from './AuthImage.jsx'
import { fmt, toLocalInput } from '../dates.js'

const TYPE_LABEL = { room: 'Salle', equipment: 'Matériel' }

export default function Resources() {
  const [items, setItems] = useState([])
  const [filter, setFilter] = useState('')
  const [q, setQ] = useState('')
  const [selected, setSelected] = useState(null)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    const params = new URLSearchParams()
    if (filter) params.set('type', filter)
    if (q) params.set('q', q)
    try {
      setItems(await api(`/resources?${params}`))
    } catch (e) {
      setError(e.message)
    }
  }, [filter, q])

  useEffect(() => { load() }, [load])

  return (
    <section>
      <div className="toolbar">
        <h2>Ressources</h2>
        <input placeholder="Rechercher…" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Rechercher" />
        <select value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Type">
          <option value="">Tous les types</option>
          <option value="room">Salles</option>
          <option value="equipment">Matériel</option>
        </select>
      </div>
      {error && <p className="error">{error}</p>}
      <div className="grid">
        {items.map((r) => (
          <article key={r.id} className="card resource" onClick={() => setSelected(r)}>
            {r.has_image
              ? <AuthImage path={`/resources/${r.id}/image?thumbnail=true`} alt={r.name} className="thumb" />
              : <div className="thumb placeholder" aria-hidden="true">{TYPE_LABEL[r.type][0]}</div>}
            <div className="body">
              <h3>{r.name}</h3>
              <p className="muted">{TYPE_LABEL[r.type]} · {r.location || '—'} · {r.capacity} pers.</p>
              <p className="desc">{r.description}</p>
            </div>
          </article>
        ))}
        {!items.length && <p className="muted">Aucune ressource.</p>}
      </div>
      {selected && <BookingPanel resource={selected} onClose={() => setSelected(null)} />}
    </section>
  )
}

function BookingPanel({ resource, onClose }) {
  const now = new Date()
  now.setMinutes(0, 0, 0)
  now.setHours(now.getHours() + 1)
  const [start, setStart] = useState(toLocalInput(now))
  const [end, setEnd] = useState(toLocalInput(new Date(now.getTime() + 3600_000)))
  const [purpose, setPurpose] = useState('')
  const [slots, setSlots] = useState([])
  const [msg, setMsg] = useState(null)

  const loadSlots = useCallback(async () => {
    const from = new Date()
    const to = new Date(from.getTime() + 7 * 86400_000)
    const params = new URLSearchParams({ start: from.toISOString(), end: to.toISOString() })
    setSlots(await api(`/resources/${resource.id}/slots?${params}`))
  }, [resource.id])

  useEffect(() => { loadSlots().catch(() => {}) }, [loadSlots])

  const book = async (e) => {
    e.preventDefault()
    setMsg(null)
    try {
      await api('/reservations', {
        method: 'POST',
        body: {
          resource_id: resource.id,
          start_at: new Date(start).toISOString(),
          end_at: new Date(end).toISOString(),
          purpose,
        },
      })
      setMsg({ ok: true, text: 'Réservation confirmée — un e-mail de confirmation est en cours d\'envoi.' })
      loadSlots()
    } catch (err) {
      setMsg({ ok: false, text: err.message })
    }
  }

  return (
    <div className="overlay" role="dialog" aria-modal="true" aria-label={`Réserver ${resource.name}`} onClick={onClose}>
      <div className="card panel" onClick={(e) => e.stopPropagation()}>
        <button className="close ghost" onClick={onClose} aria-label="Fermer">×</button>
        <h3>Réserver « {resource.name} »</h3>
        <form onSubmit={book} className="stack">
          <div className="row">
            <label>Début<input type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} required /></label>
            <label>Fin<input type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} required /></label>
          </div>
          <label>Objet<input value={purpose} maxLength={255} onChange={(e) => setPurpose(e.target.value)} /></label>
          {msg && <p className={msg.ok ? 'success' : 'error'} role="status">{msg.text}</p>}
          <button className="primary">Réserver</button>
        </form>
        <h4>Créneaux déjà pris (7 prochains jours)</h4>
        <ul className="slots">
          {slots.map((s) => <li key={s.id}>{fmt(s.start_at)} → {fmt(s.end_at)}</li>)}
          {!slots.length && <li className="muted">Aucun — la ressource est libre.</li>}
        </ul>
      </div>
    </div>
  )
}
