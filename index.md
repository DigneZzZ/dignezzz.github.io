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
        typography: (theme) => ({
          dark: {
            css: {
              color: theme('colors.gray.300'),
              a: { color: theme('colors.blue.400') },
              strong: { color: theme('colors.white') },
              code: { color: theme('colors.pink.400') },
            }
          }
        })
      }
    }
  }
</script>

<!-- Auto dark mode -->
<script>
  if (localStorage.getItem('theme') === 'dark' ||
      (!('theme' in localStorage) && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.classList.add('dark')
  }
</script>

<div class="min-h-screen bg-gray-50 dark:bg-gray-900 text-gray-900 dark:text-gray-100 transition duration-300">
  <!-- Навбар -->
  <header class="px-6 py-4 bg-white dark:bg-gray-800 shadow flex justify-between items-center">
    <div class="text-xl font-semibold">🧠 DigneZzZ Script Hub</div>
    <div class="flex gap-4 text-sm">
      <a href="https://openode.xyz" class="hover:underline">Forum</a>
      <a href="https://openode.xyz/subscriptions/" class="hover:underline">Clubs</a>
      <a href="https://neonode.cc" class="hover:underline">Blog</a>
      <button id="toggleTheme" class="border px-2 py-1 rounded hover:bg-gray-200 dark:hover:bg-gray-700">🌗 Theme</button>
    </div>
  </header>

  <!-- Контент -->
  <main class="max-w-4xl mx-auto px-6 py-10">
    <h1 class="text-3xl font-bold mb-6 text-center">🧠 DigneZzZ Script Hub</h1>
    <p class="text-center text-gray-600 dark:text-gray-400 mb-12">
      A curated collection of scripts, tools, and automation guides.
    </p>

    <!-- Раздел: Marzban -->
    <section class="mb-12">
      <h2 class="text-2xl font-semibold mb-2">⚙️ Marzban</h2>
      <p class="text-gray-700 dark:text-gray-300 mb-4">Scripts for installing, automating, and monitoring Marzban.</p>
      <div id="marzban-content" class="prose dark:prose-dark max-w-none text-sm bg-white dark:bg-gray-800 rounded p-4 shadow-inner">
        <p class="text-gray-500">Loading Marzban scripts...</p>
      </div>
    </section>

    <!-- Раздел: Server -->
    <section class="mb-12">
      <h2 class="text-2xl font-semibold mb-2">🖥️ Server</h2>
      <p class="text-gray-700 dark:text-gray-300 mb-4">General-purpose scripts: SSH, swap, firewalls, panels, and more.</p>
      <div id="server-content" class="prose dark:prose-dark max-w-none text-sm bg-white dark:bg-gray-800 rounded p-4 shadow-inner">
        <p class="text-gray-500">Loading Server scripts...</p>
      </div>
    </section>

    <!-- Раздел: All -->
    <section class="mb-12">
      <h2 class="text-2xl font-semibold mb-2">📊 All Scripts</h2>
      <p class="text-gray-700 dark:text-gray-300 mb-4">Auto-generated index of all available scripts.</p>
      <div id="readme-content" class="prose dark:prose-dark max-w-none text-sm bg-white dark:bg-gray-800 rounded p-4 shadow-inner">
        <p class="text-gray-500">Loading global script index...</p>
      </div>
    </section>

    <!-- Resources -->
    <section class="mt-8 text-sm">
      <h2 class="text-xl font-semibold mb-2">🔗 Resources</h2>
      <ul class="list-disc list-inside text-blue-400">
        <li><a href="https://openode.xyz" class="hover:underline">Forum: openode.xyz</a></li>
        <li><a href="https://openode.xyz/subscriptions/" class="hover:underline">Clubs: Marzban & Remnawave</a></li>
        <li><a href="https://neonode.cc" class="hover:underline">Blog: neonode.cc</a></li>
      </ul>
    </section>
  </main>
</div>

<!-- Markdown parser -->
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>

<script>
  const toggleTheme = document.getElementById('toggleTheme')
  toggleTheme?.addEventListener('click', () => {
    document.documentElement.classList.toggle('dark')
    localStorage.setItem('theme', document.documentElement.classList.contains('dark') ? 'dark' : 'light')
  })

  async function loadMarkdown(id, file) {
    const el = document.getElementById(id)
    try {
      const res = await fetch(file)
      const text = await res.text()
      el.innerHTML = marked.parse(text)
    } catch (err) {
      el.innerHTML = "<p class='text-red-500'>Failed to load content.</p>"
    }
  }

  // Загружаем скрипты
  loadMarkdown('marzban-content', './marzban/README.md')
  loadMarkdown('server-content', './server/README.md')
  loadMarkdown('readme-content', './README.md')
</script>
