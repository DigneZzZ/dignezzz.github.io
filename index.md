---
layout: default
title: DigneZzZ Script Hub
---

<!-- Tailwind CSS -->
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = {
    darkMode: 'class',
    theme: {
      extend: {
        animation: {
          'gradient': 'gradient 8s linear infinite',
          'float': 'float 6s ease-in-out infinite',
          'pulse-slow': 'pulse 4s cubic-bezier(0.4, 0, 0.6, 1) infinite',
        },
        keyframes: {
          gradient: {
            '0%, 100%': { backgroundPosition: '0% 50%' },
            '50%': { backgroundPosition: '100% 50%' },
          },
          float: {
            '0%, 100%': { transform: 'translateY(0px)' },
            '50%': { transform: 'translateY(-10px)' },
          }
        }
      }
    }
  }
</script>

<style>
  .glass {
    background: rgba(255, 255, 255, 0.05);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid rgba(255, 255, 255, 0.1);
  }
  .glass-light {
    background: rgba(255, 255, 255, 0.7);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid rgba(255, 255, 255, 0.3);
  }
  .gradient-text {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 50%, #f093fb 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
  }
  .gradient-bg {
    background: linear-gradient(-45deg, #0f172a, #1e1b4b, #312e81, #1e3a5f);
    background-size: 400% 400%;
  }
  .card-hover {
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  }
  .card-hover:hover {
    transform: translateY(-4px);
    box-shadow: 0 20px 40px rgba(0, 0, 0, 0.3);
  }
  .skeleton {
    background: linear-gradient(90deg, #1f2937 25%, #374151 50%, #1f2937 75%);
    background-size: 200% 100%;
    animation: shimmer 1.5s infinite;
  }
  @keyframes shimmer {
    0% { background-position: 200% 0; }
    100% { background-position: -200% 0; }
  }
  .copy-btn:active { transform: scale(0.95); }
  
  /* Стили для markdown контента */
  .markdown-content table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
  .markdown-content th, .markdown-content td { 
    padding: 0.75rem 1rem; 
    text-align: left; 
    border-bottom: 1px solid rgba(255,255,255,0.1); 
  }
  .markdown-content th { 
    font-weight: 600; 
    color: #a78bfa;
    background: rgba(139, 92, 246, 0.1);
  }
  .markdown-content code {
    background: rgba(139, 92, 246, 0.2);
    padding: 0.2rem 0.5rem;
    border-radius: 0.375rem;
    font-size: 0.85em;
    color: #c4b5fd;
  }
  .markdown-content a { color: #818cf8; }
  .markdown-content a:hover { color: #a78bfa; text-decoration: underline; }
  
  /* Light mode markdown */
  .light .markdown-content th { color: #6d28d9; background: rgba(139, 92, 246, 0.1); }
  .light .markdown-content th, .light .markdown-content td { border-color: rgba(0,0,0,0.1); }
  .light .markdown-content code { background: rgba(139, 92, 246, 0.15); color: #6d28d9; }
  .light .markdown-content a { color: #6366f1; }
</style>

<!-- Auto dark mode -->
<script>
  if (localStorage.getItem('theme') === 'dark' ||
      (!('theme' in localStorage) && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.classList.add('dark')
  } else {
    document.documentElement.classList.add('light')
  }
</script>

<div class="min-h-screen gradient-bg dark:gradient-bg bg-gray-100 animate-gradient transition-all duration-500">
  
  <!-- Floating background elements -->
  <div class="fixed inset-0 overflow-hidden pointer-events-none">
    <div class="absolute top-20 left-10 w-72 h-72 bg-purple-500/20 rounded-full blur-3xl animate-float"></div>
    <div class="absolute bottom-20 right-10 w-96 h-96 bg-blue-500/20 rounded-full blur-3xl animate-float" style="animation-delay: -3s;"></div>
    <div class="absolute top-1/2 left-1/2 w-64 h-64 bg-pink-500/10 rounded-full blur-3xl animate-pulse-slow"></div>
  </div>

  <!-- Navbar -->
  <header class="sticky top-0 z-50 px-6 py-4 glass dark:glass glass-light">
    <div class="max-w-6xl mx-auto flex justify-between items-center">
      <div class="flex items-center gap-3">
        <span class="text-2xl animate-float">🧠</span>
        <span class="text-xl font-bold gradient-text">DigneZzZ</span>
      </div>
      <nav class="flex items-center gap-2 md:gap-4">
        <a href="https://openode.xyz" class="hidden md:inline-flex items-center gap-1 px-3 py-1.5 rounded-lg hover:bg-white/10 transition-all text-gray-700 dark:text-gray-300">
          💬 Forum
        </a>
        <a href="https://openode.xyz/subscriptions/" class="hidden md:inline-flex items-center gap-1 px-3 py-1.5 rounded-lg hover:bg-white/10 transition-all text-gray-700 dark:text-gray-300">
          🔐 Clubs
        </a>
        <a href="https://neonode.cc" class="hidden md:inline-flex items-center gap-1 px-3 py-1.5 rounded-lg hover:bg-white/10 transition-all text-gray-700 dark:text-gray-300">
          ✍️ Blog
        </a>
        <a href="https://github.com/DigneZzZ/dignezzz.github.io" class="inline-flex items-center gap-1 px-3 py-1.5 rounded-lg hover:bg-white/10 transition-all text-gray-700 dark:text-gray-300">
          <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z"/></svg>
        </a>
        <button id="toggleTheme" class="p-2 rounded-lg glass dark:glass glass-light hover:scale-110 transition-transform">
          <span class="dark:hidden">🌙</span>
          <span class="hidden dark:inline">☀️</span>
        </button>
      </nav>
    </div>
  </header>

  <!-- Hero Section -->
  <section class="relative px-6 py-16 md:py-24 text-center">
    <div class="max-w-4xl mx-auto">
      <h1 class="text-4xl md:text-6xl font-extrabold mb-6 text-gray-800 dark:text-white">
        <span class="gradient-text">Script Hub</span>
      </h1>
      <p class="text-lg md:text-xl text-gray-600 dark:text-gray-300 mb-8 max-w-2xl mx-auto">
        Коллекция скриптов, инструментов и руководств для автоматизации серверов и VPN-инфраструктуры
      </p>
      <div class="flex flex-wrap justify-center gap-4">
        <a href="#scripts" class="px-6 py-3 bg-gradient-to-r from-purple-600 to-blue-600 text-white rounded-xl font-medium hover:opacity-90 transition-all hover:scale-105 shadow-lg shadow-purple-500/25">
          📜 Все скрипты
        </a>
        <a href="https://openode.xyz/subscriptions/" class="px-6 py-3 glass dark:glass glass-light rounded-xl font-medium hover:scale-105 transition-all text-gray-700 dark:text-white">
          🚀 Премиум доступ
        </a>
      </div>
    </div>
  </section>

  <!-- Stats -->
  <section class="px-6 py-8">
    <div class="max-w-4xl mx-auto grid grid-cols-2 md:grid-cols-4 gap-4">
      <div class="glass dark:glass glass-light rounded-2xl p-6 text-center card-hover">
        <div class="text-3xl font-bold gradient-text">20+</div>
        <div class="text-sm text-gray-500 dark:text-gray-400 mt-1">Скриптов</div>
      </div>
      <div class="glass dark:glass glass-light rounded-2xl p-6 text-center card-hover">
        <div class="text-3xl font-bold gradient-text">5+</div>
        <div class="text-sm text-gray-500 dark:text-gray-400 mt-1">Категорий</div>
      </div>
      <div class="glass dark:glass glass-light rounded-2xl p-6 text-center card-hover">
        <div class="text-3xl font-bold gradient-text">24/7</div>
        <div class="text-sm text-gray-500 dark:text-gray-400 mt-1">Обновления</div>
      </div>
      <div class="glass dark:glass glass-light rounded-2xl p-6 text-center card-hover">
        <div class="text-3xl font-bold gradient-text">Free</div>
        <div class="text-sm text-gray-500 dark:text-gray-400 mt-1">Open Source</div>
      </div>
    </div>
  </section>

  <!-- Main Content -->
  <main id="scripts" class="max-w-6xl mx-auto px-6 py-12">
    
    <!-- Category Cards Grid -->
    <div class="grid md:grid-cols-2 gap-6 mb-12">
      
      <!-- Marzban Card -->
      <div class="glass dark:glass glass-light rounded-2xl overflow-hidden card-hover">
        <div class="bg-gradient-to-r from-purple-600/20 to-pink-600/20 p-6 border-b border-white/10">
          <div class="flex items-center gap-3">
            <span class="text-4xl">⚙️</span>
            <div>
              <h2 class="text-2xl font-bold text-gray-800 dark:text-white">Marzban</h2>
              <p class="text-sm text-gray-500 dark:text-gray-400">Установка, автоматизация, мониторинг</p>
            </div>
          </div>
        </div>
        <div id="marzban-content" class="p-6 markdown-content text-gray-700 dark:text-gray-300 max-h-96 overflow-y-auto">
          <div class="space-y-3">
            <div class="skeleton h-4 rounded w-3/4"></div>
            <div class="skeleton h-4 rounded w-full"></div>
            <div class="skeleton h-4 rounded w-5/6"></div>
          </div>
        </div>
      </div>

      <!-- Server Card -->
      <div class="glass dark:glass glass-light rounded-2xl overflow-hidden card-hover">
        <div class="bg-gradient-to-r from-blue-600/20 to-cyan-600/20 p-6 border-b border-white/10">
          <div class="flex items-center gap-3">
            <span class="text-4xl">🖥️</span>
            <div>
              <h2 class="text-2xl font-bold text-gray-800 dark:text-white">Server</h2>
              <p class="text-sm text-gray-500 dark:text-gray-400">SSH, swap, firewall, панели</p>
            </div>
          </div>
        </div>
        <div id="server-content" class="p-6 markdown-content text-gray-700 dark:text-gray-300 max-h-96 overflow-y-auto">
          <div class="space-y-3">
            <div class="skeleton h-4 rounded w-3/4"></div>
            <div class="skeleton h-4 rounded w-full"></div>
            <div class="skeleton h-4 rounded w-5/6"></div>
          </div>
        </div>
      </div>

      <!-- Shadowrocket Card -->
      <div class="glass dark:glass glass-light rounded-2xl overflow-hidden card-hover">
        <div class="bg-gradient-to-r from-orange-600/20 to-yellow-600/20 p-6 border-b border-white/10">
          <div class="flex items-center gap-3">
            <span class="text-4xl">🚀</span>
            <div>
              <h2 class="text-2xl font-bold text-gray-800 dark:text-white">Shadowrocket</h2>
              <p class="text-sm text-gray-500 dark:text-gray-400">Правила, конфиги, списки</p>
            </div>
          </div>
        </div>
        <div id="shadowrocket-content" class="p-6 markdown-content text-gray-700 dark:text-gray-300 max-h-96 overflow-y-auto">
          <div class="space-y-3">
            <div class="skeleton h-4 rounded w-3/4"></div>
            <div class="skeleton h-4 rounded w-full"></div>
            <div class="skeleton h-4 rounded w-5/6"></div>
          </div>
        </div>
      </div>

      <!-- SHM Card -->
      <div class="glass dark:glass glass-light rounded-2xl overflow-hidden card-hover">
        <div class="bg-gradient-to-r from-green-600/20 to-emerald-600/20 p-6 border-b border-white/10">
          <div class="flex items-center gap-3">
            <span class="text-4xl">💾</span>
            <div>
              <h2 class="text-2xl font-bold text-gray-800 dark:text-white">SHM</h2>
              <p class="text-sm text-gray-500 dark:text-gray-400">Backup и утилиты</p>
            </div>
          </div>
        </div>
        <div id="shm-content" class="p-6 markdown-content text-gray-700 dark:text-gray-300 max-h-96 overflow-y-auto">
          <div class="space-y-3">
            <div class="skeleton h-4 rounded w-3/4"></div>
            <div class="skeleton h-4 rounded w-full"></div>
            <div class="skeleton h-4 rounded w-5/6"></div>
          </div>
        </div>
      </div>
    </div>

    <!-- Full Scripts Index -->
    <section class="glass dark:glass glass-light rounded-2xl overflow-hidden">
      <div class="bg-gradient-to-r from-indigo-600/20 to-purple-600/20 p-6 border-b border-white/10">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <span class="text-4xl">📊</span>
            <div>
              <h2 class="text-2xl font-bold text-gray-800 dark:text-white">Все скрипты</h2>
              <p class="text-sm text-gray-500 dark:text-gray-400">Полный автоматически обновляемый список</p>
            </div>
          </div>
          <a href="https://github.com/DigneZzZ/dignezzz.github.io" class="hidden md:flex items-center gap-2 px-4 py-2 bg-white/10 rounded-lg hover:bg-white/20 transition-all text-sm text-gray-700 dark:text-gray-300">
            <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24"><path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z"/></svg>
            View on GitHub
          </a>
        </div>
      </div>
      <div id="readme-content" class="p-6 markdown-content text-gray-700 dark:text-gray-300 max-h-[600px] overflow-y-auto">
        <div class="space-y-3">
          <div class="skeleton h-4 rounded w-1/2"></div>
          <div class="skeleton h-4 rounded w-3/4"></div>
          <div class="skeleton h-4 rounded w-full"></div>
          <div class="skeleton h-4 rounded w-5/6"></div>
        </div>
      </div>
    </section>
  </main>

  <!-- Resources Section -->
  <section class="px-6 py-16 mt-8">
    <div class="max-w-4xl mx-auto">
      <h2 class="text-2xl font-bold text-center mb-8 text-gray-800 dark:text-white">🔗 Полезные ресурсы</h2>
      <div class="grid md:grid-cols-3 gap-6">
        <a href="https://openode.xyz" class="glass dark:glass glass-light rounded-2xl p-6 text-center card-hover group">
          <div class="text-4xl mb-4 group-hover:scale-110 transition-transform">💬</div>
          <h3 class="font-bold text-gray-800 dark:text-white mb-2">Forum</h3>
          <p class="text-sm text-gray-500 dark:text-gray-400">openode.xyz — форум с клубами</p>
        </a>
        <a href="https://openode.xyz/subscriptions/" class="glass dark:glass glass-light rounded-2xl p-6 text-center card-hover group">
          <div class="text-4xl mb-4 group-hover:scale-110 transition-transform">🔐</div>
          <h3 class="font-bold text-gray-800 dark:text-white mb-2">Premium Clubs</h3>
          <p class="text-sm text-gray-500 dark:text-gray-400">Marzban & Remnawave гайды</p>
        </a>
        <a href="https://neonode.cc" class="glass dark:glass glass-light rounded-2xl p-6 text-center card-hover group">
          <div class="text-4xl mb-4 group-hover:scale-110 transition-transform">✍️</div>
          <h3 class="font-bold text-gray-800 dark:text-white mb-2">Blog</h3>
          <p class="text-sm text-gray-500 dark:text-gray-400">neonode.cc — технический блог</p>
        </a>
      </div>
    </div>
  </section>

  <!-- Footer -->
  <footer class="px-6 py-8 border-t border-white/10">
    <div class="max-w-6xl mx-auto flex flex-col md:flex-row justify-between items-center gap-4">
      <div class="flex items-center gap-2 text-gray-500 dark:text-gray-400">
        <span>Made with 💜 by</span>
        <span class="font-bold gradient-text">DigneZzZ</span>
      </div>
      <div class="flex gap-4 text-sm text-gray-500 dark:text-gray-400">
        <a href="https://t.me/dignezzz" class="hover:text-purple-400 transition-colors">Telegram</a>
        <a href="https://github.com/DigneZzZ" class="hover:text-purple-400 transition-colors">GitHub</a>
      </div>
    </div>
  </footer>
</div>

<!-- Markdown parser -->
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>

<script>
  // Theme toggle
  const toggleTheme = document.getElementById('toggleTheme')
  toggleTheme?.addEventListener('click', () => {
    document.documentElement.classList.toggle('dark')
    document.documentElement.classList.toggle('light')
    localStorage.setItem('theme', document.documentElement.classList.contains('dark') ? 'dark' : 'light')
  })

  // Load markdown content
  async function loadMarkdown(id, file) {
    const el = document.getElementById(id)
    try {
      const res = await fetch(file + '?t=' + Date.now()) // Cache bust
      if (!res.ok) throw new Error('Not found')
      const text = await res.text()
      el.innerHTML = marked.parse(text)
      
      // Add copy buttons to code blocks
      el.querySelectorAll('code').forEach(code => {
        if (code.textContent.includes('wget') || code.textContent.includes('curl') || code.textContent.includes('bash')) {
          code.style.cursor = 'pointer'
          code.title = 'Click to copy'
          code.addEventListener('click', () => {
            navigator.clipboard.writeText(code.textContent)
            const original = code.textContent
            code.textContent = '✓ Copied!'
            setTimeout(() => code.textContent = original, 1500)
          })
        }
      })
    } catch (err) {
      el.innerHTML = `<p class="text-gray-500 dark:text-gray-400 italic">Контент временно недоступен</p>`
    }
  }

  // Load all sections
  loadMarkdown('marzban-content', './marzban/README.md')
  loadMarkdown('server-content', './server/README.md')
  loadMarkdown('shadowrocket-content', './shadowrocket/readme.md')
  loadMarkdown('shm-content', './shm/README.md')
  loadMarkdown('readme-content', './README.md')

  // Smooth scroll
  document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function(e) {
      e.preventDefault()
      document.querySelector(this.getAttribute('href'))?.scrollIntoView({ behavior: 'smooth' })
    })
  })
</script>
