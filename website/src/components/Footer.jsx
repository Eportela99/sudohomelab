import { CATEGORIES } from '../data/catalog'
import { GITHUB_REPO } from '../data/platforms'
import { Logo } from './Bits'

export default function Footer() {
  return (
    <footer className="footer">
      <div className="footer-glow" />
      <div className="container footer-grid">
        <div className="footer-brand">
          <Logo />
          <p>One-line installers and pre-wired stacks for Proxmox, TrueNAS, Ubuntu Server, Windows and macOS. Open source, built in a real homelab.</p>
          <code className="footer-cmd">$ sudo homelab --help</code>
        </div>
        <div>
          <h4>Catalog</h4>
          {CATEGORIES.slice(0, 5).map((c) => (
            <a key={c.id} href={`#/c/${c.id}`}>{c.name}</a>
          ))}
        </div>
        <div>
          <h4>More</h4>
          {CATEGORIES.slice(5).map((c) => (
            <a key={c.id} href={`#/c/${c.id}`}>{c.name}</a>
          ))}
          <a href="#/stacks">Pre-wired stacks</a>
        </div>
        <div>
          <h4>Project</h4>
          <a href="#/advisor">AI Advisor</a>
          <a href={GITHUB_REPO} target="_blank" rel="noreferrer">GitHub</a>
          <a href={`${GITHUB_REPO}/issues`} target="_blank" rel="noreferrer">Request an app</a>
        </div>
      </div>
      <div className="container footer-bottom">
        <span>© {new Date().getFullYear()} sudo homelab · Built by Enrique L. Portela</span>
        <span className="footer-safety">Always read a script before piping it to a shell.</span>
      </div>
    </footer>
  )
}
