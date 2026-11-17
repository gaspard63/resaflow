import { useEffect, useState } from 'react'
import { api } from '../api.js'

// Les images sont servies par l'API (authentifiée) : on les charge en blob avec le jeton.
export default function AuthImage({ path, alt, className }) {
  const [src, setSrc] = useState(null)
  useEffect(() => {
    let url
    let cancelled = false
    api(path, { raw: true })
      .then((blob) => {
        if (cancelled) return
        url = URL.createObjectURL(blob)
        setSrc(url)
      })
      .catch(() => setSrc(null))
    return () => {
      cancelled = true
      if (url) URL.revokeObjectURL(url)
    }
  }, [path])
  if (!src) return <div className={`${className} placeholder`} aria-hidden="true" />
  return <img src={src} alt={alt} className={className} />
}
