import { useEffect, useRef, useState } from 'react'
import { useRoute } from './hooks'
import Navbar from './components/Navbar'
import Footer from './components/Footer'
import CommandPalette from './components/CommandPalette'
import Home from './pages/Home'
import Advisor, { AdvisorFab } from './pages/Advisor'
import { CatalogPage, CategoryPage, NotFound, StacksPage } from './pages/Category'

export default function App() {
  const { page, params } = useRoute()
  const [palette, setPalette] = useState(false)
  const prevKey = useRef('')

  useEffect(() => {
    const onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        setPalette((p) => !p)
      } else if (e.key === '/' && !/input|textarea/i.test(document.activeElement.tagName)) {
        e.preventDefault()
        setPalette(true)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // Scroll to top on page changes, but not when only the app drawer opens/closes.
  const pageKey = `${page}/${params[0] || ''}`
  useEffect(() => {
    if (prevKey.current !== pageKey) window.scrollTo({ top: 0, behavior: 'instant' })
    prevKey.current = pageKey
  }, [pageKey])

  let view
  if (page === 'home') view = <Home />
  else if (page === 'catalog') view = <CatalogPage />
  else if (page === 'c') view = <CategoryPage id={params[0]} appId={params[1]} />
  else if (page === 'stacks') view = <StacksPage id={params[0]} />
  else if (page === 'advisor') view = <Advisor />
  else view = <NotFound />

  return (
    <>
      <div className="noise" aria-hidden />
      <Navbar page={page} onSearch={() => setPalette(true)} />
      <main key={pageKey} className="view">
        {view}
      </main>
      {page !== 'advisor' && <AdvisorFab />}
      <Footer />
      <CommandPalette open={palette} onClose={() => setPalette(false)} />
    </>
  )
}
