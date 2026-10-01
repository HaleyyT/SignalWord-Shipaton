import { defineConfig, type Plugin } from 'vitest/config'
import react from '@vitejs/plugin-react'

const productionSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'self'; font-src 'self'; form-action 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'"

function productionSecurityHeaders(): Plugin {
  return {
    name: 'signalword-production-security-headers',
    transformIndexHtml(html, context) {
      if (context.server) return html
      return html.replace('</head>', `    <meta http-equiv="Content-Security-Policy" content="${productionSecurityPolicy}" />\n  </head>`)
    },
  }
}

export default defineConfig({
  plugins: [react(), productionSecurityHeaders()],
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
})
