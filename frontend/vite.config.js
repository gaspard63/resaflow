import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// En développement (npm run dev), /api est relayé vers l'API locale.
// En conteneur, c'est Nginx (compose) ou l'Ingress (Kubernetes) qui route /api vers le back-end.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: { '/api': 'http://localhost:8000' },
  },
  build: { sourcemap: false },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/setupTests.js'],
  },
})
