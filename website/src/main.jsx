import { createRoot } from 'react-dom/client'
import App from './App'
import { PlatformProvider } from './hooks'
import './styles.css'

createRoot(document.getElementById('root')).render(
  <PlatformProvider>
    <App />
  </PlatformProvider>
)
