import { useCallback, useEffect, useState } from 'react'
import { api, downloadFile } from '../api.js'
import { fmt } from '../dates.js'

const LABEL = { pending: 'En file', running: 'En cours', done: 'Prêt', failed: 'Échec' }

export default function Exports() {
  const [items, setItems] = useState([])
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    try { setItems(await api('/exports')) } catch (e) { setError(e.message) }
  }, [])

  useEffect(() => { load() }, [load])

  // Rafraîchissement tant qu'un export est traité par le worker
  useEffect(() => {
    if (!items.some((e) => e.status === 'pending' || e.status === 'running')) return
    const t = setTimeout(load, 1500)
    return () => clearTimeout(t)
  }, [items, load])

  const request = async () => {
    setError('')
    try {
      await api('/exports', { method: 'POST' })
      load()
    } catch (e) {
      setError(e.message)
    }
  }

  return (
    <section>
      <div className="toolbar">
        <h2>Exports PDF</h2>
        <button className="primary" onClick={request}>Générer un récapitulatif PDF</button>
      </div>
      <p className="muted">La génération est confiée à un worker en arrière-plan ; les exports sont conservés 7 jours.</p>
      {error && <p className="error">{error}</p>}
      <table className="table">
        <thead><tr><th>N°</th><th>Demandé le</th><th>Statut</th><th /></tr></thead>
        <tbody>
          {items.map((e) => (
            <tr key={e.id}>
              <td>{e.id}</td>
              <td>{fmt(e.created_at)}</td>
              <td><span className={`pill ${e.status}`}>{LABEL[e.status]}</span></td>
              <td>{e.status === 'done' &&
                <button className="link" onClick={() => downloadFile(`/exports/${e.id}/download`, `resaflow-${e.id}.pdf`)}>
                  Télécharger
                </button>}
              </td>
            </tr>
          ))}
          {!items.length && <tr><td colSpan={4} className="muted">Aucun export.</td></tr>}
        </tbody>
      </table>
    </section>
  )
}
